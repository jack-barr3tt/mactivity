package server_test

import (
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"

	api "github.com/jack-barr3tt/mactivity/api/gen"
	"github.com/jack-barr3tt/mactivity/api/internal/server"
	"github.com/jack-barr3tt/mactivity/api/internal/store"
)

func TestActivityAndSummaryHTTP(t *testing.T) {
	path, db := newDB(t)
	_, err := db.Exec(`
		INSERT INTO segments (started_at, ended_at, app_name, bundle_id, window_title, url, hostname)
		VALUES (?, ?, 'Google Chrome', 'com.google.Chrome', 'Board - Jira', 'https://acme.atlassian.net/jira/board', 'acme.atlassian.net')
	`, at(10, 0).UnixMilli(), at(12, 0).UnixMilli())
	require.NoError(t, err)
	require.NoError(t, db.Close())

	app := server.NewApp(store.Open(path))
	resp, err := app.Test(httptest.NewRequest(http.MethodGet, "/v1/activity?from=2026-10-14T11:00:00Z&to=2026-10-14T15:00:00Z", nil))
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	var segments []api.Segment
	decode(t, resp, &segments)
	require.Len(t, segments, 1)
	assert.Equal(t, "acme.atlassian.net", *segments[0].Hostname)
	assert.Equal(t, at(11, 0), segments[0].StartedAt.UTC())

	resp, err = app.Test(httptest.NewRequest(http.MethodGet, "/v1/summary?from=2026-10-14T11:00:00Z&to=2026-10-14T15:00:00Z&group=hostname&contains=jira", nil))
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	var summary []api.Summary
	decode(t, resp, &summary)
	require.Len(t, summary, 1)
	assert.Equal(t, "acme.atlassian.net", summary[0].Key)
	assert.InDelta(t, 3600, summary[0].Seconds, 0.001)
}

func TestCurrentAndBadRangeHTTP(t *testing.T) {
	path, db := newDB(t)
	_, err := db.Exec(`
		INSERT INTO segments (started_at, ended_at, app_name, bundle_id, window_title, url, hostname)
		VALUES (?, NULL, 'Code', 'com.apple.dt.Xcode', 'mactivity', NULL, NULL)
	`, at(11, 0).UnixMilli())
	require.NoError(t, err)
	require.NoError(t, db.Close())

	app := server.NewApp(store.Open(path))
	resp, err := app.Test(httptest.NewRequest(http.MethodGet, "/v1/current", nil))
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	var seg api.Segment
	decode(t, resp, &seg)
	assert.Equal(t, "Code", seg.AppName)

	resp, err = app.Test(httptest.NewRequest(http.MethodGet, "/v1/activity?from=2026-10-14T15:00:00Z&to=2026-10-14T11:00:00Z", nil))
	require.NoError(t, err)
	require.Equal(t, http.StatusBadRequest, resp.StatusCode)
	var body api.Error
	decode(t, resp, &body)
	assert.Equal(t, "from must be before to", body.Message)
}

func TestCurrentNotRecording(t *testing.T) {
	app := server.NewApp(store.Open(filepath.Join(t.TempDir(), "missing.db")))
	resp, err := app.Test(httptest.NewRequest(http.MethodGet, "/v1/current", nil))
	require.NoError(t, err)
	require.Equal(t, http.StatusNotFound, resp.StatusCode)
}

func newDB(t *testing.T) (string, *sql.DB) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "activity.db")
	db, err := sql.Open("sqlite", path)
	require.NoError(t, err)
	schema, err := os.ReadFile(schemaPath(t))
	require.NoError(t, err)
	_, err = db.Exec(string(schema))
	require.NoError(t, err)
	return path, db
}

func schemaPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	require.True(t, ok)
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "db", "schema.sql")
}

func decode(t *testing.T, resp *http.Response, dest any) {
	t.Helper()
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(body, dest))
}

func at(hour, minute int) time.Time {
	return time.Date(2026, 10, 14, hour, minute, 0, 0, time.UTC)
}
