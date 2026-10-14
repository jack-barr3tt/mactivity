# mactivity

Menu bar agent that records the frontmost Mac app, window title, and the active Chrome tab. A local API and MCP server query that log.

## Local development

Requires Go 1.26+, Swift 6, and tmux.

```sh
make dev
```

- REST: http://127.0.0.1:8787
- MCP HTTP: http://127.0.0.1:8788

The agent is a menu bar app (clock icon). The first launch asks for Accessibility access. Until that is granted, nothing is recorded. If Chrome does not expose the tab URL through Accessibility, macOS will also ask for permission to control Google Chrome.

`make stop-tmux` kills the session.

After changing `spec/openapi.yaml`, run `make generate-backend`. `make mcp` prints a Cursor stdio config.
