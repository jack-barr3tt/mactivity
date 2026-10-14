package server

import (
	"errors"
	"net/http"
	"time"

	"github.com/gofiber/fiber/v3"

	api "github.com/jack-barr3tt/mactivity/api/gen"
	"github.com/jack-barr3tt/mactivity/api/internal/store"
)

func NewApp(st *store.Store) *fiber.App {
	app := fiber.New(fiber.Config{
		ErrorHandler: jsonError,
	})
	api.RegisterHandlers(app, New(st))
	return app
}

func jsonError(c fiber.Ctx, err error) error {
	code := http.StatusInternalServerError
	var fe *fiber.Error
	if errors.As(err, &fe) {
		code = fe.Code
	}
	return c.Status(code).JSON(api.Error{Message: err.Error()})
}

type Server struct {
	store *store.Store
	now   func() time.Time
}

func New(st *store.Store) *Server {
	return &Server{store: st, now: time.Now}
}

func (s *Server) ListActivity(c fiber.Ctx, params api.ListActivityParams) error {
	if !params.From.Before(params.To) {
		return badRequest(c, "from must be before to")
	}
	rows, err := s.store.Timeline(c.Context(), params.From, params.To, s.now())
	if err != nil {
		return err
	}
	out := make([]api.Segment, 0, len(rows))
	for _, row := range rows {
		out = append(out, toAPI(row))
	}
	return c.Status(http.StatusOK).JSON(out)
}

func (s *Server) SummarizeTime(c fiber.Ctx, params api.SummarizeTimeParams) error {
	if !params.From.Before(params.To) {
		return badRequest(c, "from must be before to")
	}
	if !params.Group.Valid() {
		return badRequest(c, "group must be hostname or app")
	}
	contains := ""
	if params.Contains != nil {
		contains = *params.Contains
	}
	rows, err := s.store.Summary(c.Context(), params.From, params.To, s.now(), string(params.Group), contains)
	if err != nil {
		return err
	}
	out := make([]api.Summary, 0, len(rows))
	for _, row := range rows {
		out = append(out, api.Summary{Key: row.Key, Seconds: row.Seconds})
	}
	return c.Status(http.StatusOK).JSON(out)
}

func (s *Server) CurrentActivity(c fiber.Ctx) error {
	seg, err := s.store.Current(c.Context())
	if errors.Is(err, store.ErrNotFound) {
		return c.Status(http.StatusNotFound).JSON(api.Error{Message: "not recording"})
	}
	if err != nil {
		return err
	}
	return c.Status(http.StatusOK).JSON(toAPI(*seg))
}

func badRequest(c fiber.Ctx, message string) error {
	return c.Status(http.StatusBadRequest).JSON(api.Error{Message: message})
}

func toAPI(seg store.Segment) api.Segment {
	return api.Segment{
		Id:          seg.ID,
		StartedAt:   seg.StartedAt,
		EndedAt:     seg.EndedAt,
		AppName:     seg.AppName,
		BundleId:    seg.BundleID,
		WindowTitle: seg.WindowTitle,
		Url:         seg.URL,
		Hostname:    seg.Hostname,
	}
}
