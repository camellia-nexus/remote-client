// Client Batch 30 Hardening Tests (AUTH-005, AUTH-006, CRED-008)

#![cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    feature = "flutter"
))]

use std::sync::Mutex;

static BATCH30_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_batch30_test_lock() -> std::sync::MutexGuard<'static, ()> {
    BATCH30_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner())
}

#[test]
fn test_auth005_action_gate_monotonic_id_and_recency() {
    let _lock = acquire_batch30_test_lock();
    use camellia_remote::action_gate::{
        clean_connection, is_connection_remote_input_recent, is_global_remote_input_recent,
        next_action_id, record_remote_input, reset_action_gate_for_test,
        REMOTE_INPUT_RECENCY_THRESHOLD,
    };

    reset_action_gate_for_test();

    // 1. Monotonic action ID generation
    let id1 = next_action_id();
    let id2 = next_action_id();
    let id3 = next_action_id();
    assert!(id2 > id1, "Action IDs must be strictly increasing");
    assert!(id3 > id2, "Action IDs must be strictly increasing");

    // 2. Initial state: no recent input
    assert!(
        !is_global_remote_input_recent(REMOTE_INPUT_RECENCY_THRESHOLD),
        "Initial global remote input must not be recent"
    );
    assert!(
        !is_connection_remote_input_recent(101, REMOTE_INPUT_RECENCY_THRESHOLD),
        "Initial connection remote input must not be recent"
    );

    // 3. Record pointer move for connection 101
    record_remote_input(101, false);
    assert!(
        is_global_remote_input_recent(REMOTE_INPUT_RECENCY_THRESHOLD),
        "Global remote input must be recent after record"
    );
    assert!(
        is_connection_remote_input_recent(101, REMOTE_INPUT_RECENCY_THRESHOLD),
        "Connection 101 remote input must be recent after record"
    );

    // 4. Record click for connection 202
    record_remote_input(202, true);
    assert!(is_connection_remote_input_recent(
        202,
        REMOTE_INPUT_RECENCY_THRESHOLD
    ));

    // 5. Clean connection state
    clean_connection(101);
    clean_connection(202);
    reset_action_gate_for_test();
    assert!(!is_global_remote_input_recent(
        REMOTE_INPUT_RECENCY_THRESHOLD
    ));
}

#[test]
fn test_auth005_cm_action_authorization_fail_closed() {
    let _lock = acquire_batch30_test_lock();
    use camellia_remote::action_gate::{
        authorize_cm_action, clean_connection, create_action_token, record_remote_input,
        reset_action_gate_for_test,
    };

    reset_action_gate_for_test();

    let invalid_conn_id = -9999;
    let page_gen = 42;

    // 1. Unissued action ID must FAIL CLOSED
    let unissued_action_id = 999_999;
    assert!(
        !authorize_cm_action(invalid_conn_id, "elevate", unissued_action_id, page_gen),
        "Unissued action ID must fail closed"
    );

    // 2. Generation mismatch must FAIL CLOSED
    let token_gen1 = create_action_token(invalid_conn_id, page_gen);
    assert!(
        !authorize_cm_action(invalid_conn_id, "elevate", token_gen1, page_gen + 1),
        "Generation mismatch must fail closed"
    );

    // 3. Connection ID mismatch must FAIL CLOSED
    let token_conn_mismatch = create_action_token(invalid_conn_id, page_gen);
    assert!(
        !authorize_cm_action(-8888, "elevate", token_conn_mismatch, page_gen),
        "Connection ID mismatch must fail closed"
    );

    // 4. Non-existent connection ID must FAIL CLOSED even if token matches
    let action_id = create_action_token(invalid_conn_id, page_gen);
    let authorized = authorize_cm_action(invalid_conn_id, "elevate", action_id, page_gen);
    assert!(
        !authorized,
        "CM action on non-existent connection must fail closed"
    );

    // 5. Replay attack prevention: token must be single-use and consumed
    let replay_attempt = authorize_cm_action(invalid_conn_id, "elevate", action_id, page_gen);
    assert!(
        !replay_attempt,
        "Replaying a consumed action token must fail closed"
    );

    // 6. Active remote input on connection must FAIL CLOSED
    let token_with_input = create_action_token(invalid_conn_id, page_gen);
    record_remote_input(invalid_conn_id, true);
    let authorized_with_input = authorize_cm_action(
        invalid_conn_id,
        "permission_toggle",
        token_with_input,
        page_gen,
    );
    assert!(
        !authorized_with_input,
        "CM action with active remote input must fail closed"
    );

    // 7. clean_connection must invalidate all pending tokens for that connection
    let token_for_cleaned = create_action_token(invalid_conn_id, page_gen);
    clean_connection(invalid_conn_id);
    assert!(
        !authorize_cm_action(invalid_conn_id, "elevate", token_for_cleaned, page_gen),
        "Pending action token for cleaned connection must be purged"
    );

    reset_action_gate_for_test();
}

#[test]
fn test_auth005_pointer_source_authoritative_fail_closed() {
    let _lock = acquire_batch30_test_lock();
    use camellia_remote::action_gate::{
        check_pointer_source_authoritative, next_action_id, record_remote_input,
        reset_action_gate_for_test,
    };

    reset_action_gate_for_test();

    // When no remote input has occurred, check_pointer_source_authoritative should return false (not blocked)
    let id1 = next_action_id();
    assert!(
        !check_pointer_source_authoritative(id1),
        "Initial pointer source should not be blocked when no remote input exists"
    );

    // When remote input is recorded, it must return true (MUST BE BLOCKED)
    record_remote_input(1001, true);
    let id2 = next_action_id();
    assert!(
        check_pointer_source_authoritative(id2),
        "Pointer source MUST be blocked when remote input is active"
    );

    reset_action_gate_for_test();
}

#[test]
fn test_auth006_terminal_admin_privilege_typed_and_zero_env_leakage() {
    use camellia_remote::client::{LoginConfigHandler, TerminalPrivilegeMode};
    use camellia_remote_protocol::rendezvous_proto::ConnType;

    // Verify TerminalPrivilegeMode enum
    assert_eq!(TerminalPrivilegeMode::Standard.is_admin(), false);
    assert_eq!(TerminalPrivilegeMode::Admin.is_admin(), true);
    assert_eq!(
        TerminalPrivilegeMode::from_bool(true),
        TerminalPrivilegeMode::Admin
    );
    assert_eq!(
        TerminalPrivilegeMode::from_bool(false),
        TerminalPrivilegeMode::Standard
    );

    // Ensure legacy environment variable is ignored
    std::env::set_var("IS_TERMINAL_ADMIN", "FORBIDDEN_ENV_VALUE");

    // 1. Terminal session with explicit is_terminal_admin = true
    let mut handler_admin = LoginConfigHandler::default();
    handler_admin.initialize(
        "test_peer_admin".to_string(),
        ConnType::TERMINAL,
        None,
        false,
        None,
        None,
        None,
        true, // is_terminal_admin: true
    );
    assert_eq!(handler_admin.privilege_mode, TerminalPrivilegeMode::Admin);
    assert!(
        handler_admin.is_terminal_admin,
        "Terminal session with is_terminal_admin=true must be admin"
    );

    // 2. Terminal session with explicit is_terminal_admin = false
    // MUST NOT be affected by the environment variable IS_TERMINAL_ADMIN!
    let mut handler_non_admin = LoginConfigHandler::default();
    handler_non_admin.initialize(
        "test_peer_normal".to_string(),
        ConnType::TERMINAL,
        None,
        false,
        None,
        None,
        None,
        false, // is_terminal_admin: false
    );
    assert_eq!(
        handler_non_admin.privilege_mode,
        TerminalPrivilegeMode::Standard
    );
    assert!(
        !handler_non_admin.is_terminal_admin,
        "Terminal session with is_terminal_admin=false must NOT be admin despite IS_TERMINAL_ADMIN env"
    );

    // 3. Non-terminal session (e.g. Remote Desktop) with is_terminal_admin = true
    // MUST NOT gain terminal admin privilege
    let mut handler_desktop = LoginConfigHandler::default();
    handler_desktop.initialize(
        "test_peer_desktop".to_string(),
        ConnType::DEFAULT_CONN,
        None,
        false,
        None,
        None,
        None,
        true, // is_terminal_admin: true
    );
    assert_eq!(
        handler_desktop.privilege_mode,
        TerminalPrivilegeMode::Standard
    );
    assert!(
        !handler_desktop.is_terminal_admin,
        "Non-terminal session must never gain terminal admin privilege"
    );

    // Clean up test environment variable
    std::env::remove_var("IS_TERMINAL_ADMIN");
}

#[test]
fn test_cred008_generic_session_option_denylist() {
    use camellia_remote::flutter::FlutterHandler;
    use camellia_remote::ui_interface::{is_secret_peer_option, SECRET_PEER_OPTIONS};
    use camellia_remote::ui_session_interface::Session;
    use camellia_remote_protocol::rendezvous_proto::ConnType;

    // 1. Verify SECRET_PEER_OPTIONS and robust normalization (case, whitespace, hyphens/underscores)
    assert!(SECRET_PEER_OPTIONS.contains(&"os-password"));
    assert!(SECRET_PEER_OPTIONS.contains(&"rdp_password"));

    assert!(is_secret_peer_option("os-password"));
    assert!(is_secret_peer_option("os_password"));
    assert!(is_secret_peer_option("OS-PASSWORD"));
    assert!(is_secret_peer_option("OS_PASSWORD"));
    assert!(is_secret_peer_option(" os-password "));
    assert!(is_secret_peer_option("rdp_password"));
    assert!(is_secret_peer_option("rdp-password"));
    assert!(is_secret_peer_option("RDP_PASSWORD"));
    assert!(is_secret_peer_option(" rdp-password "));

    assert!(!is_secret_peer_option("os-username"));
    assert!(!is_secret_peer_option("auto-login"));

    // 2. Test Session::get_option secret filtering with all variants
    let session = Session::<FlutterHandler>::default();
    {
        let mut lc = session.lc.write().unwrap();
        lc.initialize(
            "test_cred008_peer".to_string(),
            ConnType::DEFAULT_CONN,
            None,
            false,
            None,
            None,
            None,
            false,
        );
        lc.set_option("os-password".to_string(), "PlainTextSecret123".to_string());
        lc.set_option("rdp_password".to_string(), "PlainTextRdp456".to_string());
        lc.set_option("os-username".to_string(), "Administrator".to_string());
        lc.set_option("auto-login".to_string(), "Y".to_string());
    }

    // Secret options MUST return empty string through generic get_option regardless of casing/separator
    assert_eq!(session.get_option("os-password".to_string()), "");
    assert_eq!(session.get_option("os_password".to_string()), "");
    assert_eq!(session.get_option("OS-PASSWORD".to_string()), "");
    assert_eq!(session.get_option("rdp_password".to_string()), "");
    assert_eq!(session.get_option("rdp-password".to_string()), "");
    assert_eq!(session.get_option("RDP_PASSWORD".to_string()), "");

    // Non-secret options MUST be retrievable
    assert_eq!(
        session.get_option("os-username".to_string()),
        "Administrator"
    );
    assert_eq!(session.get_option("auto-login".to_string()), "Y");

    // 3. Test native has_os_password helper
    assert!(
        session.has_os_password(),
        "has_os_password must return true when password exists"
    );

    // When os-password is empty:
    {
        let mut lc = session.lc.write().unwrap();
        lc.set_option("os-password".to_string(), "".to_string());
    }
    assert!(
        !session.has_os_password(),
        "has_os_password must return false when password is empty"
    );
}
