use crate::config;
use crate::db;

#[tracing::instrument]
pub async fn get_user(id: u64) -> String {
    tracing::warn!("get_user");
    tokio::time::sleep(std::time::Duration::from_millis(config::DB_LATENCY_MS)).await;
    db::find_user(id).await
}
