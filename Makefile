.PHONY: agent generate-backend lint-api lint-agent lint test dev stop stop-tmux mcp

OAPI_CODEGEN_VERSION ?= v2.8.0
AIR_VERSION ?= v1.62.0
SWIFTLINT_VERSION ?= 0.59.1
API_DIR := api
AGENT_APP := agent/Mactivity.app
TMUX_SESSION ?= mactivity
SWIFTLINT := $(CURDIR)/.bin/swiftlint

agent:
	swift build --package-path agent
	bin="$$(swift build --package-path agent --show-bin-path)/Mactivity"; \
	rm -rf $(AGENT_APP); \
	mkdir -p $(AGENT_APP)/Contents/MacOS $(AGENT_APP)/Contents/Resources; \
	cp "$$bin" $(AGENT_APP)/Contents/MacOS/Mactivity; \
	cp agent/Info.plist $(AGENT_APP)/Contents/Info.plist; \
	cp db/schema.sql $(AGENT_APP)/Contents/Resources/schema.sql; \
	codesign --force --sign - $(AGENT_APP)

generate-backend:
	cd $(API_DIR) && go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@$(OAPI_CODEGEN_VERSION) \
		-config oapi-codegen.yaml ../spec/openapi.yaml

lint-api:
	cd $(API_DIR) && go run -modfile=golangci-lint.mod github.com/golangci/golangci-lint/v2/cmd/golangci-lint run ./...

lint-agent: $(SWIFTLINT)
	cd agent && $(SWIFTLINT) lint

lint: lint-api lint-agent

test:
	cd $(API_DIR) && go test ./...
	swift test --package-path agent

dev: agent
	@command -v tmux >/dev/null 2>&1 || { echo "tmux is required. Install it (e.g. brew install tmux)."; exit 1; }
	@if tmux has-session -t $(TMUX_SESSION) 2>/dev/null; then \
		echo "tmux session $(TMUX_SESSION) already exists"; \
	else \
		tmux new-session -d -s $(TMUX_SESSION) -n agent -c "$(CURDIR)"; \
		tmux send-keys -t $(TMUX_SESSION):agent '$(CURDIR)/$(AGENT_APP)/Contents/MacOS/Mactivity' C-m; \
		tmux new-window -t $(TMUX_SESSION) -n api -c "$(CURDIR)"; \
		tmux send-keys -t $(TMUX_SESSION):api 'cd api && go run github.com/air-verse/air@$(AIR_VERSION)' C-m; \
	fi
	@if [ -z "$$TMUX" ]; then tmux attach -t $(TMUX_SESSION); fi

stop: stop-tmux

stop-tmux:
	-tmux kill-session -t $(TMUX_SESSION)

mcp:
	cd $(API_DIR) && go build -o tmp/mactivityd ./cmd/mactivityd
	@printf '%s\n' \
		'{' \
		'  "mcpServers": {' \
		'    "mactivity": {' \
		'      "command": "$(CURDIR)/api/tmp/mactivityd",' \
		'      "args": ["--stdio"]' \
		'    }' \
		'  }' \
		'}'

$(SWIFTLINT):
	mkdir -p .bin
	curl -fsSL -o .bin/swiftlint.zip "https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/portable_swiftlint.zip"
	unzip -o .bin/swiftlint.zip -d .bin
	rm -f .bin/swiftlint.zip
	chmod +x $(SWIFTLINT)
