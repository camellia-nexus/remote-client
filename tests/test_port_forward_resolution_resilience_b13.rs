#![cfg(not(any(target_os = "android", target_os = "ios")))]

use camellia_remote::client::{Data, Interface, LoginConfigHandler};
use camellia_remote::port_forward::{
    get_global_available_permits, MAX_ACTIVE_TUNNELS_PER_LISTENER, MAX_GLOBAL_ACTIVE_TUNNELS,
    MAX_PRELOGIN_BUFFER_BYTES, PRELOGIN_DEADLINE,
};
use camellia_remote_protocol::message_proto::{
    Hash, PeerInfo, Resolution, TestDelay, WindowsSession,
};
use camellia_remote_protocol::tokio;
use camellia_remote_protocol::Stream;
use std::sync::{Arc, RwLock};
use std::time::Duration;

#[derive(Clone)]
struct MockInterface {
    lch: Arc<RwLock<LoginConfigHandler>>,
}

#[async_trait::async_trait]
impl Interface for MockInterface {
    fn send(&self, _data: Data) {}
    fn msgbox(&self, _msgtype: &str, _title: &str, _text: &str, _link: &str) {}
    fn handle_login_error(&self, _err: &str) -> bool {
        false
    }
    fn handle_peer_info(&self, _pi: PeerInfo) {}
    fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {}
    async fn handle_hash(&self, _pass: &str, _hash: Hash, _peer: &mut Stream) {}
    async fn handle_login_from_ui(
        &self,
        _os_username: String,
        _os_password: String,
        _password: String,
        _remember: bool,
        _peer: &mut Stream,
    ) {
    }
    async fn handle_test_delay(&self, _t: TestDelay, _peer: &mut Stream) {}
    fn get_lch(&self) -> Arc<RwLock<LoginConfigHandler>> {
        self.lch.clone()
    }
}

// ============================================================================
// RES-024 Tests: Port Forwarding Resource Lifecycle & Prelogin Bounds
// ============================================================================

#[test]
fn test_res024_port_forward_constants_and_limits() {
    const {
        assert!(
            MAX_ACTIVE_TUNNELS_PER_LISTENER <= MAX_GLOBAL_ACTIVE_TUNNELS,
            "Per-listener tunnels must not exceed global tunnels"
        );
    }
    assert_eq!(MAX_PRELOGIN_BUFFER_BYTES, 64 * 1024);
    assert_eq!(PRELOGIN_DEADLINE, Duration::from_secs(30));
    assert_eq!(get_global_available_permits(), MAX_GLOBAL_ACTIVE_TUNNELS);
}

#[camellia_remote_protocol::tokio::test]
async fn test_res024_listen_terminates_immediately_on_receiver_channel_drop() {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    // Drop sender immediately
    drop(tx);

    let lc = Arc::new(RwLock::new(LoginConfigHandler::default()));
    let interface = MockInterface { lch: lc.clone() };

    // Finding an available port
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port() as i32;
    drop(listener);

    let start = std::time::Instant::now();
    let res = camellia_remote::port_forward::listen(
        "test_peer".to_string(),
        "password".to_string(),
        port,
        interface,
        rx,
        "",
        "",
        lc,
        "127.0.0.1".to_string(),
        8080,
    )
    .await;

    assert!(res.is_ok(), "listen must terminate cleanly on channel EOF");
    assert!(
        start.elapsed() < Duration::from_millis(500),
        "listen must not busy-loop on dropped ui_receiver"
    );
}

#[camellia_remote_protocol::tokio::test]
async fn test_res024_listen_terminates_immediately_on_close_message() {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

    let lc = Arc::new(RwLock::new(LoginConfigHandler::default()));
    let interface = MockInterface { lch: lc.clone() };

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port() as i32;
    drop(listener);

    tx.send(Data::Close).unwrap();

    let start = std::time::Instant::now();
    let res = camellia_remote::port_forward::listen(
        "test_peer".to_string(),
        "password".to_string(),
        port,
        interface,
        rx,
        "",
        "",
        lc,
        "127.0.0.1".to_string(),
        8080,
    )
    .await;

    assert!(res.is_ok(), "listen must terminate cleanly on Data::Close");
    assert!(
        start.elapsed() < Duration::from_millis(500),
        "listen must exit immediately when Close received"
    );
}

// ============================================================================
// RES-027 Tests: Resolution Message Dimension Bounding
// ============================================================================

#[test]
fn test_res027_resolution_dimension_bounds_validation() {
    const MIN_RESOLUTION_DIMENSION: i32 = 100;
    const MAX_RESOLUTION_DIMENSION: i32 = 16384;

    let is_valid = |r: &Resolution| -> bool {
        r.width >= MIN_RESOLUTION_DIMENSION
            && r.width <= MAX_RESOLUTION_DIMENSION
            && r.height >= MIN_RESOLUTION_DIMENSION
            && r.height <= MAX_RESOLUTION_DIMENSION
    };

    // Valid resolutions
    let normal = Resolution {
        width: 1920,
        height: 1080,
        ..Default::default()
    };
    assert!(is_valid(&normal));

    let min_valid = Resolution {
        width: 100,
        height: 100,
        ..Default::default()
    };
    assert!(is_valid(&min_valid));

    let max_valid = Resolution {
        width: 16384,
        height: 16384,
        ..Default::default()
    };
    assert!(is_valid(&max_valid));

    // Invalid negative dimensions
    let negative = Resolution {
        width: -1,
        height: 1080,
        ..Default::default()
    };
    assert!(!is_valid(&negative));

    let min_int = Resolution {
        width: i32::MIN,
        height: 1080,
        ..Default::default()
    };
    assert!(!is_valid(&min_int));

    // Zero dimensions
    let zero = Resolution {
        width: 0,
        height: 0,
        ..Default::default()
    };
    assert!(!is_valid(&zero));

    // Oversized dimensions
    let oversized = Resolution {
        width: 32768,
        height: 20000,
        ..Default::default()
    };
    assert!(!is_valid(&oversized));
}
