package auth_test

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	sdkmcp "github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/modelcontextprotocol/go-sdk/oauthex"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/jack-barr3tt/mactivity/api/internal/auth"
	"github.com/jack-barr3tt/mactivity/api/internal/mcp"
	"github.com/jack-barr3tt/mactivity/api/internal/server"
	"github.com/jack-barr3tt/mactivity/api/internal/store"
)

func TestOAuthFlow(t *testing.T) {
	dir := t.TempDir()
	iss, err := auth.Open(dir)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, iss.Close()) })

	handler := iss.Handler(sdkmcp.NewStreamableHTTPHandler(func(*http.Request) *sdkmcp.Server {
		return mcp.New(store.Open(filepath.Join(dir, "activity.db"))).MCP()
	}, nil))
	ts := httptest.NewServer(handler)
	t.Cleanup(ts.Close)
	resource := ts.URL + "/mcp"

	resp, err := http.Get(resource)
	require.NoError(t, err)
	require.Equal(t, http.StatusUnauthorized, resp.StatusCode)
	challenge := resp.Header.Get("WWW-Authenticate")
	assert.Contains(t, challenge, `resource_metadata="`+ts.URL+`/.well-known/oauth-protected-resource"`)
	assert.Contains(t, challenge, `scope="activity:read"`)
	_ = resp.Body.Close()

	var prm oauthex.ProtectedResourceMetadata
	getJSON(t, ts.URL+"/.well-known/oauth-protected-resource", &prm)
	assert.Equal(t, resource, prm.Resource)
	assert.Equal(t, []string{ts.URL}, prm.AuthorizationServers)
	assert.Equal(t, []string{auth.Scope}, prm.ScopesSupported)
	getJSON(t, ts.URL+"/.well-known/oauth-protected-resource/mcp", &prm)

	var meta oauthex.AuthServerMeta
	getJSON(t, ts.URL+"/.well-known/oauth-authorization-server", &meta)
	assert.Equal(t, ts.URL, meta.Issuer)
	assert.Equal(t, ts.URL+"/token", meta.TokenEndpoint)
	assert.Contains(t, meta.CodeChallengeMethodsSupported, "S256")
	assert.True(t, meta.ClientIDMetadataDocumentSupported)
	assert.Contains(t, meta.GrantTypesSupported, "refresh_token")

	var jwks struct {
		Keys []struct {
			Kty string `json:"kty"`
			Alg string `json:"alg"`
		} `json:"keys"`
	}
	getJSON(t, ts.URL+"/.well-known/jwks.json", &jwks)
	require.Len(t, jwks.Keys, 1)
	assert.Equal(t, "EC", jwks.Keys[0].Kty)
	assert.Equal(t, "ES256", jwks.Keys[0].Alg)

	_, status := register(t, ts.URL, "http://example.com/callback")
	assert.Equal(t, http.StatusBadRequest, status)

	clientID, status := register(t, ts.URL, "http://127.0.0.1:1/callback", "cursor://anysphere.cursor-mcp/oauth/callback")
	require.Equal(t, http.StatusCreated, status)
	require.NotEmpty(t, clientID)

	mismatch := authorizeURL(ts.URL, clientID, "http://127.0.0.1:9/callback", resource, "state", challengeS256("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
	resp, err = noRedirect(t).Get(mismatch)
	require.NoError(t, err)
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	_ = resp.Body.Close()

	cimd := authorizeURL(ts.URL, "https://127.0.0.1/oauth/client.json", "http://127.0.0.1:1/callback", resource, "state", challengeS256("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
	resp, err = noRedirect(t).Get(cimd)
	require.NoError(t, err)
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	_ = resp.Body.Close()

	verifier := strings.Repeat("b", 50)
	code := allow(t, ts.URL, clientID, "http://127.0.0.1:1/callback", resource, "xyz", verifier)
	bad := tokenForm(t, ts.URL, url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {"http://127.0.0.1:1/callback"},
		"client_id":     {clientID},
		"resource":      {resource},
		"code_verifier": {"wrong-verifier-wrong-verifier-wrong-verifier"},
	})
	assert.Equal(t, http.StatusBadRequest, bad.StatusCode)
	_ = bad.Body.Close()
	reused := tokenForm(t, ts.URL, url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {"http://127.0.0.1:1/callback"},
		"client_id":     {clientID},
		"resource":      {resource},
		"code_verifier": {verifier},
	})
	assert.Equal(t, http.StatusBadRequest, reused.StatusCode)
	_ = reused.Body.Close()

	verifier = strings.Repeat("c", 50)
	code = allow(t, ts.URL, clientID, "http://127.0.0.1:1/callback", resource, "xyz", verifier)
	wrongResource := tokenForm(t, ts.URL, url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {"http://127.0.0.1:1/callback"},
		"client_id":     {clientID},
		"resource":      {ts.URL + "/other"},
		"code_verifier": {verifier},
	})
	assert.Equal(t, http.StatusBadRequest, wrongResource.StatusCode)
	_ = wrongResource.Body.Close()

	verifier = strings.Repeat("d", 50)
	code = allow(t, ts.URL, clientID, "http://127.0.0.1:1/callback", resource, "xyz", verifier)
	ok := tokenForm(t, ts.URL, url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {"http://127.0.0.1:1/callback"},
		"client_id":     {clientID},
		"resource":      {resource},
		"code_verifier": {verifier},
	})
	require.Equal(t, http.StatusOK, ok.StatusCode)
	var issued struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		TokenType    string `json:"token_type"`
		Scope        string `json:"scope"`
	}
	decode(t, ok, &issued)
	assert.Equal(t, "Bearer", issued.TokenType)
	assert.Equal(t, auth.Scope, issued.Scope)
	assert.Equal(t, resource, jwtAudience(t, issued.AccessToken))

	app := server.NewApp(store.Open(filepath.Join(dir, "missing.db")), iss)
	req := httptest.NewRequest(http.MethodGet, "/v1/current", nil)
	rest, err := app.Test(req)
	require.NoError(t, err)
	assert.Equal(t, http.StatusUnauthorized, rest.StatusCode)
	_ = rest.Body.Close()
	req.Header.Set("Authorization", "Bearer "+issued.AccessToken)
	rest, err = app.Test(req)
	require.NoError(t, err)
	assert.Equal(t, http.StatusNotFound, rest.StatusCode)
	_ = rest.Body.Close()

	mcpReq, err := http.NewRequest(http.MethodPost, resource, strings.NewReader(`{}`))
	require.NoError(t, err)
	mcpReq.Header.Set("Authorization", "Bearer "+issued.AccessToken)
	mcpResp, err := http.DefaultClient.Do(mcpReq)
	require.NoError(t, err)
	assert.NotEqual(t, http.StatusUnauthorized, mcpResp.StatusCode)
	_ = mcpResp.Body.Close()

	other := httptest.NewServer(handler)
	t.Cleanup(other.Close)
	otherReq, err := http.NewRequest(http.MethodPost, other.URL+"/mcp", strings.NewReader(`{}`))
	require.NoError(t, err)
	otherReq.Header.Set("Authorization", "Bearer "+issued.AccessToken)
	otherResp, err := http.DefaultClient.Do(otherReq)
	require.NoError(t, err)
	assert.Equal(t, http.StatusUnauthorized, otherResp.StatusCode)
	_ = otherResp.Body.Close()

	refreshed := tokenForm(t, ts.URL, url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {issued.RefreshToken},
		"client_id":     {clientID},
		"resource":      {resource},
	})
	require.Equal(t, http.StatusOK, refreshed.StatusCode)
	var next struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	decode(t, refreshed, &next)
	assert.NotEqual(t, issued.RefreshToken, next.RefreshToken)
	req = httptest.NewRequest(http.MethodGet, "/v1/current", nil)
	req.Header.Set("Authorization", "Bearer "+next.AccessToken)
	rest, err = app.Test(req)
	require.NoError(t, err)
	assert.Equal(t, http.StatusNotFound, rest.StatusCode)
	_ = rest.Body.Close()

	stale := tokenForm(t, ts.URL, url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {issued.RefreshToken},
		"client_id":     {clientID},
		"resource":      {resource},
	})
	assert.Equal(t, http.StatusBadRequest, stale.StatusCode)
	_ = stale.Body.Close()

	again := tokenForm(t, ts.URL, url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {next.RefreshToken},
		"client_id":     {clientID},
		"resource":      {resource},
	})
	assert.Equal(t, http.StatusOK, again.StatusCode)
	_ = again.Body.Close()
}

func TestNonLoopbackHost(t *testing.T) {
	iss, err := auth.Open(t.TempDir())
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, iss.Close()) })
	req := httptest.NewRequest(http.MethodGet, "http://evil.example/.well-known/oauth-protected-resource", nil)
	req.Host = "evil.example"
	rec := httptest.NewRecorder()
	iss.Handler(http.NotFoundHandler()).ServeHTTP(rec, req)
	assert.Equal(t, http.StatusBadRequest, rec.Code)
}

func allow(t *testing.T, base, clientID, redirectURI, resource, state, verifier string) string {
	t.Helper()
	resp, err := noRedirect(t).Get(authorizeURL(base, clientID, redirectURI, resource, state, challengeS256(verifier)))
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	_ = resp.Body.Close()
	match := regexp.MustCompile(`name="consent_id" value="([^"]+)"`).FindSubmatch(body)
	require.NotNil(t, match)
	assert.Contains(t, string(body), "Cursor")
	assert.Contains(t, string(body), "127.0.0.1:1")

	deny, err := noRedirect(t).PostForm(base+"/authorize", url.Values{"consent_id": {string(match[1])}, "decision": {"deny"}})
	require.NoError(t, err)
	require.Equal(t, http.StatusFound, deny.StatusCode)
	assert.Contains(t, deny.Header.Get("Location"), "error=access_denied")
	assert.Contains(t, deny.Header.Get("Location"), "state="+state)
	_ = deny.Body.Close()

	resp, err = noRedirect(t).Get(authorizeURL(base, clientID, redirectURI, resource, state, challengeS256(verifier)))
	require.NoError(t, err)
	body, err = io.ReadAll(resp.Body)
	require.NoError(t, err)
	_ = resp.Body.Close()
	match = regexp.MustCompile(`name="consent_id" value="([^"]+)"`).FindSubmatch(body)
	require.NotNil(t, match)
	allowResp, err := noRedirect(t).PostForm(base+"/authorize", url.Values{"consent_id": {string(match[1])}, "decision": {"allow"}})
	require.NoError(t, err)
	require.Equal(t, http.StatusFound, allowResp.StatusCode)
	loc, err := url.Parse(allowResp.Header.Get("Location"))
	require.NoError(t, err)
	_ = allowResp.Body.Close()
	assert.Equal(t, state, loc.Query().Get("state"))
	code := loc.Query().Get("code")
	require.NotEmpty(t, code)
	return code
}

func authorizeURL(base, clientID, redirectURI, resource, state, challenge string) string {
	q := url.Values{}
	q.Set("response_type", "code")
	q.Set("client_id", clientID)
	q.Set("redirect_uri", redirectURI)
	q.Set("code_challenge", challenge)
	q.Set("code_challenge_method", "S256")
	q.Set("resource", resource)
	q.Set("state", state)
	q.Set("scope", auth.Scope)
	return base + "/authorize?" + q.Encode()
}

func challengeS256(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func register(t *testing.T, base string, redirects ...string) (string, int) {
	t.Helper()
	body, err := json.Marshal(oauthex.ClientRegistrationMetadata{
		RedirectURIs:            redirects,
		ClientName:              "Cursor",
		TokenEndpointAuthMethod: "none",
	})
	require.NoError(t, err)
	resp, err := http.Post(base+"/register", "application/json", strings.NewReader(string(body)))
	require.NoError(t, err)
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusCreated {
		return "", resp.StatusCode
	}
	var out struct {
		ClientID string `json:"client_id"`
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&out))
	return out.ClientID, resp.StatusCode
}

func tokenForm(t *testing.T, base string, form url.Values) *http.Response {
	t.Helper()
	resp, err := http.Post(base+"/token", "application/x-www-form-urlencoded", strings.NewReader(form.Encode()))
	require.NoError(t, err)
	return resp
}

func getJSON(t *testing.T, raw string, dest any) {
	t.Helper()
	resp, err := http.Get(raw)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	decode(t, resp, dest)
}

func decode(t *testing.T, resp *http.Response, dest any) {
	t.Helper()
	defer func() { _ = resp.Body.Close() }()
	require.NoError(t, json.NewDecoder(resp.Body).Decode(dest))
}

func jwtAudience(t *testing.T, token string) string {
	t.Helper()
	parts := strings.Split(token, ".")
	require.Len(t, parts, 3)
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	require.NoError(t, err)
	var payload map[string]any
	require.NoError(t, json.Unmarshal(raw, &payload))
	switch aud := payload["aud"].(type) {
	case string:
		return aud
	case []any:
		require.Len(t, aud, 1)
		got, ok := aud[0].(string)
		require.True(t, ok)
		return got
	default:
		t.Fatalf("aud %T", payload["aud"])
		return ""
	}
}

func noRedirect(t *testing.T) *http.Client {
	t.Helper()
	return &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
}
