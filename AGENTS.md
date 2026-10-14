# mactivity

Conventions for humans and agents. How we write code here.

## Shape

A Swift menu bar agent records focus intervals. A Go process reads that SQLite file and serves the same queries over REST and MCP.

`spec/openapi.yaml` is the HTTP contract. Generate it with `make generate-backend` (`oapi-codegen`, Fiber). Do not hand-write parallel DTO types. Do not edit `api/gen/`; change the spec and regenerate.

The agent is the only writer. The Go process opens the database `query_only`. The file lives at `~/Library/Application Support/mactivity/activity.db` unless `MACTIVITY_DB` is set. Both sides must keep that path.

`db/schema.sql` is the schema. The agent applies it on open. There is no migrate runner.

Local development is **Makefile + tmux**. `make dev` builds the agent bundle and starts the agent plus the API (air). `make stop-tmux` kills the session.

Codegen and lint are per-component targets plus an aggregate: `make generate-backend`; `make lint-api` / `make lint-agent` / `make lint`. golangci-lint is pinned with `api/golangci-lint.mod` / `api/golangci-lint.sum`. SwiftLint is pinned in the Makefile and configured by `agent/.swiftlint.yml`. Swift has no modfile equivalent.

REST listens on `127.0.0.1:8787`. MCP streamable HTTP listens on `127.0.0.1:8788`. `mactivityd --stdio` is the Cursor transport. `make mcp` prints a config that points at the built binary.

## Recording

Each focus change closes the open segment and inserts the next one. Identical snapshots are not written. `started_at` and `ended_at` are unix milliseconds. `ended_at` is null only while that segment is still in the foreground.

Windows are half-open: `[from, to)`. Duration is the overlap only:

`min(ended_at or now, to) - max(started_at, from)`

Chrome (`com.google.Chrome`) also stores the active tab URL and hostname. Other apps leave those null. `contains` is a case-insensitive substring of app name, window title, URL, and hostname, so `jira` can match a tab on `company.atlassian.net`.

On quit, close the open segment. On launch, close any segment left open by a crash, ending it at startup.

## Tests

Go tests cover the store, HTTP wiring, and the MCP tool. Tests for package `a` live in package `a_test` and only exercise exported behaviour. `swift test` covers the agent's interval writer. `make test` runs both.

Use `testify/require` and `testify/assert`. Store and HTTP tests use a temp SQLite file and `db/schema.sql`, not the live database.

## Hygiene

Prefer small, explicit changes. Match existing style in the file you are in. Don’t commit secrets. The agent bundle (`agent/Mactivity.app`), `agent/.build/`, and `api/tmp/` are build output.

If an instruction contradicts this file or another project convention, flag it and ask whether it is a one-off exception or a change of convention. If the convention has changed, update the file that owned it.
