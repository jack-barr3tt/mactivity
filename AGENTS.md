# mactivity

Conventions for humans and agents. How we write code here.

## Shape

A Swift menu bar agent records focus intervals. A Go process reads that SQLite file and serves the same queries over REST and MCP.

`spec/openapi.yaml` is the HTTP contract. Generate it with `make generate-backend` (`oapi-codegen`, Fiber). Do not hand-write parallel DTO types. Do not edit `api/gen/`; change the spec and regenerate.

The agent is the only writer. The Go process opens the database `query_only`. The file lives at `~/Library/Application Support/mactivity/activity.db` unless `MACTIVITY_DB` is set. Both sides must keep that path.

`db/schema.sql` is the schema. The agent applies it on open. There is no migrate runner. If an existing database is missing `category` or `work_related`, the agent adds that column on open.

Local development is **Makefile + tmux**. `make dev` builds the agent bundle and starts the agent plus the API (air). `make stop` kills the session.

Codegen and lint are per-component targets plus an aggregate: `make generate-backend`; `make lint-api` / `make lint-agent` / `make lint`. golangci-lint is pinned with `api/golangci-lint.mod` / `api/golangci-lint.sum`. SwiftLint is pinned in the Makefile and configured by `agent/.swiftlint.yml`. Swift has no modfile equivalent.

REST listens on `127.0.0.1:8787`. MCP streamable HTTP listens on `127.0.0.1:8788/mcp`. `mactivityd --stdio` is the Cursor transport. `make mcp` prints a config that points at the built binary.

REST and MCP HTTP require an OAuth 2.1 bearer token (MCP authorization, 2025-11-25). The MCP listener is the authorization server: protected-resource metadata, authorization-server metadata, dynamic client registration, a local consent page, and authorization-code with S256 PKCE. Refresh tokens rotate. Access tokens are ES256 JWTs for one hour; the audience is `http://<mcp-host>/mcp` and the only scope is `activity:read`. REST accepts those same tokens. The signing key and client store are `oauth.key` and `oauth.db` next to the activity database. Both listeners stay on loopback and speak HTTP there. `--stdio` does not use this flow.

## Recording

Each focus change closes the open segment and inserts the next one. Identical snapshots are not written. `started_at` and `ended_at` are unix milliseconds. `ended_at` is null only while that segment is still in the foreground and the user has not gone idle.

The status menu has two idle settings, each 1, 2, 5, or 10 minutes, stored in the `mactivity` user defaults and read on each sample. **Idle after** is how long without input before the segment is cut; the default is 5. **Count after activity** is how much of that wait is still recorded; the default is 2, and it cannot be longer than Idle after. When idle reaches Idle after, the open segment closes at last input plus Count after activity and stays closed until the next input. A window-title change during that gap does not open a segment. A playing video in the focused window does not count as idle: the front Chrome or Safari tab has an HTML5 video that is not paused, or the frontmost app is QuickTime, TV, IINA, or VLC and reports that it is playing. Spotify and other audio, and video that is not in the focused window, still time out. If that video was holding the segment open and then stops, the segment ends then.

**Notify when idle** is off unless turned on in the status menu. When it is on and notification permission is granted, reaching Idle after posts a notification and leaves the segment open for 10 seconds. Input or a focused playing video in that window cancels the cutoff, so the block continues; the same snapshot keeps the open row, and a new snapshot is recorded as a normal focus change. A window-title change during the wait does not cancel it. If nothing happens, the segment still closes at the original cutoff. Quit during those 10 seconds commits that cutoff.

Windows are half-open: `[from, to)`. Duration is the overlap only:

`min(ended_at or now, to) - max(started_at, from)`

Chrome (`com.google.Chrome`) also stores the active tab URL and hostname. Other apps leave those null. `contains` is a case-insensitive substring of app name, window title, URL, and hostname, so `jira` can match a tab on `company.atlassian.net`.

On quit, close the open segment (at the pending cutoff when the idle notification is still waiting). On launch, close any segment left open by a crash, ending it at startup.

**Classify windows** is off unless turned on in the status menu. When it is on and a segment opens, the on-device Apple Intelligence model classifies it if that model is available. The label is a category (`code`, `communication`, `docs`, `browse`, `media`, or `other`) and whether the window looks work-related. Recording does not wait on the model, so those columns stay null until the result is written onto that row. A later segment with the same app, bundle id, window title, URL, and hostname copies the newest label. The status item shows the open segment’s label once it exists. `summarize_time` can group by `category` or `work` (`work` and `not_work`). Unlabeled time is left out of those groups.

## Tests

Go tests cover the store, HTTP wiring, and the MCP tool. Tests for package `a` live in package `a_test` and only exercise exported behaviour. `swift test` covers the agent's interval writer. `make test` runs both.

Use `testify/require` and `testify/assert`. Store and HTTP tests use a temp SQLite file and `db/schema.sql`, not the live database.

## Hygiene

Prefer small, explicit changes. Match existing style in the file you are in. Don’t commit secrets. The agent bundle (`agent/Mactivity.app`), `agent/.build/`, and `api/tmp/` are build output.

If an instruction contradicts this file or another project convention, flag it and ask whether it is a one-off exception or a change of convention. If the convention has changed, update the file that owned it.
