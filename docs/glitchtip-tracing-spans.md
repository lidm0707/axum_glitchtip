# GlitchTip Tracing Spans — From `#[tracing::instrument]` to Span Breakdown

This document explains how tracing spans from the Rust backend become child
spans in GlitchTip transactions, why the span-breakdown UI stayed empty, and
the diagnostics (`make check-glitchtip`, `make send-test-log`) used to verify
each stage of the pipeline.

## Overview

The Rust backend uses `sentry-tower` to create a root transaction per HTTP
request, and `#[tracing::instrument]` on handlers/functions. The
`sentry-tracing` layer converts qualifying tracing spans into Sentry child
spans automatically — but only if the layer's filters allow them.

```
axum handler with #[tracing::instrument]        (tracing span, INFO)
    │  sentry-tracing layer: span_filter INFO → on_new_span
    ▼
Sentry child span (parent = root http.server)
    │  on_close → span.finish() when the fn's future resolves
    ▼
envelope POST → glitchtip ingest
    │
    ▼
postgres: performance_spanstaging
    │  promote-spans task (every 300s, spans older than 5 min only)
    ▼
cold storage: cold_storage/performance_spans/org_*/.../chunk_*.parquet
    │
    ▼
span breakdown in transaction UI
```

## Span lifecycle — when does each span stop?

| Layer | Starts | Finishes |
|---|---|---|
| root `http.server` (`SentryHttpLayer`) | request enters middleware | when the response is returned — at that moment the whole transaction is sent to GlitchTip |
| child (`#[tracing::instrument]`) | fn is entered | when the fn's future resolves — `on_close` calls `finish()` automatically |

Children must finish **before** the root. Work spawned outside the request
(`tokio::spawn`) loses its parent and is not recorded in the transaction.
For such cases use a manual `sentry::configure_scope(|s| s.get_span())
.start_child(...)` instead.

## Why `#[tracing::instrument]` spans were missing (root cause)

The original subscriber setup was:

```rust
sentry::integrations::tracing::layer().with_filter(LevelFilter::WARN)
```

`.with_filter` applies to **both events and spans**. The
`sentry-tracing` `on_new_span` implementation consults the layer's
`span_filter` (default: INFO and above) before creating a Sentry span, so
every `#[tracing::instrument]` span (default level INFO) was discarded at
step 1 of the conversion chain:

```
tracing span created
  ① passes span_filter?        ← failed here (WARN filter)
  ② has a parent sentry span?  (root http.server)
  ③ entered and closed         (on_close → finish)
  = sentry child span
```

Meanwhile `tracing::warn!` still arrived, because events are filtered
separately from spans — hence "warnings visible, spans missing".

### Fix — separate event and span filters (`src/main.rs`)

```rust
sentry::integrations::tracing::layer()
    .event_filter(|md| match *md.level() {
        tracing::Level::ERROR => sentry::integrations::tracing::EventFilter::Event,
        tracing::Level::WARN => sentry::integrations::tracing::EventFilter::Log,
        _ => sentry::integrations::tracing::EventFilter::Ignore,
    })
    .span_filter(|md| matches!(*md.level(), tracing::Level::INFO))
```

Events keep the old behavior (ERROR → issue, WARN → log entry); spans at
INFO now become Sentry child spans automatically.

Trade-off: an INFO span filter also captures axum/tower internal spans
(one request yields several spans). Narrow it by target if that is too
noisy, e.g. `md.target().starts_with("axum_glithip")`.

With this change `db.rs` needs no manual span code at all:

```rust
#[tracing::instrument]
pub async fn find_user(id: u64) -> String {
    tokio::time::sleep(std::time::Duration::from_millis(config::DB_LATENCY_MS)).await;
    format!("user-{id}")
}
```

## Checking the current Sentry span from inside a handler

`sentry::configure_scope(|scope| scope.get_span())` returns the active span
object; `get_trace_context()` exposes `span_id` / `trace_id` / `op`.
Attaching this to a warning (see `span_summary()` in `src/routes.rs`) is a
quick way to verify which span a log line belongs to — before the fix every
warning reported `op=Some("http.server")`, proving no child span existed.

## Verifying the pipeline end to end

`make check-glitchtip` inspects every stage:

| # | Check | Healthy state |
|---|---|---|
| 1 | worker heartbeat: valkey key `{vt}:alive:*` (TTL refreshed every 5s) | key present, TTL > 0 |
| 2 | postgres `pg_isready` | accepting connections |
| 3 | valkey `PING` | PONG |
| 4 | duckdb runs `select 42` in the web container + parquet count | 42; parquet files listed |
| 5 | `performance_spanstaging` / `performance_transactiongroup` counts | non-empty between ingest and promotion |
| 6 | last worker messages from container logs | task activity visible |
| 7 | scan recent container logs for errors/warnings | errors=0 (or visible tail for triage) |

Sections 1–3 hard-fail the target (infrastructure); 4–5 warn only, because
an empty parquet/staging table means "no child spans yet", not "broken".

## Sending events/logs from outside (`make send-test-log`)

GlitchTip ingestion has authentication gotchas worth documenting:

- The envelope endpoint accepts the DSN key as a query parameter
  (`?sentry_key=...`) or `Authorization: Bearer <key>` — a plain
  `x-sentry-key` header returns 403 `Denied`.
- The store endpoint (`/api/{project}/store/`) expects the classic
  `x-sentry-auth: Sentry sentry_key=..., sentry_version=7` header.
- OTLP ingest is also supported by the same auth helper.

`make send-test-log` posts one error event and one Sentry log item into
`project1`, then verifies the row landed in `logs_logevent`:

```
store: HTTP 200
envelope: HTTP 200
logs_logevent(project1) = 2
```

## Promotion latency — why the UI lags behind

`promote_spans` in GlitchTip uses a five-minute cutoff and runs every five
minutes:

```python
cutoff = now_dt - timedelta(minutes=5)
```

A span therefore takes **5–10 minutes** from request to visible breakdown:
ingest → staging (immediate) → eligible after 5 min → promoted on the next
schedule tick → parquet → UI. Fresh spans sitting in `spanstaging` are
normal; only rows stuck for multiple promotion cycles indicate a problem.

## EventFilter reference

`EventFilter` (from `sentry::integrations::tracing`) decides what a tracing
**event** (`tracing::warn!`, `error!`, ...) becomes in Sentry. It is the
return value of `event_filter(...)`. Note this only affects events; spans
are governed separately by `span_filter`.

| Variant | Result in Sentry | Typical source |
|---|---|---|
| `EventFilter::Event` | Creates an **Issue** on the Issues page (with stacktrace, occurrence count) | `sentry::capture_error`, or `tracing::error!` |
| `EventFilter::Breadcrumb` | Attaches a **breadcrumb** to the next event in the same request — does not create an issue by itself | INFO/DEBUG logs meant as silent context |
| `EventFilter::Log` | Appears on the project's **Logs** page (same place as `make send-test-log` entries for project1) | `tracing::warn!("{user}")` in `test_span` |
| `EventFilter::Ignore` | Dropped | anything not needed |

Memory aid: **Event = report, Breadcrumb = trail of footsteps, Log = notebook**.

Variants are bitflags, so they combine: `EventFilter::Event |
EventFilter::Log` sends both. The library default is
`ERROR → Event | Log`, `WARN/INFO → Breadcrumb | Log`, rest ignored.

### How to use

Set it on the layer in `src/main.rs`:

```rust
sentry::integrations::tracing::layer()
    // what each event level becomes in Sentry
    .event_filter(|md| match *md.level() {
        tracing::Level::ERROR => sentry::integrations::tracing::EventFilter::Event,
        tracing::Level::WARN => sentry::integrations::tracing::EventFilter::Log,
        tracing::Level::INFO => {
            sentry::integrations::tracing::EventFilter::Breadcrumb
        }
        _ => sentry::integrations::tracing::EventFilter::Ignore,
    })
    // which tracing spans become sentry child spans
    .span_filter(|md| matches!(*md.level(), tracing::Level::INFO))
```

Emitting from code — no extra API needed, the level decides the fate:

```rust
tracing::error!("payment failed"); // → Issue (Event)
tracing::warn!("cache miss");      // → Logs page (Log)
tracing::info!("entered handler"); // → breadcrumb on the next Issue
tracing::debug!("noise");          // → dropped (Ignore)
```

To see breadcrumbs in action: trigger `/api/error` — the captured issue
will list prior INFO breadcrumbs from the same request under
"Breadcrumbs".

Practical tips:

- Don't route WARN to `Event` — warnings become issues and pollute the
  Issues page (one issue per unique message).
- Keep `Ignore` broad: every accepted event costs an envelope over the
  wire to GlitchTip.
- Breadcrumbs need a later Event within the same request to be visible;
  a breadcrumb with no following issue is never shown anywhere.

## Related bugs fixed along the way

- `src/config.rs`: `sentry_dsn()` contained
  `std::env::var("RUST_LOG").expect(...)` — an unused read that panicked at
  startup whenever `RUST_LOG` was unset. Removed.
- Container rebuilds are required for backend code changes:
  `make compose-up` (builds `docker/Dockerfile.backend`). Hitting
  `localhost:3000` while the container runs old code gives misleading
  results — the bind error `AddrInUse` on port 3000 means the docker
  backend still owns the port.
