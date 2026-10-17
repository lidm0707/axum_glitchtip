use std::net::{IpAddr, Ipv4Addr, SocketAddr};

pub const HOST_IP: [u8; 4] = [0, 0, 0, 0];
pub const PORT: u16 = 3000;
pub const TEST_USER_ID: u64 = 42;
pub const SENTRY_DSN_ENV: &str = "SENTRY_DSN";
pub const DB_LATENCY_MS: u64 = 20;
pub fn sentry_dsn() -> String {
    std::env::var(SENTRY_DSN_ENV).expect("not found sentry dsn")
}

pub const fn socket_addr() -> SocketAddr {
    SocketAddr::new(
        IpAddr::V4(Ipv4Addr::new(
            HOST_IP[0], HOST_IP[1], HOST_IP[2], HOST_IP[3],
        )),
        PORT,
    )
}
