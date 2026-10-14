package auth

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"html/template"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	sdkauth "github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/oauthex"
)

var consentPage = template.Must(template.New("consent").Parse(`<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Allow mactivity</title></head>
<body>
<p><strong>{{.Name}}</strong> is asking to read activity on this Mac.</p>
<p>After you allow it, the browser will go to <strong>{{.Host}}</strong>.</p>
{{if .Loopback}}<p>That address is on this computer.</p>{{end}}
<form method="post" action="/authorize">
<input type="hidden" name="consent_id" value="{{.ID}}">
<button type="submit" name="decision" value="allow">Allow</button>
<button type="submit" name="decision" value="deny">Deny</button>
</form>
</body>
</html>
`))

// Handler serves discovery, authorization, and the protected MCP endpoint.
func (i *Issuer) Handler(mcp http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/oauth-protected-resource", i.resourceMeta)
	mux.HandleFunc("GET /.well-known/oauth-protected-resource/mcp", i.resourceMeta)
	mux.HandleFunc("GET /.well-known/oauth-authorization-server", i.serverMeta)
	mux.HandleFunc("GET /.well-known/jwks.json", i.jwks)
	mux.HandleFunc("POST /register", i.register)
	mux.HandleFunc("GET /authorize", i.authorize)
	mux.HandleFunc("POST /authorize", i.consent)
	mux.HandleFunc("POST /token", i.token)
	protected := i.protect(mcp)
	mux.Handle("/mcp", protected)
	mux.Handle("/mcp/", protected)
	return mux
}

func (i *Issuer) protect(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		base, err := requestBase(r)
		if err != nil {
			http.Error(w, "invalid host", http.StatusBadRequest)
			return
		}
		opts := &sdkauth.RequireBearerTokenOptions{
			ResourceMetadataURL: base + "/.well-known/oauth-protected-resource",
			Scopes:              []string{Scope},
		}
		sdkauth.RequireBearerToken(i.verify(base), opts)(next).ServeHTTP(&scopeWriter{ResponseWriter: w}, r)
	})
}

func (i *Issuer) verify(base string) sdkauth.TokenVerifier {
	resource := base + "/mcp"
	return func(_ context.Context, token string, _ *http.Request) (*sdkauth.TokenInfo, error) {
		claims, err := i.parse(token)
		if err != nil {
			return nil, sdkauth.ErrInvalidToken
		}
		if claims.ExpiresAt == nil || len(claims.Audience) != 1 || claims.Audience[0] != resource || claims.Issuer != base {
			return nil, sdkauth.ErrInvalidToken
		}
		return &sdkauth.TokenInfo{
			Scopes:     strings.Fields(claims.Scope),
			Expiration: claims.ExpiresAt.Time,
			UserID:     claims.Subject,
		}, nil
	}
}

type scopeWriter struct {
	http.ResponseWriter
	wrote bool
}

func (s *scopeWriter) WriteHeader(code int) {
	if !s.wrote && code == http.StatusForbidden {
		header := s.Header().Get("WWW-Authenticate")
		if !strings.Contains(header, "insufficient_scope") {
			if header != "" {
				header += ", "
			}
			s.Header().Set("WWW-Authenticate", header+`error="insufficient_scope"`)
		}
	}
	s.wrote = true
	s.ResponseWriter.WriteHeader(code)
}

func (s *scopeWriter) Flush() {
	if flusher, ok := s.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (s *scopeWriter) Unwrap() http.ResponseWriter {
	return s.ResponseWriter
}

func (i *Issuer) resourceMeta(w http.ResponseWriter, r *http.Request) {
	base, err := requestBase(r)
	if err != nil {
		http.Error(w, "invalid host", http.StatusBadRequest)
		return
	}
	meta := &oauthex.ProtectedResourceMetadata{
		Resource:               base + "/mcp",
		AuthorizationServers:   []string{base},
		ScopesSupported:        []string{Scope},
		BearerMethodsSupported: []string{"header"},
		ResourceName:           "mactivity",
	}
	sdkauth.ProtectedResourceMetadataHandler(meta).ServeHTTP(w, r)
}

func (i *Issuer) serverMeta(w http.ResponseWriter, r *http.Request) {
	base, err := requestBase(r)
	if err != nil {
		http.Error(w, "invalid host", http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusOK, oauthex.AuthServerMeta{
		Issuer:                            base,
		AuthorizationEndpoint:             base + "/authorize",
		TokenEndpoint:                     base + "/token",
		RegistrationEndpoint:              base + "/register",
		JWKSURI:                           base + "/.well-known/jwks.json",
		ScopesSupported:                   []string{Scope},
		ResponseTypesSupported:            []string{"code"},
		GrantTypesSupported:               []string{"authorization_code", "refresh_token"},
		TokenEndpointAuthMethodsSupported: []string{"none"},
		CodeChallengeMethodsSupported:     []string{"S256"},
		ClientIDMetadataDocumentSupported: true,
	})
}

func (i *Issuer) jwks(w http.ResponseWriter, r *http.Request) {
	if _, err := requestBase(r); err != nil {
		http.Error(w, "invalid host", http.StatusBadRequest)
		return
	}
	x, y := jwkCoords(&i.key.PublicKey)
	writeJSON(w, http.StatusOK, map[string]any{
		"keys": []map[string]string{{
			"kty": "EC",
			"crv": "P-256",
			"x":   x,
			"y":   y,
			"alg": "ES256",
			"use": "sig",
		}},
	})
}

func (i *Issuer) register(w http.ResponseWriter, r *http.Request) {
	if _, err := requestBase(r); err != nil {
		http.Error(w, "invalid host", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20+1))
	if err != nil || len(body) > 1<<20 {
		oauthError(w, http.StatusBadRequest, "invalid_client_metadata", "request body is invalid")
		return
	}
	var meta oauthex.ClientRegistrationMetadata
	if err := json.Unmarshal(body, &meta); err != nil {
		oauthError(w, http.StatusBadRequest, "invalid_client_metadata", "request body is invalid")
		return
	}
	if err := validateRegistration(meta); err != nil {
		code := "invalid_client_metadata"
		if errors.Is(err, errInvalidRedirect) {
			code = "invalid_redirect_uri"
		}
		oauthError(w, http.StatusBadRequest, code, err.Error())
		return
	}
	id, err := randomToken()
	if err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "could not register")
		return
	}
	id = "mactivity_" + id
	name := meta.ClientName
	if name == "" {
		name = "MCP client"
	}
	if len(name) > 128 {
		name = name[:128]
	}
	if err := i.saveClient(id, name, meta.RedirectURIs); err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "could not register")
		return
	}
	meta.TokenEndpointAuthMethod = "none"
	meta.GrantTypes = []string{"authorization_code", "refresh_token"}
	meta.ResponseTypes = []string{"code"}
	meta.ClientName = name
	writeJSON(w, http.StatusCreated, struct {
		oauthex.ClientRegistrationMetadata
		ClientID         string `json:"client_id"`
		ClientIDIssuedAt int64  `json:"client_id_issued_at"`
	}{
		ClientRegistrationMetadata: meta,
		ClientID:                   id,
		ClientIDIssuedAt:           time.Now().Unix(),
	})
}

func (i *Issuer) authorize(w http.ResponseWriter, r *http.Request) {
	base, err := requestBase(r)
	if err != nil {
		http.Error(w, "invalid host", http.StatusBadRequest)
		return
	}
	q := r.URL.Query()
	clientID := q.Get("client_id")
	redirectURI := q.Get("redirect_uri")
	if clientID == "" || redirectURI == "" {
		http.Error(w, "invalid_request", http.StatusBadRequest)
		return
	}
	info, err := i.lookupClient(r.Context(), clientID)
	if err != nil {
		http.Error(w, "invalid_client", http.StatusBadRequest)
		return
	}
	if !redirectAllowed(info.redirects, redirectURI) {
		http.Error(w, "invalid_request", http.StatusBadRequest)
		return
	}
	state := q.Get("state")
	if len(state) > 1024 {
		redirectQuery(w, r, redirectURI, state, url.Values{"error": {"invalid_request"}})
		return
	}
	fail := func(code string) {
		redirectQuery(w, r, redirectURI, state, url.Values{"error": {code}})
	}
	if q.Get("response_type") != "code" {
		fail("unsupported_response_type")
		return
	}
	if q.Get("code_challenge_method") != "S256" || len(q.Get("code_challenge")) != 43 {
		fail("invalid_request")
		return
	}
	resource := q.Get("resource")
	if resource != base+"/mcp" {
		fail("invalid_target")
		return
	}
	scope := q.Get("scope")
	if scope == "" {
		scope = Scope
	}
	if scope != Scope {
		fail("invalid_scope")
		return
	}
	id, err := i.putConsent(consent{
		clientID:    clientID,
		clientName:  info.name,
		redirectURI: redirectURI,
		challenge:   q.Get("code_challenge"),
		resource:    resource,
		scope:       scope,
		state:       state,
		expires:     time.Now().Add(consentTTL),
	})
	if err != nil {
		fail("server_error")
		return
	}
	host := redirectURI
	if parsed, err := url.Parse(redirectURI); err == nil && parsed.Host != "" {
		host = parsed.Host
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := consentPage.Execute(w, struct {
		Name     string
		Host     string
		ID       string
		Loopback bool
	}{
		Name:     info.name,
		Host:     host,
		ID:       id,
		Loopback: loopbackHost(hostName(redirectURI)),
	}); err != nil {
		http.Error(w, "server_error", http.StatusInternalServerError)
	}
}

func (i *Issuer) consent(w http.ResponseWriter, r *http.Request) {
	if _, err := requestBase(r); err != nil {
		http.Error(w, "invalid host", http.StatusBadRequest)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid_request", http.StatusBadRequest)
		return
	}
	info, ok := i.takeConsent(r.PostForm.Get("consent_id"), time.Now())
	if !ok {
		http.Error(w, "invalid_request", http.StatusBadRequest)
		return
	}
	if r.PostForm.Get("decision") != "allow" {
		redirectQuery(w, r, info.redirectURI, info.state, url.Values{"error": {"access_denied"}})
		return
	}
	code, err := i.putCode(pendingCode{
		clientID:    info.clientID,
		redirectURI: info.redirectURI,
		challenge:   info.challenge,
		resource:    info.resource,
		scope:       info.scope,
		expires:     time.Now().Add(codeTTL),
	})
	if err != nil {
		redirectQuery(w, r, info.redirectURI, info.state, url.Values{"error": {"server_error"}})
		return
	}
	values := url.Values{"code": {code}}
	redirectQuery(w, r, info.redirectURI, info.state, values)
}

func (i *Issuer) token(w http.ResponseWriter, r *http.Request) {
	base, err := requestBase(r)
	if err != nil {
		http.Error(w, "invalid host", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		oauthError(w, http.StatusBadRequest, "invalid_request", "request body is invalid")
		return
	}
	form, err := url.ParseQuery(string(body))
	if err != nil {
		oauthError(w, http.StatusBadRequest, "invalid_request", "request body is invalid")
		return
	}
	if form.Get("client_secret") != "" {
		oauthError(w, http.StatusBadRequest, "invalid_client", "public clients only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	switch form.Get("grant_type") {
	case "authorization_code":
		i.exchangeCode(w, base, form)
	case "refresh_token":
		i.exchangeRefresh(w, base, form)
	default:
		oauthError(w, http.StatusBadRequest, "unsupported_grant_type", "unsupported grant")
	}
}

func (i *Issuer) exchangeCode(w http.ResponseWriter, base string, form url.Values) {
	now := time.Now()
	info, ok := i.takeCode(form.Get("code"), now)
	if !ok || form.Get("client_id") != info.clientID || form.Get("redirect_uri") != info.redirectURI {
		oauthError(w, http.StatusBadRequest, "invalid_grant", "invalid code")
		return
	}
	resource := form.Get("resource")
	if resource != info.resource || resource != base+"/mcp" {
		oauthError(w, http.StatusBadRequest, "invalid_grant", "invalid resource")
		return
	}
	verifier := form.Get("code_verifier")
	if len(verifier) < 43 || len(verifier) > 128 || !pkce(verifier, info.challenge) {
		oauthError(w, http.StatusBadRequest, "invalid_grant", "invalid code verifier")
		return
	}
	i.writeTokens(w, base, info.clientID, info.resource, info.scope, now)
}

func (i *Issuer) exchangeRefresh(w http.ResponseWriter, base string, form url.Values) {
	now := time.Now()
	resource := form.Get("resource")
	if resource != base+"/mcp" {
		oauthError(w, http.StatusBadRequest, "invalid_grant", "invalid resource")
		return
	}
	row, next, err := i.rotateRefresh(form.Get("refresh_token"), form.Get("client_id"), resource, now)
	if errors.Is(err, errInvalidGrant) {
		oauthError(w, http.StatusBadRequest, "invalid_grant", "invalid refresh token")
		return
	}
	if err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "could not refresh")
		return
	}
	access, err := i.sign(base, row.resource, row.scope, now)
	if err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "could not sign")
		return
	}
	writeJSON(w, http.StatusOK, tokenResponse(access, next, row.scope))
}

func (i *Issuer) writeTokens(w http.ResponseWriter, base, clientID, resource, scope string, now time.Time) {
	access, err := i.sign(base, resource, scope, now)
	if err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "could not sign")
		return
	}
	refresh, err := randomToken()
	if err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "could not sign")
		return
	}
	if err := i.storeRefresh(clientID, scope, resource, refresh, now); err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "could not sign")
		return
	}
	writeJSON(w, http.StatusOK, tokenResponse(access, refresh, scope))
}

func tokenResponse(access, refresh, scope string) map[string]any {
	return map[string]any{
		"access_token":  access,
		"token_type":    "Bearer",
		"expires_in":    int(accessTTL.Seconds()),
		"refresh_token": refresh,
		"scope":         scope,
	}
}

func pkce(verifier, challenge string) bool {
	sum := sha256.Sum256([]byte(verifier))
	got := base64.RawURLEncoding.EncodeToString(sum[:])
	if len(got) != len(challenge) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(challenge)) == 1
}

func redirectQuery(w http.ResponseWriter, r *http.Request, raw, state string, values url.Values) {
	u, err := url.Parse(raw)
	if err != nil {
		http.Error(w, "invalid_request", http.StatusBadRequest)
		return
	}
	q := u.Query()
	for key, items := range values {
		for _, item := range items {
			q.Set(key, item)
		}
	}
	if state != "" {
		q.Set("state", state)
	}
	u.RawQuery = q.Encode()
	http.Redirect(w, r, u.String(), http.StatusFound)
}

func hostName(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

func oauthError(w http.ResponseWriter, status int, code, desc string) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, status, map[string]string{"error": code, "error_description": desc})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
