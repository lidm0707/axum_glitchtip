# GlitchTip Cold Storage (DuckDB / Parquet) — Setup & Debugging Notes

This document explains how the GlitchTip cold-storage pipeline works in this
project's `docker/docker-compose.yml`, why parquet files may silently never
appear, and the debugging steps that traced the problem.

## Overview

The Rust backend (`src/`) sends tracing events and spans to a self-hosted
GlitchTip instance through the Sentry protocol. With DuckDB mode enabled,
GlitchTip promotes old performance spans from Postgres into Parquet files on
disk ("cold storage") so the span-breakdown UI can query them cheaply.

```
backend (axum + sentry-rust)
    │  envelope POST /api/{project}/envelope/
    ▼
glitchtip web (granian ASGI)
    │  enqueue task
    ▼
embedded worker (celery, same process)
    │  writes rows
    ▼
postgres: performance_spanstaging
    │  celery beat schedule: promote-spans
    ▼
/data (named volume) — parquet files
```

## Relevant compose configuration

| Setting | Value | Purpose |
|---|---|---|
| `GLITCHTIP_ENABLE_DUCKDB` | `"true"` | Opt in to span ingestion + parquet promotion |
| `GLITCHTIP_COLD_STORAGE_DIR` | `/data` | Where parquet files are written inside the container |
| `GLITCHTIP_EMBED_WORKER` | `"true"` | Run the celery worker inside the web process (dev only) |
| `coldstorage:/data` | named volume | Persist parquet files; must be mounted at the same path as `GLITCHTIP_COLD_STORAGE_DIR` |
| `cold-storage-init` | alpine one-shot | `chown -R 5000:5000 /data` — GlitchTip runs as uid 5000, fresh named volumes are root-owned |

### Key facts that caused confusion

- **Nobody creates the directory manually.** Docker creates the mount point
  automatically when a named volume is mounted over a non-existent path.
  GlitchTip then creates the `cold_storage/performance_spans*` subdirectories
  itself when it first writes parquet.
- **The same named volume is mounted twice on purpose**: once in
  `cold-storage-init` (at `/data`, to fix ownership) and once in `glitchtip`
  (also at `/data`, to actually use it). Mount points differ per container;
  the data is the same.
- **`chown` fixes permissions only.** Parquet files require the whole
  pipeline to work: ingest → staging table → `promote-spans` task → write.

## Problems found while debugging

### 1. Root-owned named volume (hidden PermissionError)

A freshly created named volume is owned by root. GlitchTip runs as uid 5000,
so the `promote-spans` task failed with a hidden `PermissionError` when
writing parquet — the container kept running, and the failure was easy to
miss. Fixed by the `cold-storage-init` one-shot service plus
`depends_on: condition: service_completed_successfully`.

### 2. Mounted volume didn't match `GLITCHTIP_COLD_STORAGE_DIR`

At one point `GLITCHTIP_COLD_STORAGE_DIR` was changed to `/data` while the
volume was still mounted at `/app/glitchtip/cold-storage`. The variable then
pointed into the container's writable layer: root-owned (permission error
again) and not persisted. The mount path and the env var must always match.

### 3. Embedded worker silently dies after restart (main culprit)

With `GLITCHTIP_EMBED_WORKER: "true"` on `glitchtip/glitchtip:latest`
(v6.2.6, granian server), the celery worker runs inside the web process.
Observed behavior:

- The web server kept answering `200 OK` to envelope POSTs, so ingestion
  looked healthy.
- But the worker half of the process was dead: no events landed in Postgres,
  `performance_spanstaging` stayed empty, and the `promote-spans` scheduler
  stopped advancing.
- Errors were completely silent — nothing in container logs.

Diagnostics that identified it (all read-only):

```sh
# process list: only granian + its ASGI worker, no active celery work
docker top axum_glithip-web

# is the scheduler advancing? compare with `date -u +%s`
docker exec axum_glithip-valkey valkey-cli get '{vt}:scheduler:vtasks_last_run:promote-spans'

# events arriving?
docker exec axum_glithip-db psql -U glitchtip -d duck \
  -tc "select count(*) from issue_events_issueevent where created > now() - interval '5 minutes'"

# spans waiting for promotion?
docker exec axum_glithip-db psql -U glitchtip -d duck \
  -tc "select count(*) from performance_spanstaging"

# anything actually written to cold storage?
docker exec axum_glithip-web ls -laR /data
```

A second `docker restart axum_glithip-web` brought the worker back and events
flowed again immediately. A separate long-running stack with the identical
config (`glitchtip-dev`, image `glitchtip/glitchtip:6`, also v6.2.6) never
showed this failure in 40+ hours — the instability only appeared after a
container restart. Restarting web without restarting valkey/db seems to be
the trigger.

## DSN / connectivity gotchas (ruled out during debugging)

- GlitchTip rejects the DSN-style key in the URL path; the SDK sends the key
  as a query parameter (`?sentry_key=...`), which works. When testing with
  `curl`, pass the key that way or via `X-Sentry-Auth`, otherwise you get 403
  and may mistake it for a backend problem.
- Envelopes with wrong-year timestamps are accepted with 200 but silently
  dropped (outside retention windows / partitions). Use the current time when
  crafting test envelopes.
- From inside a container, reach the host-published port via
  `host.docker.internal:9000` (works on Docker Desktop for macOS).
- The project key lives in `projects_projectkey.public_key`; verify it
  matches the key in `SENTRY_DSN` if ingestion looks dead.

## Current recommendation

For anything beyond throwaway testing, replace `GLITCHTIP_EMBED_WORKER` with
dedicated services, matching GlitchTip's production layout:

```yaml
  glitchtip-worker:
    image: glitchtip/glitchtip:6        # pin the version
    command: ./manage.py celery_worker
    environment: ...                    # same env as web (DATABASE_URL, VALKEY_HOST, COLD_STORAGE_DIR)
    volumes:
      - coldstorage:/data

  glitchtip-beat:
    image: glitchtip/glitchtip:6
    command: ./manage.py celery_beat
    environment: ...
```

This isolates the worker lifecycle from the web server so a web restart can
no longer silently kill ingestion and span promotion. If staying on the
embedded worker, remember: **if envelopes return 200 but nothing lands in
Postgres, restart the glitchtip web container first.**

## Health-check cheat sheet

| Check | Command | Healthy state |
|---|---|---|
| Worker scheduler alive | `valkey-cli get '{vt}:scheduler:vtasks_last_run:promote-spans'` | Timestamp advances (compare to `date -u +%s`) |
| Events ingested | count `issue_events_issueevent` recent rows | Grows while load is sent |
| Spans staged | `select count(*) from performance_spanstaging` | Non-empty between ingest and promotion |
| Parquet written | `ls -R /data` in the web container | `cold_storage/performance_spans*` directories with files |
| Volume ownership | `ls -la /data` | Owner `app` (uid 5000), not root |
