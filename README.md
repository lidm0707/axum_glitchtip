# axum_glithip

Learn project: axum API reporting errors to self-hosted GlitchTip, load-tested with k6.

## Endpoints

- `GET /health` — liveness check
- `GET /api/hit` — atomic hit counter
- `GET /api/error` — sends a mock error event to GlitchTip, returns 500

## Quick start

```sh
make help       # list all targets
make compose-up # start GlitchTip stack
make run        # start the axum app
make k6         # run load test
make compose-down
```

## Run GlitchTip

```sh
make compose-up
```

Open http://localhost:9000, create an account, create a project (platform: Rust), copy the DSN.

Set the DSN in `src/main.rs` (`sentry::init`) — format: `http://<key>@localhost:9000/<project_id>`.

## Run the app

```sh
make run
```

## Run k6

```sh
make k6
# lighter run
make k6-quick
# override target
BASE_URL=http://localhost:3000 make k6
```

Every 10th iteration hits `/api/error`; check events appear in the GlitchTip UI.
