SHELL := /bin/bash
ROOT := $(CURDIR)
BACKEND := $(ROOT)/pulse_trade_backend
FRONTEND := $(ROOT)/pulse_trade_frontend

# Go's build and module caches are kept inside the repository. That keeps the
# toolchain working in sandboxed environments (nothing is written to ~/go or
# ~/Library) and makes `make backend-test` reproducible after one `go mod download`.
export GOCACHE := $(BACKEND)/.cache/go-build
export GOMODCACHE := $(BACKEND)/.cache/gomod

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- Backend ---------------------------------------------------------------

.PHONY: backend-deps
backend-deps: ## Download and tidy Go module dependencies
	cd $(BACKEND) && go mod download && go mod tidy

.PHONY: backend-run
backend-run: ## Run the market-data backend on 0.0.0.0:8080
	cd $(BACKEND) && go run ./cmd/server

.PHONY: backend-build
backend-build: ## Build the backend binary into pulse_trade_backend/bin/
	cd $(BACKEND) && CGO_ENABLED=0 go build -trimpath -o bin/pulsetrade-server ./cmd/server

.PHONY: backend-test
backend-test: ## Run backend unit and integration tests with the race detector
	cd $(BACKEND) && go test ./... -race -count=1

.PHONY: backend-cover
backend-cover: ## Report backend test coverage (informational)
	cd $(BACKEND) && go test ./... -coverprofile=coverage.out && go tool cover -func=coverage.out | tail -1

.PHONY: backend-fmt
backend-fmt: ## Format backend Go sources
	cd $(BACKEND) && gofmt -l -w .

.PHONY: backend-lint
backend-lint: ## Vet and lint the backend
	cd $(BACKEND) && go vet ./... && gofmt -l . \
		&& { command -v golangci-lint >/dev/null && golangci-lint run ./... || echo "golangci-lint not installed; ran go vet + gofmt only"; }

# --- Frontend --------------------------------------------------------------

.PHONY: frontend-deps
frontend-deps: ## Resolve Flutter packages
	cd $(FRONTEND) && flutter pub get

.PHONY: frontend-gen
frontend-gen: ## Regenerate json_serializable DTO codecs
	cd $(FRONTEND) && dart run build_runner build --delete-conflicting-outputs

.PHONY: frontend-run
frontend-run: ## Run the app on the connected device or emulator
	cd $(FRONTEND) && flutter run

.PHONY: frontend-test
frontend-test: ## Run frontend unit and widget tests
	cd $(FRONTEND) && flutter test

.PHONY: frontend-analyze
frontend-analyze: ## Format-check and analyze the frontend
	cd $(FRONTEND) && dart format --set-exit-if-changed lib test && flutter analyze

.PHONY: frontend-build
frontend-build: ## Build a debug APK
	cd $(FRONTEND) && flutter build apk --debug

# --- Combined --------------------------------------------------------------

.PHONY: test
test: backend-test frontend-test ## Run every test suite

.PHONY: demo
demo: ## Print the steps for a live demo and start the backend
	@echo "1. Backend:    make backend-run        (listens on http://0.0.0.0:8080)"
	@echo "2. Emulator:   http://10.0.2.2:8080  +  ws://10.0.2.2:8080/ws"
	@echo "3. App:        cd pulse_trade_frontend && flutter run"
	@echo "4. Health:     curl -s localhost:8080/health | jq"
	@echo "5. Metrics:    curl -s localhost:8080/api/v1/metrics/summary | jq"
	$(MAKE) backend-run

.PHONY: reset-data
reset-data: ## Delete the metrics database
	rm -rf $(BACKEND)/data
