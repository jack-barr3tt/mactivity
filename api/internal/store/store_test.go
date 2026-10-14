package store_test

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"

	"github.com/jack-barr3tt/mactivity/api/internal/store"
)

func TestTimelineClipsOverlap(t *testing.T) {
	path, db := newDB(t)
	insert(t, db, at(10, 0), ptr(at(12, 0)), "Google Chrome", "com.google.Chrome", "Jira", "https://acme.atlassian.net/jira/board", "acme.atlassian.net")
	require.NoError(t, db.Close())

	st := store.Open(path)
	t.Cleanup(func() { _ = st.Close() })

	got, err := st.Timeline(context.Background(), at(11, 0), at(15, 0), at(16, 0))
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, at(11, 0), got[0].StartedAt)
	assert.Equal(t, at(12, 0), *got[0].EndedAt)
	assert.Equal(t, "acme.atlassian.net", *got[0].Hostname)
}

func TestTimelineHalfOpenBoundaries(t *testing.T) {
	path, db := newDB(t)
	insert(t, db, at(9, 0), ptr(at(11, 0)), "Slack", "com.tinyspeck.slackmacgap", "Slack", "", "")
	insert(t, db, at(15, 0), ptr(at(16, 0)), "Slack", "com.tinyspeck.slackmacgap", "Slack", "", "")
	require.NoError(t, db.Close())

	st := store.Open(path)
	t.Cleanup(func() { _ = st.Close() })

	got, err := st.Timeline(context.Background(), at(11, 0), at(15, 0), at(16, 0))
	require.NoError(t, err)
	assert.Empty(t, got)
}

func TestSummaryJiraContainsMatchesURL(t *testing.T) {
	path, db := newDB(t)
	insert(t, db, at(10, 0), ptr(at(12, 0)), "Google Chrome", "com.google.Chrome", "Board - Jira", "https://acme.atlassian.net/jira/board", "acme.atlassian.net")
	insert(t, db, at(10, 0), ptr(at(12, 0)), "Slack", "com.tinyspeck.slackmacgap", "Slack", "", "")
	require.NoError(t, db.Close())

	st := store.Open(path)
	t.Cleanup(func() { _ = st.Close() })

	got, err := st.Summary(context.Background(), at(11, 0), at(15, 0), at(16, 0), "hostname", "jira")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "acme.atlassian.net", got[0].Key)
	assert.InDelta(t, 3600, got[0].Seconds, 0.001)
}

func TestSummaryOpenSegmentClipsToNow(t *testing.T) {
	path, db := newDB(t)
	insert(t, db, at(10, 0), nil, "Google Chrome", "com.google.Chrome", "Jira", "https://acme.atlassian.net/jira", "acme.atlassian.net")
	require.NoError(t, db.Close())

	st := store.Open(path)
	t.Cleanup(func() { _ = st.Close() })

	got, err := st.Summary(context.Background(), at(11, 0), at(15, 0), at(12, 0), "app", "")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "Google Chrome", got[0].Key)
	assert.InDelta(t, 3600, got[0].Seconds, 0.001)
}

func TestCurrent(t *testing.T) {
	path, db := newDB(t)
	insert(t, db, at(10, 0), ptr(at(11, 0)), "Slack", "com.tinyspeck.slackmacgap", "old", "", "")
	insert(t, db, at(11, 0), nil, "Code", "com.todesktop.230313mzl4w4u92", "mactivity", "", "")
	require.NoError(t, db.Close())

	st := store.Open(path)
	t.Cleanup(func() { _ = st.Close() })

	got, err := st.Current(context.Background())
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "Code", got.AppName)
	assert.Nil(t, got.EndedAt)
}

func TestTimelineReadsLabel(t *testing.T) {
	path, db := newDB(t)
	_, err := db.Exec(`
		INSERT INTO segments (started_at, ended_at, app_name, bundle_id, window_title, url, hostname, category, work_related)
		VALUES (?, ?, 'Code', 'com.todesktop.230313mzl4w4u92', 'mactivity', NULL, NULL, 'code', 1)
	`, at(10, 0).UnixMilli(), at(12, 0).UnixMilli())
	require.NoError(t, err)
	require.NoError(t, db.Close())

	st := store.Open(path)
	t.Cleanup(func() { _ = st.Close() })

	got, err := st.Timeline(context.Background(), at(11, 0), at(15, 0), at(16, 0))
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.NotNil(t, got[0].Category)
	assert.Equal(t, "code", *got[0].Category)
	require.NotNil(t, got[0].WorkRelated)
	assert.True(t, *got[0].WorkRelated)
}

func TestSummaryGroupsCategoryAndWork(t *testing.T) {
	path, db := newDB(t)
	insertLabeled(t, db, at(10, 0), ptr(at(12, 0)), "code", 1)
	insertLabeled(t, db, at(12, 0), ptr(at(13, 0)), "media", 0)
	insert(t, db, at(13, 0), ptr(at(14, 0)), "Slack", "com.slack", "general", "", "")
	require.NoError(t, db.Close())

	st := store.Open(path)
	t.Cleanup(func() { _ = st.Close() })

	byCategory, err := st.Summary(context.Background(), at(11, 0), at(15, 0), at(16, 0), "category", "")
	require.NoError(t, err)
	require.Len(t, byCategory, 2)
	assert.Equal(t, "code", byCategory[0].Key)
	assert.InDelta(t, 3600, byCategory[0].Seconds, 0.001)
	assert.Equal(t, "media", byCategory[1].Key)
	assert.InDelta(t, 3600, byCategory[1].Seconds, 0.001)

	byWork, err := st.Summary(context.Background(), at(11, 0), at(15, 0), at(16, 0), "work", "")
	require.NoError(t, err)
	require.Len(t, byWork, 2)
	assert.Equal(t, "not_work", byWork[0].Key)
	assert.InDelta(t, 3600, byWork[0].Seconds, 0.001)
	assert.Equal(t, "work", byWork[1].Key)
	assert.InDelta(t, 3600, byWork[1].Seconds, 0.001)
}

func TestCurrentMissing(t *testing.T) {
	st := store.Open(filepath.Join(t.TempDir(), "missing.db"))
	t.Cleanup(func() { _ = st.Close() })

	_, err := st.Current(context.Background())
	require.ErrorIs(t, err, store.ErrNotFound)

	got, err := st.Timeline(context.Background(), at(11, 0), at(15, 0), at(12, 0))
	require.NoError(t, err)
	assert.Empty(t, got)
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

func insert(t *testing.T, db *sql.DB, start time.Time, end *time.Time, appName, bundleID, title, pageURL, host string) {
	t.Helper()
	var ended any
	if end != nil {
		ended = end.UnixMilli()
	}
	_, err := db.Exec(`
		INSERT INTO segments (started_at, ended_at, app_name, bundle_id, window_title, url, hostname)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, start.UnixMilli(), ended, appName, bundleID, nullIfEmpty(title), nullIfEmpty(pageURL), nullIfEmpty(host))
	require.NoError(t, err)
}

func insertLabeled(t *testing.T, db *sql.DB, start time.Time, end *time.Time, category string, work int) {
	t.Helper()
	var ended any
	if end != nil {
		ended = end.UnixMilli()
	}
	_, err := db.Exec(`
		INSERT INTO segments (started_at, ended_at, app_name, bundle_id, window_title, url, hostname, category, work_related)
		VALUES (?, ?, 'App', 'app.id', NULL, NULL, NULL, ?, ?)
	`, start.UnixMilli(), ended, category, work)
	require.NoError(t, err)
}

func nullIfEmpty(v string) any {
	if v == "" {
		return nil
	}
	return v
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

func ptr(t time.Time) *time.Time {
	return &t
}
