// Client Batch 18 Hardening Tests (CRED-002, UNSAFE-001, UNSAFE-002)

use std::sync::Arc;

#[test]
fn test_secret_peer_option_denylist() {
    use camellia_remote::ui_interface::{is_secret_peer_option, SECRET_PEER_OPTIONS};

    assert!(SECRET_PEER_OPTIONS.contains(&"rdp_password"));
    assert!(SECRET_PEER_OPTIONS.contains(&"os-password"));

    assert!(is_secret_peer_option("rdp_password"));
    assert!(is_secret_peer_option("os-password"));
    assert!(!is_secret_peer_option("rdp_port"));
    assert!(!is_secret_peer_option("rdp_username"));
    assert!(!is_secret_peer_option("alias"));
    assert!(!is_secret_peer_option("has_rdp_password"));
}

#[test]
fn test_get_peer_option_denies_secrets() {
    use camellia_remote::ui_interface::{get_peer_option, set_peer_option};

    let test_peer = "test_denylist_peer_999999";
    // Set secret option
    set_peer_option(
        test_peer.to_string(),
        "rdp_password".to_string(),
        "super_secret_123".to_string(),
    );
    set_peer_option(
        test_peer.to_string(),
        "rdp_username".to_string(),
        "admin_user".to_string(),
    );

    // Generic getter MUST deny secret options
    let leaked_pass = get_peer_option(test_peer.to_string(), "rdp_password".to_string());
    assert_eq!(
        leaked_pass, "",
        "rdp_password must be blocked by secret denylist"
    );

    // Non-secret options must still be retrievable
    let user = get_peer_option(test_peer.to_string(), "rdp_username".to_string());
    assert_eq!(user, "admin_user");

    // has_rdp_password query returns "true"
    let has_pwd = get_peer_option(test_peer.to_string(), "has_rdp_password".to_string());
    assert_eq!(has_pwd, "true");

    // Cleanup
    set_peer_option(
        test_peer.to_string(),
        "rdp_password".to_string(),
        "".to_string(),
    );
    set_peer_option(
        test_peer.to_string(),
        "rdp_username".to_string(),
        "".to_string(),
    );
}

#[test]
fn test_rdp_credential_actions_keep_replace_clear() {
    use camellia_remote::ui_interface::{peer_has_rdp_password, set_peer_rdp_options};
    use camellia_remote_protocol::config::PeerConfig;

    let peer_id = "test_rdp_actions_peer_888888";

    // 1. Initial set with new password ("replace")
    set_peer_rdp_options(
        peer_id.to_string(),
        "3389".to_string(),
        "alice".to_string(),
        "replace".to_string(),
        Some("first_pass_456".to_string()),
    );

    assert!(peer_has_rdp_password(peer_id));
    let cfg = PeerConfig::load(peer_id);
    assert_eq!(
        cfg.options.get("rdp_port").map(|s| s.as_str()),
        Some("3389")
    );
    assert_eq!(
        cfg.options.get("rdp_username").map(|s| s.as_str()),
        Some("alice")
    );
    assert_eq!(
        cfg.options.get("rdp_password").map(|s| s.as_str()),
        Some("first_pass_456")
    );

    // 2. Update username and port while preserving password ("keep")
    set_peer_rdp_options(
        peer_id.to_string(),
        "3390".to_string(),
        "bob".to_string(),
        "keep".to_string(),
        None,
    );

    assert!(peer_has_rdp_password(peer_id));
    let cfg2 = PeerConfig::load(peer_id);
    assert_eq!(
        cfg2.options.get("rdp_port").map(|s| s.as_str()),
        Some("3390")
    );
    assert_eq!(
        cfg2.options.get("rdp_username").map(|s| s.as_str()),
        Some("bob")
    );
    assert_eq!(
        cfg2.options.get("rdp_password").map(|s| s.as_str()),
        Some("first_pass_456")
    );

    // 3. Clear password explicitly ("clear")
    set_peer_rdp_options(
        peer_id.to_string(),
        "3390".to_string(),
        "bob".to_string(),
        "clear".to_string(),
        None,
    );

    assert!(!peer_has_rdp_password(peer_id));
    let cfg3 = PeerConfig::load(peer_id);
    assert!(!cfg3.options.contains_key("rdp_password"));

    // Final cleanup
    PeerConfig::remove(peer_id);
}

#[test]
fn test_no_environment_variable_leakage() {
    assert!(
        std::env::var("rdp_password").is_err(),
        "rdp_password must never be stored in process env"
    );
    assert!(
        std::env::var("rdp_username").is_err(),
        "rdp_username must never be stored in process env"
    );
}

#[test]
fn test_mock_credential_store_raii_lifecycle() {
    use camellia_remote::port_forward::{MockCredStore, RdpCredentialGuard, RdpCredentialStore};

    let store = Arc::new(MockCredStore::new());
    let target1 = "TERMSRV/127.0.0.5".to_string();
    let target2 = "TERMSRV/127.0.0.5:3389".to_string();

    store
        .write_credential(&target1, "admin", "secret123")
        .unwrap();
    store
        .write_credential(&target2, "admin", "secret123")
        .unwrap();

    {
        let map = store.credentials.read().unwrap();
        assert_eq!(map.len(), 2);
        assert_eq!(
            map.get(&target1).unwrap(),
            &("admin".to_string(), "secret123".to_string())
        );
    }

    // Wrap in RAII guard and drop
    {
        let _guard = RdpCredentialGuard::new(store.clone(), vec![target1.clone(), target2.clone()]);
        let map = store.credentials.read().unwrap();
        assert_eq!(map.len(), 2);
    } // guard drops here

    // Target credentials must be deleted on drop
    {
        let map = store.credentials.read().unwrap();
        assert_eq!(map.len(), 0);
    }
}

#[test]
fn test_rdp_slot_guard_allocation_and_reclamation() {
    use camellia_remote::port_forward::RdpSlotGuard;

    let slot1 = RdpSlotGuard::allocate();
    let slot2 = RdpSlotGuard::allocate();
    let slot3 = RdpSlotGuard::allocate();

    assert_ne!(slot1.slot(), slot2.slot());
    assert_ne!(slot2.slot(), slot3.slot());
    assert_ne!(slot1.slot(), slot3.slot());

    assert_eq!(slot1.ip(), format!("127.0.0.{}", slot1.slot()));
    assert_eq!(slot2.ip(), format!("127.0.0.{}", slot2.slot()));
    assert_eq!(slot3.ip(), format!("127.0.0.{}", slot3.slot()));

    let released_slot = slot2.slot();
    drop(slot2);

    // After dropping slot2, a new allocation can reclaim that slot
    let slot4 = RdpSlotGuard::allocate();
    assert_eq!(slot4.slot(), released_slot);
}

#[test]
fn test_zero_invalid_value_annotations_in_client() {
    // Structural regression test: assert that #[allow(invalid_value)] is completely absent
    let client_src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let libs_scrap = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src");

    fn check_dir(dir: &std::path::Path) {
        if !dir.exists() {
            return;
        }
        for entry in std::fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            if path.is_dir() {
                check_dir(&path);
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                let content = std::fs::read_to_string(&path).unwrap();
                assert!(
                    !content.contains("invalid_value"),
                    "File {:?} still contains #[allow(invalid_value)]!",
                    path
                );
            }
        }
    }

    check_dir(&client_src);
    check_dir(&libs_scrap);
}

#[test]
fn test_soft_render_safe_frame_copy_and_null_tolerance() {
    #[cfg(feature = "flutter")]
    {
        use camellia_remote::flutter::{session_copy_rgba, session_get_rgba_frame};
        use camellia_remote_protocol::uuid::Uuid;

        // 1. Calling session_get_rgba_frame on non-existent session returns None safely
        let frame = session_get_rgba_frame(Uuid::new_v4(), 0);
        assert!(frame.is_none());

        // 2. Calling session_copy_rgba with null pointer or invalid session returns 0
        let copied = unsafe { session_copy_rgba(std::ptr::null(), 0, std::ptr::null_mut(), 0) };
        assert_eq!(copied, 0);

        let mut buf = [0u8; 128];
        let c_str = std::ffi::CString::new("invalid_uuid").unwrap();
        let copied2 = unsafe { session_copy_rgba(c_str.as_ptr(), 0, buf.as_mut_ptr(), buf.len()) };
        assert_eq!(copied2, 0);
    }
}
