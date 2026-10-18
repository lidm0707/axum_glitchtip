---
name: glitchtip-axum-setup
description: Set up GlitchTip error reporting in an axum Rust app using the sentry crate (tracing layer, tower layers, DSN from env), and use it to send error events. Use when adding, configuring, or debugging GlitchTip/sentry integration in axum.
---

# GlitchTip in axum

How this repo wires GlitchTip error reporting into an axum server via the `sentry` crate (v0.49.x). Follow these steps in order when adding or fixing the integration.

## 1. Dependencies (Cargo.toml)

```toml
sentry = { version = "0.49.3", features = ["tracing", "tower-axum-matched-path", "logs"] }
sentry-tracing = "0.49.3"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tower = "0.5"
```

- `tracing` feature: bridges `tracing` events/spans into sentry.
- `tower-axum-matched-path`: HTTP transaction names use axum route patterns.
- `logs` feature: sentry structured log support.

## 2. DSN from env (never hardcode)

GlitchTip is Sentry-protocol compatible, so the `sentry` crate talks to it directly.

- Read the DSN from an env var with a named `const` (see `src/config.rs`): `pub const SENTRY_DSN_ENV: &str = "SENTRY_DSN";`
- Self-hosted GlitchTip DSN format: `http://<key>@localhost:9000/<project_id>`
- Load `.env` with `dotenvy::dotenv().ok()` before reading it. Never read or commit `.env`.

## 3. Init sentry before the subscriber (src/main.rs)

```rust
let options = sentry::ClientOptions::new()
    .dsn(&config::sentry_dsn())
    .traces_sample_rate(1.0)
    .send_default_pii(false)
    .attach_stacktrace(true)
    .auto_session_tracking(true)
    .session_mode(sentry::SessionMode::Request);
let _guard = sentry::init(options.maybe_release(sentry::release_name!()));
```

The `_guard` must stay alive for the whole program — dropping it flushes/discards events. Bind it in `main`, not inside a block.

## 4. Tracing layer — only send ERROR as events

```rust
tracing_subscriber::registry()
    .with(tracing_subscriber::EnvFilter::from_default_env())
    .with(tracing_subscriber::fmt::layer())
    .with(
        sentry::integrations::tracing::layer()
            .event_filter(|md| match *md.level() {
                tracing::Level::ERROR => EventFilter::Event,
                tracing::Level::WARN => EventFilter::Log,
                _ => EventFilter::Ignore,
            })
            .span_filter(|md| matches!(*md.level(), tracing::Level::INFO)),
    )
    .init();
```

This is the key filter choice: `ERROR` becomes a GlitchTip issue, `WARN` becomes a breadcrumb/log, everything else is ignored. Adjust deliberately, not by accident.

## 5. Tower layers on the router — panic capture + HTTP transactions

```rust
let sentry_layers = ServiceBuilder::new()
    .layer(NewSentryLayer::new_from_top())
    .layer(SentryHttpLayer::new().enable_transaction());

let app = routes::router(state).layer(sentry_layers);
```

- `NewSentryLayer::new_from_top()` picks up the hub from `sentry::init`'s guard → panics in handlers are captured.
- `SentryHttpLayer::new().enable_transaction()` creates a performance transaction per request.

## 6. Using it

- Any `tracing::error!` in handlers becomes a GlitchTip event.
- `sentry::capture_message(...)`, `sentry::capture_error(&err)` for explicit reporting.
- `.expect()`/`panic!` in a handler is auto-captured by the tower layer.
- Verify with `make compose-up` + the GlitchTip UI at http://localhost:9000, or load test with `make k6` (every 10th iteration hits `/api/error`).

## Debugging checklist

If events don't appear in GlitchTip:

1. `.debug(true)` on `ClientOptions` prints envelopes to stderr — confirm transport is sending.
2. Check DSN host/port matches the compose stack (localhost:9000).
3. Confirm `_guard` is held in `main` and `sentry::init` runs before the tracing registry is built.
4. Confirm the tracing `event_filter` isn't ignoring the level you emit.
5. Duplicate/odd layer behavior: don't add `sentry` layers twice; `new_from_top` requires the guard to be the outermost init.
