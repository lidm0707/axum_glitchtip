# axum_glithip

<p align="center">
  <img src="assets/glitchtip_mascot.png" width="200" alt="glitchtip" />
</p>


Learn project: axum API reporting errors to self-hosted GlitchTip, load-tested with k6.

## Endpoints

- `GET /health` — liveness check
- `GET /api/hit` — atomic hit counter
- `GET /api/error` — sends a mock error event to GlitchTip, returns 500
- `GET /api/span` — warns with the current sentry trace context (span_id/trace_id)
- `GET /` — panics (tests panic capture via the tower sentry layer)

## Quick start

```sh
make help            # list all targets
make up-glitchtip    # start GlitchTip stack (db, valkey, web)
make up-backend      # start/rebuild the Rust backend container
make run             # or run the axum app locally
make k6              # run load test (opens HTML report)
make down-backend    # stop the backend container
make down-glitchtip  # stop the GlitchTip stack
make check-glitchtip # deep check: worker, pg, valkey,

```
