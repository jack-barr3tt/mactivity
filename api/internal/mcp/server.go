package mcp

import (
	"context"
	"errors"
	"fmt"
	"time"

	sdkmcp "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/jack-barr3tt/mactivity/api/internal/store"
)

type Server struct {
	mcp *sdkmcp.Server
	db  *store.Store
	now func() time.Time
}

func New(db *store.Store) *Server {
	s := &Server{db: db, now: time.Now}
	impl := &sdkmcp.Implementation{
		Name:    "mactivity",
		Title:   "mactivity",
		Version: "0.1.0",
	}
	server := sdkmcp.NewServer(impl, nil)
	sdkmcp.AddTool(server, &sdkmcp.Tool{
		Name:        "list_activity",
		Description: "Segments overlapping a half-open window [from, to). Times are clipped to that window.",
	}, s.listActivity)
	sdkmcp.AddTool(server, &sdkmcp.Tool{
		Name:        "summarize_time",
		Description: "Time spent in a half-open window, grouped by hostname, app, category, or work. category is the on-device label. work splits time into work and not_work. Unlabeled segments are left out of those groups. contains is a case-insensitive substring of the app name, window title, URL, or hostname, so jira matches a Jira tab on company.atlassian.net.",
	}, s.summarizeTime)
	sdkmcp.AddTool(server, &sdkmcp.Tool{
		Name:        "current_activity",
		Description: "The segment currently in the foreground. endedAt is null while it is still active.",
	}, s.currentActivity)
	s.mcp = server
	return s
}

func (s *Server) MCP() *sdkmcp.Server {
	return s.mcp
}

func (s *Server) RunStdio(ctx context.Context) error {
	return s.mcp.Run(ctx, &sdkmcp.StdioTransport{})
}

type emptyInput struct{}

type windowInput struct {
	From string `json:"from" jsonschema:"inclusive window start, RFC3339"`
	To   string `json:"to" jsonschema:"exclusive window end, RFC3339"`
}

type summaryInput struct {
	From     string `json:"from" jsonschema:"inclusive window start, RFC3339"`
	To       string `json:"to" jsonschema:"exclusive window end, RFC3339"`
	Group    string `json:"group" jsonschema:"hostname, app, category, or work"`
	Contains string `json:"contains,omitempty" jsonschema:"optional case-insensitive substring matched against app name, window title, URL, and hostname"`
}

type segmentOut struct {
	ID          int64      `json:"id"`
	StartedAt   time.Time  `json:"startedAt"`
	EndedAt     *time.Time `json:"endedAt"`
	AppName     string     `json:"appName"`
	BundleID    string     `json:"bundleId"`
	WindowTitle *string    `json:"windowTitle"`
	URL         *string    `json:"url"`
	Hostname    *string    `json:"hostname"`
	Category    *string    `json:"category"`
	WorkRelated *bool      `json:"workRelated"`
}

type activityOut struct {
	Segments []segmentOut `json:"segments"`
}

type summaryRowOut struct {
	Key     string  `json:"key"`
	Seconds float64 `json:"seconds"`
}

type summaryOut struct {
	Rows []summaryRowOut `json:"rows"`
}

func (s *Server) listActivity(ctx context.Context, _ *sdkmcp.CallToolRequest, in windowInput) (*sdkmcp.CallToolResult, activityOut, error) {
	from, to, err := parseWindow(in.From, in.To)
	if err != nil {
		return nil, activityOut{}, err
	}
	rows, err := s.db.Timeline(ctx, from, to, s.now())
	if err != nil {
		return nil, activityOut{}, err
	}
	out := activityOut{Segments: make([]segmentOut, 0, len(rows))}
	for _, row := range rows {
		out.Segments = append(out.Segments, toSegment(row))
	}
	return nil, out, nil
}

func (s *Server) summarizeTime(ctx context.Context, _ *sdkmcp.CallToolRequest, in summaryInput) (*sdkmcp.CallToolResult, summaryOut, error) {
	from, to, err := parseWindow(in.From, in.To)
	if err != nil {
		return nil, summaryOut{}, err
	}
	switch in.Group {
	case "hostname", "app", "category", "work":
	default:
		return nil, summaryOut{}, errors.New("group must be hostname, app, category, or work")
	}
	rows, err := s.db.Summary(ctx, from, to, s.now(), in.Group, in.Contains)
	if err != nil {
		return nil, summaryOut{}, err
	}
	out := summaryOut{Rows: make([]summaryRowOut, 0, len(rows))}
	for _, row := range rows {
		out.Rows = append(out.Rows, summaryRowOut{Key: row.Key, Seconds: row.Seconds})
	}
	return nil, out, nil
}

func (s *Server) currentActivity(ctx context.Context, _ *sdkmcp.CallToolRequest, _ emptyInput) (*sdkmcp.CallToolResult, segmentOut, error) {
	seg, err := s.db.Current(ctx)
	if errors.Is(err, store.ErrNotFound) {
		return nil, segmentOut{}, errors.New("not recording")
	}
	if err != nil {
		return nil, segmentOut{}, err
	}
	return nil, toSegment(*seg), nil
}

func parseWindow(fromRaw, toRaw string) (time.Time, time.Time, error) {
	from, err := time.Parse(time.RFC3339, fromRaw)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("from: %w", err)
	}
	to, err := time.Parse(time.RFC3339, toRaw)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("to: %w", err)
	}
	if !from.Before(to) {
		return time.Time{}, time.Time{}, errors.New("from must be before to")
	}
	return from, to, nil
}

func toSegment(seg store.Segment) segmentOut {
	return segmentOut{
		ID:          seg.ID,
		StartedAt:   seg.StartedAt,
		EndedAt:     seg.EndedAt,
		AppName:     seg.AppName,
		BundleID:    seg.BundleID,
		WindowTitle: seg.WindowTitle,
		URL:         seg.URL,
		Hostname:    seg.Hostname,
		Category:    seg.Category,
		WorkRelated: seg.WorkRelated,
	}
}
