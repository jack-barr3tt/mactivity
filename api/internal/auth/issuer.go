package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	_ "modernc.org/sqlite"
)

const (
	Scope       = "activity:read"
	accessTTL   = time.Hour
	codeTTL     = time.Minute
	consentTTL  = 5 * time.Minute
	refreshTTL  = 30 * 24 * time.Hour
	keyFileName = "oauth.key"
	dbFileName  = "oauth.db"
)

// ErrInsufficientScope is returned when a token is valid but missing activity:read.
var ErrInsufficientScope = errors.New("insufficient scope")

// Checker validates access tokens for the REST API.
type Checker interface {
	Check(token string) error
}

type accessClaims struct {
	jwt.RegisteredClaims
	Scope string `json:"scope"`
}

type pendingCode struct {
	clientID    string
	redirectURI string
	challenge   string
	resource    string
	scope       string
	expires     time.Time
}

type consent struct {
	clientID    string
	clientName  string
	redirectURI string
	challenge   string
	resource    string
	scope       string
	state       string
	expires     time.Time
}

type cimdEntry struct {
	name      string
	redirects []string
	expires   time.Time
}

// Issuer is the local authorization server. It signs tokens for the MCP
// resource and stores registered clients and refresh tokens beside the
// activity database.
type Issuer struct {
	key *ecdsa.PrivateKey
	db  *sql.DB

	mu       sync.Mutex
	codes    map[string]pendingCode
	consents map[string]consent
	cimd     map[string]cimdEntry
}

// Open loads or creates the signing key and client store in dir.
func Open(dir string) (*Issuer, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	key, err := loadOrCreateKey(filepath.Join(dir, keyFileName))
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", filepath.Join(dir, dbFileName))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS clients (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			redirect_uris TEXT NOT NULL
		);
		CREATE TABLE IF NOT EXISTS refresh_tokens (
			hash TEXT PRIMARY KEY,
			client_id TEXT NOT NULL,
			scope TEXT NOT NULL,
			resource TEXT NOT NULL,
			expires_at INTEGER NOT NULL
		);
	`); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Issuer{
		key:      key,
		db:       db,
		codes:    make(map[string]pendingCode),
		consents: make(map[string]consent),
		cimd:     make(map[string]cimdEntry),
	}, nil
}

func (i *Issuer) Close() error {
	return i.db.Close()
}

// Check reports whether token was signed by this issuer for a loopback MCP resource.
func (i *Issuer) Check(token string) error {
	claims, err := i.parse(token)
	if err != nil {
		return err
	}
	if len(claims.Audience) != 1 || !loopbackMCP(claims.Audience[0]) {
		return errors.New("audience")
	}
	if !scopeHas(claims.Scope, Scope) {
		return ErrInsufficientScope
	}
	if !loopbackOrigin(claims.Issuer) {
		return errors.New("issuer")
	}
	return nil
}

func (i *Issuer) parse(token string) (*accessClaims, error) {
	claims := &accessClaims{}
	parsed, err := jwt.ParseWithClaims(token, claims, func(t *jwt.Token) (any, error) {
		if t.Method == nil || t.Method.Alg() != jwt.SigningMethodES256.Alg() {
			return nil, errors.New("unexpected signing method")
		}
		return &i.key.PublicKey, nil
	}, jwt.WithValidMethods([]string{jwt.SigningMethodES256.Alg()}), jwt.WithExpirationRequired())
	if err != nil || !parsed.Valid {
		return nil, errors.New("invalid token")
	}
	return claims, nil
}

func (i *Issuer) sign(issuer, resource, scope string, now time.Time) (string, error) {
	claims := accessClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer,
			Subject:   "local",
			Audience:  jwt.ClaimStrings{resource},
			ExpiresAt: jwt.NewNumericDate(now.Add(accessTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
		},
		Scope: scope,
	}
	return jwt.NewWithClaims(jwt.SigningMethodES256, claims).SignedString(i.key)
}

func (i *Issuer) saveClient(id, name string, redirects []string) error {
	raw, err := json.Marshal(redirects)
	if err != nil {
		return err
	}
	_, err = i.db.Exec(`INSERT INTO clients (id, name, redirect_uris) VALUES (?, ?, ?)`, id, name, string(raw))
	return err
}

func (i *Issuer) registeredClient(id string) (name string, redirects []string, ok bool, err error) {
	var raw string
	err = i.db.QueryRow(`SELECT name, redirect_uris FROM clients WHERE id = ?`, id).Scan(&name, &raw)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil, false, nil
	}
	if err != nil {
		return "", nil, false, err
	}
	if err := json.Unmarshal([]byte(raw), &redirects); err != nil {
		return "", nil, false, err
	}
	return name, redirects, true, nil
}

func (i *Issuer) putCode(info pendingCode) (string, error) {
	code, err := randomToken()
	if err != nil {
		return "", err
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	i.sweepLocked(time.Now())
	i.codes[code] = info
	return code, nil
}

func (i *Issuer) takeCode(code string, now time.Time) (pendingCode, bool) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.sweepLocked(now)
	info, ok := i.codes[code]
	if !ok {
		return pendingCode{}, false
	}
	delete(i.codes, code)
	if !now.Before(info.expires) {
		return pendingCode{}, false
	}
	return info, true
}

func (i *Issuer) putConsent(info consent) (string, error) {
	id, err := randomToken()
	if err != nil {
		return "", err
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	i.sweepLocked(time.Now())
	i.consents[id] = info
	return id, nil
}

func (i *Issuer) takeConsent(id string, now time.Time) (consent, bool) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.sweepLocked(now)
	info, ok := i.consents[id]
	if !ok {
		return consent{}, false
	}
	delete(i.consents, id)
	if !now.Before(info.expires) {
		return consent{}, false
	}
	return info, true
}

func (i *Issuer) sweepLocked(now time.Time) {
	for code, info := range i.codes {
		if !now.Before(info.expires) {
			delete(i.codes, code)
		}
	}
	for id, info := range i.consents {
		if !now.Before(info.expires) {
			delete(i.consents, id)
		}
	}
	for id, info := range i.cimd {
		if !now.Before(info.expires) {
			delete(i.cimd, id)
		}
	}
}

type refreshRow struct {
	clientID string
	scope    string
	resource string
}

func (i *Issuer) rotateRefresh(presented, clientID, resource string, now time.Time) (refreshRow, string, error) {
	hash := hashToken(presented)
	tx, err := i.db.Begin()
	if err != nil {
		return refreshRow{}, "", err
	}
	defer func() { _ = tx.Rollback() }()

	var row refreshRow
	var exp int64
	err = tx.QueryRow(`SELECT client_id, scope, resource, expires_at FROM refresh_tokens WHERE hash = ?`, hash).
		Scan(&row.clientID, &row.scope, &row.resource, &exp)
	if errors.Is(err, sql.ErrNoRows) {
		return refreshRow{}, "", errInvalidGrant
	}
	if err != nil {
		return refreshRow{}, "", err
	}
	if _, err := tx.Exec(`DELETE FROM refresh_tokens WHERE hash = ?`, hash); err != nil {
		return refreshRow{}, "", err
	}
	if exp <= now.Unix() || row.resource != resource || row.clientID != clientID {
		if err := tx.Commit(); err != nil {
			return refreshRow{}, "", err
		}
		return refreshRow{}, "", errInvalidGrant
	}
	next, err := randomToken()
	if err != nil {
		return refreshRow{}, "", err
	}
	if _, err := tx.Exec(
		`INSERT INTO refresh_tokens (hash, client_id, scope, resource, expires_at) VALUES (?, ?, ?, ?, ?)`,
		hashToken(next), row.clientID, row.scope, row.resource, now.Add(refreshTTL).Unix(),
	); err != nil {
		return refreshRow{}, "", err
	}
	if err := tx.Commit(); err != nil {
		return refreshRow{}, "", err
	}
	return row, next, nil
}

func (i *Issuer) storeRefresh(clientID, scope, resource, token string, now time.Time) error {
	_, err := i.db.Exec(
		`INSERT INTO refresh_tokens (hash, client_id, scope, resource, expires_at) VALUES (?, ?, ?, ?, ?)`,
		hashToken(token), clientID, scope, resource, now.Add(refreshTTL).Unix(),
	)
	return err
}

func loadOrCreateKey(path string) (*ecdsa.PrivateKey, error) {
	key, err := readKey(path)
	if err == nil {
		return key, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	block := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return readKey(path)
	}
	if err != nil {
		return nil, err
	}
	if _, err := f.Write(block); err != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return nil, err
	}
	if err := f.Close(); err != nil {
		return nil, err
	}
	return key, nil
}

func readKey(path string) (*ecdsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("oauth key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("oauth key is not ECDSA")
	}
	return key, nil
}

func randomToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func scopeHas(scope, want string) bool {
	for _, part := range strings.Fields(scope) {
		if part == want {
			return true
		}
	}
	return false
}

func jwkCoords(key *ecdsa.PublicKey) (x, y string) {
	size := (key.Curve.Params().BitSize + 7) / 8
	xb := make([]byte, size)
	yb := make([]byte, size)
	key.X.FillBytes(xb)
	key.Y.FillBytes(yb)
	return base64.RawURLEncoding.EncodeToString(xb), base64.RawURLEncoding.EncodeToString(yb)
}

var errInvalidGrant = errors.New("invalid_grant")
