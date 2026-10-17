use crate::config;

#[tracing::instrument]
pub async fn find_user(id: u64) -> String {
    tokio::time::sleep(std::time::Duration::from_millis(config::DB_LATENCY_MS)).await;
    format!("user-{id}")
}
