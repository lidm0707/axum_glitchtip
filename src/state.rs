use std::sync::atomic::AtomicU64;

#[derive(Default)]
pub struct AppState {
    pub hit_count: AtomicU64,
}
