---
name: axum-glitchip-dev
description: Develop and run this axum app that reports errors to self-hosted GlitchTip, including the Makefile targets, DSN setup, and k6 load-test workflow.
---

# axum-glitchip dev workflow

Instructions for working in the `axum_glithip` repo: an axum API that sends mock error events to self-hosted GlitchTip, load-tested with k6.

## Layout

- `src/main.rs` — entry point, `sentry::init` with the GlitchTip DSN
- `src/routes.rs` — `GET /health`, `GET /api/hit`, `GET /api/error`
- `src/service.rs`, `src/state.rs`, `src/db.rs`, `src/config.rs` — app layers
- `docker/` — GlitchTip compose stack
- `k6/` — load-test scripts
- `Makefile` — single entry point for everything

## Workflow

1. Start the GlitchTip stack: `make compose-up`. Open http://localhost:9000, create an account and project (platform: Rust), copy the DSN.
2. The DSN goes in `src/main.rs` inside `sentry::init`, format: `http://<key>@localhost:9000/<project_id>`.
3. Run the app: `make run` (listens on port 3000).
4. Exercise it: `GET /health` for liveness, `GET /api/hit` increments an atomic counter, `GET /api/error` sends an error event to GlitchTip and returns 500.
5. Load test: `make k6` (full), `make k6-quick` (light), or `BASE_URL=... make k6` to override the target. Every 10th iteration hits `/api/error` — verify events appear in the GlitchTip UI.
6. Tear down: `make compose-down`.

## Conventions

- Always run `cargo check && cargo clippy` after finishing a change.
- Never read or modify `.env` or `wrangler.toml` if present.
- Small functions, zero-copy first, no hardcoded values (use `const`), prefer enums over magic strings.
