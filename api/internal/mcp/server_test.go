package mcp_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	sdkmcp "github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"

	"github.com/jack-barr3tt/mactivity/api/internal/mcp"
	"github.com/jack-barr3tt/mactivity/api/internal/store"
)

func TestSummarizeTimeTool(t *testing.T) {
	path, db := newDB(t)
	_, err := db.Exec(`
		INSERT INTO segments (started_at, ended_at, app_name, bundle_id, window_title, url, hostname)
		VALUES (?, ?, 'Google Chrome', 'com.google.Chrome', 'Board - Jira', 'https://acme.atlassian.net/jira/board', 'acme.atlassian.net')
	`, at(10, 0).UnixMilli(), at(12, 0).UnixMilli())
	require.NoError(t, err)
	require.NoError(t, db.Close())

	ctx := context.Background()
	srv := mcp.New(store.Open(path))
	clientTransport, serverTransport := sdkmcp.NewInMemoryTransports()
	session, err := srv.MCP().Connect(ctx, serverTransport, nil)
	require.NoError(t, err)
	t.Cleanup(func() { _ = session.Close() })

	client := sdkmcp.NewClient(&sdkmcp.Implementation{Name: "test", Version: "0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	require.NoError(t, err)
	t.Cleanup(func() { _ = cs.Close() })

	result, err := cs.CallTool(ctx, &sdkmcp.CallToolParams{
		Name: "summarize_time",
		Arguments: map[string]any{
			"from":     "2026-10-14T11:00:00Z",
			"to":       "2026-10-14T15:00:00Z",
			"group":    "hostname",
			"contains": "jira",
		},
	})
	require.NoError(t, err)
	require.False(t, result.IsError)
	raw, err := json.Marshal(result.StructuredContent)
	require.NoError(t, err)
	var out struct {
		Rows []struct {
			Key     string  `json:"key"`
			Seconds float64 `json:"seconds"`
		} `json:"rows"`
	}
	require.NoError(t, json.Unmarshal(raw, &out))
	require.Len(t, out.Rows, 1)
	assert.Equal(t, "acme.atlassian.net", out.Rows[0].Key)
	assert.InDelta(t, 3600, out.Rows[0].Seconds, 0.001)
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

func at(hour, minute int) time.Time {
	return time.Date(2026, 10, 14, hour, minute, 0, 0, time.UTC)
}
