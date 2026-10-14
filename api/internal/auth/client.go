package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/oauthex"
)

const cimdTTL = 5 * time.Minute

type clientInfo struct {
	name      string
	redirects []string
}

func (i *Issuer) lookupClient(ctx context.Context, id string) (clientInfo, error) {
	if isCIMD(id) {
		return i.fetchCIMD(ctx, id)
	}
	name, redirects, ok, err := i.registeredClient(id)
	if err != nil {
		return clientInfo{}, err
	}
	if !ok {
		return clientInfo{}, errUnknownClient
	}
	return clientInfo{name: name, redirects: redirects}, nil
}

func (i *Issuer) fetchCIMD(ctx context.Context, id string) (clientInfo, error) {
	now := time.Now()
	i.mu.Lock()
	if cached, ok := i.cimd[id]; ok && now.Before(cached.expires) {
		i.mu.Unlock()
		return clientInfo{name: cached.name, redirects: cached.redirects}, nil
	}
	i.mu.Unlock()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, id, nil)
	if err != nil {
		return clientInfo{}, errUnknownClient
	}
	resp, err := cimdClient.Do(req)
	if err != nil {
		return clientInfo{}, errUnknownClient
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return clientInfo{}, errUnknownClient
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20+1))
	if err != nil || len(body) > 1<<20 {
		return clientInfo{}, errUnknownClient
	}
	var doc struct {
		ClientID     string   `json:"client_id"`
		ClientName   string   `json:"client_name"`
		RedirectURIs []string `json:"redirect_uris"`
	}
	if err := json.Unmarshal(body, &doc); err != nil || doc.ClientID != id || len(doc.RedirectURIs) == 0 {
		return clientInfo{}, errUnknownClient
	}
	for _, raw := range doc.RedirectURIs {
		if err := validateRedirect(raw); err != nil {
			return clientInfo{}, errUnknownClient
		}
	}
	name := doc.ClientName
	if name == "" {
		name = "MCP client"
	}
	i.mu.Lock()
	i.cimd[id] = cimdEntry{name: name, redirects: doc.RedirectURIs, expires: now.Add(cimdTTL)}
	i.mu.Unlock()
	return clientInfo{name: name, redirects: doc.RedirectURIs}, nil
}

func isCIMD(id string) bool {
	u, err := url.Parse(id)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" || u.RawQuery != "" {
		return false
	}
	return u.Path != "" && u.Path != "/"
}

func validateRedirect(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" || u.Fragment != "" || u.User != nil {
		return errInvalidRedirect
	}
	switch strings.ToLower(u.Scheme) {
	case "http":
		if !loopbackHost(u.Hostname()) {
			return errInvalidRedirect
		}
	case "https":
		if u.Hostname() == "" {
			return errInvalidRedirect
		}
	case "file", "javascript", "data", "blob":
		return errInvalidRedirect
	default:
		if u.Host == "" && u.Opaque == "" && u.Path == "" {
			return errInvalidRedirect
		}
	}
	return nil
}

func redirectAllowed(redirects []string, raw string) bool {
	for _, candidate := range redirects {
		if candidate == raw {
			return true
		}
	}
	return false
}

func validateRegistration(meta oauthex.ClientRegistrationMetadata) error {
	if meta.TokenEndpointAuthMethod != "" && meta.TokenEndpointAuthMethod != "none" {
		return errInvalidClientMetadata
	}
	if len(meta.RedirectURIs) == 0 || len(meta.RedirectURIs) > 16 {
		return errInvalidRedirect
	}
	for _, raw := range meta.RedirectURIs {
		if err := validateRedirect(raw); err != nil {
			return err
		}
	}
	if len(meta.GrantTypes) > 0 && !onlyGrants(meta.GrantTypes) {
		return errInvalidClientMetadata
	}
	if len(meta.ResponseTypes) > 0 && (len(meta.ResponseTypes) != 1 || meta.ResponseTypes[0] != "code") {
		return errInvalidClientMetadata
	}
	return nil
}

func onlyGrants(grants []string) bool {
	sawCode := false
	for _, grant := range grants {
		switch grant {
		case "authorization_code":
			sawCode = true
		case "refresh_token":
		default:
			return false
		}
	}
	return sawCode
}

func loopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func loopbackMCP(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" || !loopbackHost(u.Hostname()) {
		return false
	}
	return u.Path == "/mcp" && u.RawQuery == "" && u.Fragment == ""
}

func loopbackOrigin(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	return loopbackHost(u.Hostname())
}

func requestBase(r *http.Request) (string, error) {
	host := r.Host
	if host == "" {
		return "", errBadHost
	}
	name, _, err := net.SplitHostPort(host)
	if err != nil {
		name = host
	}
	name = strings.Trim(name, "[]")
	if !loopbackHost(name) {
		return "", errBadHost
	}
	return "http://" + host, nil
}

var cimdClient = &http.Client{
	Timeout: 5 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	},
	Transport: &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
			if err != nil {
				return nil, err
			}
			if len(ips) == 0 {
				return nil, errors.New("no addresses")
			}
			for _, ip := range ips {
				if !publicIP(ip.IP) {
					return nil, errors.New("host is not public")
				}
			}
			return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ips[0].IP.String(), port))
		},
	},
}

func publicIP(ip net.IP) bool {
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
		return false
	}
	return true
}

var (
	errUnknownClient         = errors.New("unknown client")
	errInvalidRedirect       = errors.New("invalid redirect uri")
	errInvalidClientMetadata = errors.New("invalid client metadata")
	errBadHost               = errors.New("host is not loopback")
)
