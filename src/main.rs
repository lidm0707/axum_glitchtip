pub mod config;
pub mod db;
pub mod routes;
pub mod service;
pub mod state;
use crate::state::AppState;
use axum::routing::get;
use sentry::integrations::tower::{NewSentryLayer, SentryHttpLayer};
use std::sync::Arc;
use tower::ServiceBuilder;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

// TEMP-TEST: minimal layer that logs every span/event hook it receives
struct SpyLayer;
fn spy_layer() -> SpyLayer {
    SpyLayer
}
impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for SpyLayer {
    fn on_new_span(
        &self,
        attrs: &tracing::span::Attributes<'_>,
        id: &tracing::span::Id,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        eprintln!(
            "SPY new_span {:?} {} @{}",
            id,
            attrs.metadata().name(),
            attrs.metadata().level()
        );
    }
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        eprintln!(
            "SPY event {} @{}",
            event.metadata().level(),
            event.metadata().target()
        );
    }
}

fn main() {
    dotenvy::dotenv().ok();

    let options = sentry::ClientOptions::new()
        .dsn(&config::sentry_dsn())
        .traces_sample_rate(1.0)
        .debug(true) // TEMP-TEST: print envelopes to stderr
        .send_default_pii(false)
        .attach_stacktrace(true)
        .auto_session_tracking(true)
        .session_mode(sentry::SessionMode::Request)
        .send_default_pii(true);

    let _guard = sentry::init(options.maybe_release(sentry::release_name!()));
    async fn failing() -> () {
        panic!("Everything is on fire!")
    }
    tracing_subscriber::registry()
        .with(spy_layer()) // TEMP-TEST
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .with(tracing_subscriber::fmt::layer())
        .with(
            sentry::integrations::tracing::layer()
                .event_filter(|md| match *md.level() {
                    tracing::Level::ERROR => sentry::integrations::tracing::EventFilter::Event,
                    tracing::Level::WARN => sentry::integrations::tracing::EventFilter::Log,
                    _ => sentry::integrations::tracing::EventFilter::Ignore,
                })
                .span_filter(|md| matches!(*md.level(), tracing::Level::INFO)),
        )
        .init();
    let sentry_layers = ServiceBuilder::new()
        .layer(NewSentryLayer::new_from_top())
        .layer(SentryHttpLayer::new().enable_transaction());
    let app = routes::router(Arc::new(AppState::default()))
        .route("/", get(failing))
        .layer(sentry_layers);

    tracing::info!("listening on {}", config::socket_addr());
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("build broken")
        .block_on(async {
            let listener = tokio::net::TcpListener::bind(config::socket_addr())
                .await
                .expect("bind failed");
            axum::serve(listener, app.into_make_service())
                .await
                .expect("serve fail when starting");
        });
}
