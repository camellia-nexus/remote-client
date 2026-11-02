use clipboard::{
    next_connection_generation, ClipboardFileOpId, ClipboardOpGuard, GLOBAL_CLIPBOARD_OP_MGR,
};
use std::collections::HashSet;
use std::time::{Duration, Instant};

#[test]
fn test_clipboard_file_op_id_uniqueness() {
    let mut ids = HashSet::new();
    for _ in 0..1000 {
        let op_id = ClipboardFileOpId::new_random();
        assert_ne!(op_id.0, 0, "Op ID must never be zero");
        assert!(ids.insert(op_id), "Duplicate op_id detected: {:?}", op_id);
    }
}

#[test]
fn test_clipboard_generational_binding_and_validation() {
    GLOBAL_CLIPBOARD_OP_MGR.write().take();

    let conn_id = 42;
    let conn_gen_active = next_connection_generation();
    let fd_id = 1;

    // Initiate operation
    let op_id = ClipboardOpGuard::initiate_operation(conn_id, conn_gen_active, false, fd_id);
    assert_ne!(op_id.0, 0);

    // Validate with correct conn_id and conn_generation -> Ok
    let val_ok = ClipboardOpGuard::validate_format_data_response(conn_id, conn_gen_active);
    assert!(val_ok.is_ok());
    let (validated_op_id, _, cancel_token) = val_ok.unwrap();
    assert_eq!(validated_op_id, op_id);
    assert!(!cancel_token.is_cancelled());

    // FileContentsResponse with mismatched conn_id -> Rejected
    let val_mismatch_conn =
        ClipboardOpGuard::validate_file_contents_response(conn_id + 1, conn_gen_active);
    assert!(val_mismatch_conn.is_err());

    // FileContentsResponse with stale generation -> Rejected
    let stale_gen = conn_gen_active - 1;
    let val_stale_gen = ClipboardOpGuard::validate_file_contents_response(conn_id, stale_gen);
    assert!(val_stale_gen.is_err());

    // FileContentsResponse with correct conn_id and generation -> Ok
    let val_contents_ok =
        ClipboardOpGuard::validate_file_contents_response(conn_id, conn_gen_active);
    assert!(val_contents_ok.is_ok());
    assert_eq!(val_contents_ok.unwrap(), op_id);

    // Abort connection (simulating disconnect or permission revocation)
    ClipboardOpGuard::abort_for_connection(conn_id, conn_gen_active);

    // Cancel token is now triggered
    assert!(cancel_token.is_cancelled());

    // Subsequent validation fails immediately
    let val_after_abort =
        ClipboardOpGuard::validate_file_contents_response(conn_id, conn_gen_active);
    assert!(val_after_abort.is_err());
}

#[test]
fn test_clipboard_operation_ttl_expiration() {
    GLOBAL_CLIPBOARD_OP_MGR.write().take();

    let conn_id = 99;
    let conn_gen = next_connection_generation();
    let _op_id = ClipboardOpGuard::initiate_operation(conn_id, conn_gen, true, 2);

    // Manually artificially age the operation beyond TTL
    {
        let mut guard = GLOBAL_CLIPBOARD_OP_MGR.write();
        if let Some(op) = guard.as_mut() {
            op.deadline = Instant::now() - Duration::from_secs(5);
        }
    }

    // Validation must fail due to TTL expiration
    let val_expired = ClipboardOpGuard::validate_file_contents_response(conn_id, conn_gen);
    assert!(val_expired.is_err());

    // And operation is aborted or expired
    assert!(
        GLOBAL_CLIPBOARD_OP_MGR.read().is_none()
            || GLOBAL_CLIPBOARD_OP_MGR
                .read()
                .as_ref()
                .unwrap()
                .is_expired()
    );
}
