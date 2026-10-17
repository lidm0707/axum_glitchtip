PORT := 3000
BASE_URL ?= http://host.docker.internal:$(PORT)
COMPOSE_GLITCHTIP := docker/docker-compose.glitchtip.yml
COMPOSE_BACKEND := docker/docker-compose.backend.yml
K6_SCRIPT := k6/load-test.js
K6_REPORT_DIR := k6/reports
K6_REPORT := $(K6_REPORT_DIR)/report.html
K6_IMAGE := grafana/k6:latest

.PHONY: help build run check clippy fmt fmt-check watch compose-up compose-down compose-logs compose-status check-glitchtip send-test-log up-backend down-backend logs-backend up-glitchtip down-glitchtip logs-glitchtip k6 dev clean

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build the app
	cargo build

run: ## Run the app
	cargo run

dev: ## Run app and k6 needs separate terminals, this just runs clippy+run
	cargo clippy && cargo run

check: ## cargo check
	cargo check

clippy: ## cargo clippy
	cargo clippy

fmt: ## Format code
	cargo fmt

fmt-check: ## Check formatting
	cargo fmt --check

compose-up: ## Start the whole stack (GlitchTip + backend)
	docker compose -f $(COMPOSE_GLITCHTIP) up -d && \
	docker compose -f $(COMPOSE_BACKEND) up -d --build

compose-down: ## Stop everything
	docker compose -f $(COMPOSE_BACKEND) down && \
	docker compose -f $(COMPOSE_GLITCHTIP) down

compose-logs: ## Tail GlitchTip logs
	docker compose -f $(COMPOSE_GLITCHTIP) logs -f glitchtip

COMPOSE_STATUS := docker compose -f $(COMPOSE_GLITCHTIP) ps
WEB_URL ?= http://localhost:9000

compose-status: ## Check GlitchTip stack: containers, db, worker, web
	@echo "=== containers ==="
	@$(COMPOSE_STATUS) --format 'table {{.Name}}\t{{.Status}}'
	@echo "\n=== db (postgres) ==="
	@docker exec axum_glithip-db pg_isready -U glitchtip -d duck && echo "db: OK" || echo "db: FAIL"
	@echo "\n=== worker (heartbeat via valkey) ==="
	@alive=$$(docker exec axum_glithip-valkey valkey-cli --scan --pattern '{vt}:alive:*' | head -n 1); \
	if [ -n "$$alive" ]; then \
		ttl=$$(docker exec axum_glithip-valkey valkey-cli ttl "$$alive"); \
		echo "worker: ALIVE ($$alive, ttl $$ttl s)"; \
	else \
		echo "worker: NO HEARTBEAT (starting or dead — check logs below)"; \
		docker logs axum_glithip-web 2>&1 | tail -n 20; \
		exit 1; \
	fi
	@echo "\n=== scheduler (periodic tasks last run) ==="
	@now=$$(date +%s); \
	docker exec axum_glithip-valkey valkey-cli --scan --pattern '{vt}:scheduler:vtasks_last_run:*' | while read k; do \
		ts=$$(docker exec axum_glithip-valkey valkey-cli get "$$k"); \
		age=$$(echo "$$now $$ts" | awk '{printf "%d", $$1 - $$2}'); \
		task=$$(echo "$$k" | sed 's/.*last_run://'); \
		echo "$$task: last ran $$age s ago"; \
	done | sort
	@echo "\n=== web (API liveness) ==="
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(WEB_URL)/api/0/organizations/); \
	case "$$code" in \
		200|401|403) echo "web: OK (HTTP $$code)" ;; \
		*) echo "web: FAIL (HTTP $$code)"; exit 1 ;; \
	esac
	@echo "\n=== done ==="

DB_CONTAINER := axum_glithip-db
WEB_CONTAINER := axum_glithip-web
VALKEY_CONTAINER := axum_glithip-valkey
LOG_TAIL_LINES := 10
LOG_SCAN_LINES := 300
COLD_STORAGE_DIR := /app/glitchtip/cold-storage

check-glitchtip: ## Deep check: worker, pg, valkey, duckdb, spans, logs
	@fails=0; \
	echo "=== 1. worker (valkey heartbeat) ==="; \
	alive=$$(docker exec $(VALKEY_CONTAINER) valkey-cli --scan --pattern '{vt}:alive:*' | head -n 1); \
	if [ -n "$$alive" ]; then \
		ttl=$$(docker exec $(VALKEY_CONTAINER) valkey-cli ttl "$$alive"); \
		echo "OK: ALIVE ($$alive, ttl $$ttl s)"; \
	else \
		echo "FAIL: no heartbeat"; fails=1; \
	fi; \
	echo "\n=== 2. postgres ==="; \
	if docker exec $(DB_CONTAINER) pg_isready -U glitchtip -d duck >/dev/null 2>&1; then \
		echo "OK: accepting connections"; \
	else \
		echo "FAIL: pg_isready failed"; fails=1; \
	fi; \
	echo "\n=== 3. valkey ==="; \
	ping=$$(docker exec $(VALKEY_CONTAINER) valkey-cli ping); \
	if [ "$$ping" = "PONG" ]; then \
		echo "OK: PONG"; \
	else \
		echo "FAIL: $$ping"; fails=1; \
	fi; \
	echo "\n=== 4. duckdb (in-container query) ==="; \
	duk=$$(docker exec $(WEB_CONTAINER) python -c "import duckdb; print(duckdb.sql('select 42 as ok').fetchone()[0])" 2>&1); \
	if [ "$$duk" = "42" ]; then \
		echo "OK: duckdb query works"; \
	else \
		echo "FAIL: $$duk"; fails=1; \
	fi; \
	parquet=$$(docker exec $(WEB_CONTAINER) sh -c 'ls $(COLD_STORAGE_DIR) 2>/dev/null | grep -c parquet'); \
	echo "parquet files: $$parquet$$([ "$$parquet" -eq 0 ] && echo ' (empty until child spans arrive)')"; \
	echo "\n=== 5. spans in pg ==="; \
	spans=$$(docker exec $(DB_CONTAINER) psql -U glitchtip -d duck -tAc 'select count(*) from performance_spanstaging'); \
	txns=$$(docker exec $(DB_CONTAINER) psql -U glitchtip -d duck -tAc 'select count(*) from performance_transactiongroup'); \
	echo "spanstaging=$$spans transactiongroups=$$txns"; \
	if [ "$$spans" -gt 0 ]; then echo "OK: spans pending promote"; \
	else echo "WARN: 0 spans (app sends no child spans — tracing::instrument is not a sentry span)"; \
	fi; \
	echo "\n=== 6. last worker msg ==="; \
	docker logs $(WEB_CONTAINER) 2>&1 | grep -ia 'vtasks\|worker\|promote\|heartbeat\|task' | tail -n $(LOG_TAIL_LINES); \
	echo "\n=== 7. glitchtip log errors/warnings (last $(LOG_SCAN_LINES) lines) ==="; \
	logs=$$(docker logs --tail $(LOG_SCAN_LINES) $(WEB_CONTAINER) 2>&1); \
	errs=$$(printf '%s\n' "$$logs" | grep -icE '\[error\]|traceback|critical|exception|internal server error'); \
	warns=$$(printf '%s\n' "$$logs" | grep -icE '\[warning\]|\[warn\]'); \
	echo "errors=$$errs warnings=$$warns"; \
	if [ "$$errs" -gt 0 ]; then \
		echo "-- recent errors --"; \
		printf '%s\n' "$$logs" | grep -inE '\[error\]|traceback|critical|exception|internal server error' | tail -n $(LOG_TAIL_LINES); \
		fails=1; \
	else \
		echo "OK: no errors in recent logs"; \
	fi; \
	echo "\n=== result: $$([ $$fails -eq 0 ] && echo ALL OK || echo FAILURES) ==="; \
	exit $$fails

GLITCHTIP_URL ?= http://localhost:9000
PROJECT1_ID := 2
PROJECT1_KEY := ad28ca6b-df24-46c4-8a3b-0723336cf96f
TEST_LOG_MSG := log line from outside (project1)

send-test-log: ## Send a test event + log from outside into GlitchTip project1
	@key=$(PROJECT1_KEY); eid=$$(uuidgen | tr 'A-Z' 'a-z'); \
	curl -s -X POST "$(GLITCHTIP_URL)/api/$(PROJECT1_ID)/store/" \
		-H "x-sentry-auth: Sentry sentry_key=$$key, sentry_version=7, sentry_client=custom/1.0" \
		-H "content-type: application/json" \
		-d "{\"event_id\":\"$$eid\",\"timestamp\":$$(date +%s),\"platform\":\"python\",\"level\":\"error\",\"message\":\"external test event\"}" \
		-w '\nstore: HTTP %{http_code}\n'; \
	printf '{"event_id":"%s","sent_at":"%s"}\n{"type":"log","item_count":1,"content_type":"application/vnd.sentry.items.log+json"}\n{"items":[{"trace_id":"%s","timestamp":%s,"level":"warn","body":"$(TEST_LOG_MSG)"}]}\n' \
		"$$(uuidgen | tr 'A-Z' 'a-z')" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$(uuidgen | tr -d '-' | tr 'A-Z' 'a-z')" "$$(date +%s)" | \
		curl -s -X POST "$(GLITCHTIP_URL)/api/$(PROJECT1_ID)/envelope/?sentry_key=$$key" \
			-H "content-type: application/x-sentry-envelope" --data-binary @- \
			-w '\nenvelope: HTTP %{http_code}\n'; \
	sleep 3; \
	count=$$(docker exec $(DB_CONTAINER) psql -U glitchtip -d duck -tAc "select count(*) from logs_logevent where project_id=$(PROJECT1_ID)"); \
	echo "logs_logevent(project1) = $$count"

up-backend: ## Start/rebuild only the Rust backend
	docker compose -f $(COMPOSE_BACKEND) up -d --build

down-backend: ## Stop only the backend
	docker compose -f $(COMPOSE_BACKEND) down

logs-backend: ## Tail backend logs
	docker compose -f $(COMPOSE_BACKEND) logs -f

up-glitchtip: ## Start GlitchTip stack (db, valkey, web)
	docker compose -f $(COMPOSE_GLITCHTIP) up -d db valkey cold-storage-init glitchtip

down-glitchtip: ## Stop GlitchTip web only (db/valkey keep running)
	docker compose -f $(COMPOSE_GLITCHTIP) rm -sf glitchtip

logs-glitchtip: ## Tail glitchtip web logs
	docker compose -f $(COMPOSE_GLITCHTIP) logs -f glitchtip

k6: ## Run k6 load test, show results and open HTML report
	mkdir -p $(K6_REPORT_DIR) && \
	docker run --rm -v $(PWD)/k6:/k6 \
		-e K6_WEB_DASHBOARD=true \
		-e K6_WEB_DASHBOARD_EXPORT=/k6/reports/report.html \
		-e BASE_URL=$(BASE_URL) \
		$(K6_IMAGE) run \
		--summary-export=/k6/reports/summary.json \
		/k6/load-test.js; \
	echo "\n=== RESULT ==="; \
	grep -E '"http_req_duration"|"http_req_failed"|"checks"|"iterations"' $(K6_REPORT_DIR)/summary.json || true; \
	echo "=== full report: $(K6_REPORT) ==="; open $(K6_REPORT)


clean: ## Clean cargo artifacts
	cargo clean
