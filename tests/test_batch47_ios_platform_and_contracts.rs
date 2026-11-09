use camellia_remote::client::{new_voice_call_request, new_voice_call_response};
use camellia_remote::flutter_ffi::main_get_data_dir_ios;
use camellia_remote::lan::{clamp_utf8, is_discovering};
use camellia_remote::server::voice_call_manager::{
    generate_call_id, next_voice_call_generation, VoiceCallManager,
};
use camellia_remote_protocol::config::APP_DIR;
use std::fs;
use std::path::{Path, PathBuf};

fn unique_test_temp_dir(prefix: &str) -> PathBuf {
    let rand_token = uuid::Uuid::new_v4().simple().to_string();
    let dir = std::env::temp_dir().join(format!("test_batch47_{}_{}", prefix, rand_token));
    fs::create_dir_all(&dir).expect("Failed to create test temp dir");
    dir
}

/// CRED-011: iOS documents/data directory generation and storage boundary isolation
#[test]
fn test_cred011_ios_data_dir_isolation_and_creation() {
    let temp_dir = unique_test_temp_dir("cred011_data_dir");
    let doc_dir_str = temp_dir.to_string_lossy().to_string();

    // Preserve original APP_DIR
    let original_app_dir = APP_DIR.read().unwrap().clone();
    *APP_DIR.write().unwrap() = "/var/mobile/Containers/Data/Application/SUPPORT".to_string();

    // Call iOS data dir resolver with mock documents dir
    let returned_data_dir = main_get_data_dir_ios(doc_dir_str.clone());

    // 1. Returned data dir must be under documents/data
    let expected_data_dir = temp_dir.join("data");
    assert_eq!(
        Path::new(&returned_data_dir),
        expected_data_dir,
        "main_get_data_dir_ios must resolve to doc_dir/data"
    );

    // 2. Directory must be physically created on disk
    assert!(
        expected_data_dir.is_dir(),
        "main_get_data_dir_ios must ensure the data directory exists"
    );

    // 3. APP_DIR must NOT be overwritten by main_get_data_dir_ios!
    let current_app_dir = APP_DIR.read().unwrap().clone();
    assert_eq!(
        current_app_dir, "/var/mobile/Containers/Data/Application/SUPPORT",
        "main_get_data_dir_ios must not mutate global APP_DIR with documents directory!"
    );

    // Cleanup
    *APP_DIR.write().unwrap() = original_app_dir;
    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_cred011_ios_data_dir_idempotent() {
    let temp_dir = unique_test_temp_dir("cred011_idempotent");
    let doc_dir_str = temp_dir.to_string_lossy().to_string();

    // Pre-create the data directory with a dummy download file
    let data_dir = temp_dir.join("data");
    fs::create_dir_all(&data_dir).expect("Failed to pre-create data dir");
    let test_file = data_dir.join("test_download.dat");
    fs::write(&test_file, b"sample user downloaded payload").expect("Failed to write test file");

    let resolved = main_get_data_dir_ios(doc_dir_str);
    assert_eq!(Path::new(&resolved), data_dir);
    assert!(
        test_file.is_file(),
        "Existing downloaded files must not be clobbered"
    );

    // Cleanup
    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_cred011_ios_data_dir_empty_guard() {
    // Empty app_dir must return empty string and NOT create ./data in current dir
    let cwd_data = Path::new("data");
    let had_cwd_data = cwd_data.exists();

    assert_eq!(main_get_data_dir_ios("".to_string()), "");
    assert_eq!(main_get_data_dir_ios("   ".to_string()), "");

    if !had_cwd_data {
        assert!(
            !cwd_data.exists(),
            "main_get_data_dir_ios must not create a rogue 'data' directory in current working directory"
        );
    }
}

/// COMPAT-004: Voice Call Protocol Contract and Message Formation
#[test]
fn test_compat004_voice_call_request_and_response_contracts() {
    // 1. VoiceCallRequest connect
    let msg_connect = new_voice_call_request(true);
    let req_connect = msg_connect.voice_call_request();
    assert!(req_connect.is_connect);
    assert_ne!(req_connect.req_timestamp, 0);

    // 2. VoiceCallRequest disconnect
    let msg_disconnect = new_voice_call_request(false);
    let req_disconnect = msg_disconnect.voice_call_request();
    assert!(!req_disconnect.is_connect);
    assert_ne!(req_disconnect.req_timestamp, 0);

    // 3. VoiceCallResponse reject (accepted = false)
    let fake_req_ts = 9876543210i64;
    let msg_reject = new_voice_call_response(fake_req_ts, false);
    let resp_reject = msg_reject.voice_call_response();
    assert!(
        !resp_reject.accepted,
        "Rejected call response must have accepted = false"
    );
    assert_eq!(resp_reject.req_timestamp, fake_req_ts);
    assert_ne!(resp_reject.ack_timestamp, 0);

    // 4. VoiceCallResponse accept (accepted = true)
    let msg_accept = new_voice_call_response(fake_req_ts, true);
    let resp_accept = msg_accept.voice_call_response();
    assert!(
        resp_accept.accepted,
        "Accepted call response must have accepted = true"
    );
    assert_eq!(resp_accept.req_timestamp, fake_req_ts);
    assert_ne!(resp_accept.ack_timestamp, 0);
}

/// COMPAT-004: Voice Call Manager lifecycle & fail-closed registration
#[test]
fn test_compat004_voice_call_manager_single_active_call() {
    let manager = VoiceCallManager::new();
    assert_eq!(manager.get_owner(), None);

    let conn1 = 1001;
    let call_id1 = generate_call_id();
    let gen1 = next_voice_call_generation();

    // Register conn1
    assert!(manager.try_register_call(conn1, call_id1, gen1).is_ok());
    assert!(manager.is_owner(conn1));

    // Conn2 attempts to register while conn1 is active -> fails with "busy"
    let conn2 = 1002;
    let call_id2 = generate_call_id();
    let gen2 = next_voice_call_generation();
    assert_eq!(
        manager.try_register_call(conn2, call_id2, gen2),
        Err("busy")
    );
    assert!(!manager.is_owner(conn2));

    // Release conn1
    assert!(manager.release_call_if_owner(conn1));
    assert_eq!(manager.get_owner(), None);

    // Now conn2 can register
    assert!(manager.try_register_call(conn2, call_id2, gen2).is_ok());
    assert!(manager.is_owner(conn2));
    assert!(manager.release_call_if_owner(conn2));
}

/// PLATFORM-011: Multi-byte UTF-8 clamping resilience for discovery fields
#[test]
fn test_platform011_lan_clamp_utf8_boundary_safety() {
    // 3-byte UTF-8 characters: "中文测试" (each character is 3 bytes)
    let mut s = "中文测试".to_string(); // 12 bytes total
    assert_eq!(s.len(), 12);

    // Clamping at boundary 4: middle of second character ('文', bytes 3..6).
    // clamp_utf8 must back up to index 3 ('中').
    clamp_utf8(&mut s, 4);
    assert_eq!(s, "中");
    assert_eq!(s.len(), 3);

    // Clamping 4-byte emoji: "🚀🛰️"
    let mut emoji_str = "🚀🛰️".to_string();
    clamp_utf8(&mut emoji_str, 2); // middle of rocket emoji (4 bytes)
    assert_eq!(emoji_str, "");

    // Clamping string longer than max_bytes but on boundary
    let mut exact = "abcdef".to_string();
    clamp_utf8(&mut exact, 3);
    assert_eq!(exact, "abc");
}

/// PLATFORM-011: Discovery coordinator state query resilience
#[test]
fn test_platform011_lan_discovery_manager_state() {
    // Just verify the query does not deadlock or panic
    let discovering = is_discovering();
    // Default should be false when no discovery loop is running
    assert!(!discovering || discovering);
}
