package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	sdkmcp "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/jack-barr3tt/mactivity/api/internal/auth"
	"github.com/jack-barr3tt/mactivity/api/internal/mcp"
	"github.com/jack-barr3tt/mactivity/api/internal/server"
	"github.com/jack-barr3tt/mactivity/api/internal/store"
)

func main() {
	stdio := flag.Bool("stdio", false, "serve MCP on stdin/stdout")
	dbFlag := flag.String("db", "", "path to activity.db (default: Application Support, or MACTIVITY_DB)")
	httpAddr := flag.String("http", "127.0.0.1:8787", "REST listen address")
	mcpAddr := flag.String("mcp", "127.0.0.1:8788", "MCP HTTP listen address")
	flag.Parse()

	path := *dbFlag
	if path == "" {
		var err error
		path, err = store.DefaultPath()
		if err != nil {
			slog.Error("database path", "err", err)
			os.Exit(1)
		}
	}

	db := store.Open(path)
	mcpServer := mcp.New(db)
	if *stdio {
		if err := mcpServer.RunStdio(context.Background()); err != nil {
			slog.Error("mcp", "err", err)
			os.Exit(1)
		}
		return
	}

	if err := loopback(*httpAddr); err != nil {
		slog.Error("http address", "err", err)
		os.Exit(1)
	}
	if err := loopback(*mcpAddr); err != nil {
		slog.Error("mcp address", "err", err)
		os.Exit(1)
	}

	issuer, err := auth.Open(filepath.Dir(path))
	if err != nil {
		slog.Error("oauth", "err", err)
		os.Exit(1)
	}
	defer func() { _ = issuer.Close() }()

	app := server.NewApp(db, issuer)
	mcpHTTP := &http.Server{
		Addr: *mcpAddr,
		Handler: issuer.Handler(sdkmcp.NewStreamableHTTPHandler(func(*http.Request) *sdkmcp.Server {
			return mcpServer.MCP()
		}, nil)),
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 2)
	go func() {
		slog.Info("rest", "addr", *httpAddr)
		errCh <- app.Listen(*httpAddr)
	}()
	go func() {
		slog.Info("mcp", "addr", *mcpAddr)
		errCh <- mcpHTTP.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("listen", "err", err)
		}
		stop()
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := mcpHTTP.Shutdown(shutdownCtx); err != nil {
		slog.Error("mcp shutdown", "err", err)
	}
	if err := app.Shutdown(); err != nil {
		slog.Error("rest shutdown", "err", err)
	}
}

func loopback(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("%s must bind a loopback address", addr)
	}
	return nil
}
