package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrNotFound    = errors.New("not found")
	ErrUnavailable = errors.New("database unavailable")
)

type Segment struct {
	ID          int64
	StartedAt   time.Time
	EndedAt     *time.Time
	AppName     string
	BundleID    string
	WindowTitle *string
	URL         *string
	Hostname    *string
	Category    *string
	WorkRelated *bool
}

type SummaryRow struct {
	Key     string
	Seconds float64
}

type Store struct {
	path string
	mu   sync.Mutex
	db   *sql.DB
}

func DefaultPath() (string, error) {
	if p := os.Getenv("MACTIVITY_DB"); p != "" {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "Application Support", "mactivity", "activity.db"), nil
}

func Open(path string) *Store {
	return &Store{path: path}
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil
	}
	err := s.db.Close()
	s.db = nil
	return err
}

func (s *Store) Timeline(ctx context.Context, from, to, now time.Time) ([]Segment, error) {
	db, err := s.conn()
	if errors.Is(err, ErrUnavailable) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	rows, err := db.QueryContext(ctx, `
		SELECT id, started_at, ended_at, app_name, bundle_id, window_title, url, hostname, category, work_related
		FROM segments
		WHERE started_at < ? AND COALESCE(ended_at, ?) > ?
		ORDER BY started_at ASC, id ASC
	`, to.UnixMilli(), now.UnixMilli(), from.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var out []Segment
	for rows.Next() {
		seg, err := scanSegment(rows)
		if err != nil {
			return nil, err
		}
		clipped, ok := clip(seg, from, to, now)
		if !ok {
			continue
		}
		out = append(out, clipped)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Store) Summary(ctx context.Context, from, to, now time.Time, group, contains string) ([]SummaryRow, error) {
	column, err := groupColumn(group)
	if err != nil {
		return nil, err
	}
	db, err := s.conn()
	if errors.Is(err, ErrUnavailable) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	needle := strings.ToLower(contains)
	query := fmt.Sprintf(`
		SELECT %s AS key,
		       SUM(MIN(COALESCE(ended_at, ?), ?) - MAX(started_at, ?)) / 1000.0 AS seconds
		FROM segments
		WHERE started_at < ?
		  AND COALESCE(ended_at, ?) > ?
		  AND %s IS NOT NULL
		  AND (
		    ? = ''
		    OR instr(lower(ifnull(hostname, '')), ?) > 0
		    OR instr(lower(ifnull(url, '')), ?) > 0
		    OR instr(lower(ifnull(window_title, '')), ?) > 0
		    OR instr(lower(app_name), ?) > 0
		  )
		GROUP BY %s
		HAVING seconds > 0
		ORDER BY seconds DESC, key ASC
	`, column, column, column)
	rows, err := db.QueryContext(
		ctx,
		query,
		now.UnixMilli(),
		to.UnixMilli(),
		from.UnixMilli(),
		to.UnixMilli(),
		now.UnixMilli(),
		from.UnixMilli(),
		needle,
		needle,
		needle,
		needle,
		needle,
	)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var out []SummaryRow
	for rows.Next() {
		var row SummaryRow
		if err := rows.Scan(&row.Key, &row.Seconds); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Store) Current(ctx context.Context) (*Segment, error) {
	db, err := s.conn()
	if errors.Is(err, ErrUnavailable) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	row := db.QueryRowContext(ctx, `
		SELECT id, started_at, ended_at, app_name, bundle_id, window_title, url, hostname, category, work_related
		FROM segments
		WHERE ended_at IS NULL
		ORDER BY started_at DESC, id DESC
		LIMIT 1
	`)
	seg, err := scanSegment(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &seg, nil
}

func (s *Store) conn() (*sql.DB, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		return s.db, nil
	}
	if _, err := os.Stat(s.path); errors.Is(err, os.ErrNotExist) {
		return nil, ErrUnavailable
	} else if err != nil {
		return nil, err
	}
	u := url.URL{
		Scheme:   "file",
		Path:     s.path,
		RawQuery: "_pragma=busy_timeout(5000)&_pragma=query_only(1)",
	}
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	s.db = db
	return db, nil
}

func groupColumn(group string) (string, error) {
	switch group {
	case "hostname":
		return "hostname", nil
	case "app":
		return "app_name", nil
	case "category":
		return "category", nil
	case "work":
		return "CASE work_related WHEN 1 THEN 'work' WHEN 0 THEN 'not_work' END", nil
	default:
		return "", fmt.Errorf("group must be hostname, app, category, or work")
	}
}

type scanner interface {
	Scan(dest ...any) error
}

func scanSegment(row scanner) (Segment, error) {
	var (
		seg      Segment
		started  int64
		ended    sql.NullInt64
		title    sql.NullString
		pageURL  sql.NullString
		host     sql.NullString
		category sql.NullString
		work     sql.NullInt64
	)
	err := row.Scan(
		&seg.ID, &started, &ended, &seg.AppName, &seg.BundleID,
		&title, &pageURL, &host, &category, &work,
	)
	if err != nil {
		return Segment{}, err
	}
	seg.StartedAt = time.UnixMilli(started).UTC()
	if ended.Valid {
		t := time.UnixMilli(ended.Int64).UTC()
		seg.EndedAt = &t
	}
	seg.WindowTitle = stringPtr(title)
	seg.URL = stringPtr(pageURL)
	seg.Hostname = stringPtr(host)
	seg.Category = stringPtr(category)
	if work.Valid {
		value := work.Int64 != 0
		seg.WorkRelated = &value
	}
	return seg, nil
}

func stringPtr(v sql.NullString) *string {
	if !v.Valid {
		return nil
	}
	s := v.String
	return &s
}

func clip(seg Segment, from, to, now time.Time) (Segment, bool) {
	end := now
	if seg.EndedAt != nil {
		end = *seg.EndedAt
	}
	start := seg.StartedAt
	if !start.Before(to) || !end.After(from) {
		return Segment{}, false
	}
	if start.Before(from) {
		start = from
	}
	if end.After(to) {
		end = to
	}
	if !end.After(start) {
		return Segment{}, false
	}
	seg.StartedAt = start.UTC()
	clippedEnd := end.UTC()
	seg.EndedAt = &clippedEnd
	return seg, true
}
