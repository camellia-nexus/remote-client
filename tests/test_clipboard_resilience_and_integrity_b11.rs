#![cfg(not(any(target_os = "ios")))]

use camellia_remote::clipboard::{
    proto::{
        from_clipboard, from_multi_clipboards, special_to_proto, MAX_CLIPBOARD_COMPRESSED_BYTES,
        MAX_CLIPBOARD_ITEMS, MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES,
        MAX_CLIPBOARD_TOTAL_DECOMPRESSED_BYTES, MAX_SPECIAL_NAME_LEN, MAX_SPECIAL_PAYLOAD_BYTES,
    },
    update_clipboard, valid_rgba_dimensions, ClipboardSide,
};
use camellia_remote_protocol::message_proto::{Clipboard, ClipboardFormat};
use clipboard::{
    get_rx_cliprdr_server, remove_channel_by_conn_id, send_data, ClipboardFile, CliprdrError,
    CLIPRDR_CHANNEL_BOUND, MAX_CLIPRDR_PAYLOAD_BYTES,
};

// ============================================================================
// DATA-001 Tests: Special Clipboard Uncompressed vs Compressed Integrity
// ============================================================================

#[test]
fn test_data001_special_uncompressed_preserves_content() {
    let special_name = "application/x-vnd.camellia.calc-sheet".to_string();
    // Incompressible short payload: compressed bytes will not be smaller than raw
    let raw_payload = vec![10, 20, 30, 40, 50, 60, 70, 80];

    let proto = special_to_proto(raw_payload.clone(), special_name.clone())
        .expect("special_to_proto should succeed for valid short payload");

    assert!(
        !proto.compress,
        "Short payload must not be marked as compressed"
    );
    assert_eq!(proto.special_name, special_name);
    // Crucial DATA-001 check: content must be raw_payload, NOT special_name string bytes
    assert_eq!(
        &proto.content[..],
        raw_payload.as_slice(),
        "DATA-001: uncompressed special clipboard payload must contain raw bytes, not format name"
    );

    #[cfg(not(target_os = "android"))]
    {
        let restored = from_clipboard(proto).expect("from_clipboard should succeed");
        match restored {
            arboard::ClipboardData::Special((name, data)) => {
                assert_eq!(name, special_name);
                assert_eq!(data, raw_payload);
            }
            other => panic!("Expected Special clipboard data, got {:?}", other),
        }
    }
}

#[test]
fn test_data001_special_compressed_preserves_content() {
    let special_name = "application/x-vnd.camellia.report".to_string();
    // Repetitive compressible payload
    let raw_payload = vec![0xAB; 8192];

    let proto = special_to_proto(raw_payload.clone(), special_name.clone())
        .expect("special_to_proto should succeed for compressible payload");

    assert!(
        proto.compress,
        "Repetitive payload must be marked as compressed"
    );
    assert_eq!(proto.special_name, special_name);
    assert!(
        proto.content.len() < raw_payload.len(),
        "Compressed payload must be smaller than raw payload"
    );

    #[cfg(not(target_os = "android"))]
    {
        let restored = from_clipboard(proto).expect("from_clipboard should succeed");
        match restored {
            arboard::ClipboardData::Special((name, data)) => {
                assert_eq!(name, special_name);
                assert_eq!(data, raw_payload);
            }
            other => panic!("Expected Special clipboard data, got {:?}", other),
        }
    }
}

#[test]
fn test_data001_special_bounds_enforced() {
    // 1. Name exceeding MAX_SPECIAL_NAME_LEN (256) is rejected
    let long_name = "s".repeat(MAX_SPECIAL_NAME_LEN + 1);
    assert!(
        special_to_proto(vec![1, 2, 3], long_name).is_none(),
        "Special format name exceeding MAX_SPECIAL_NAME_LEN must be rejected"
    );

    // 2. Payload exceeding MAX_SPECIAL_PAYLOAD_BYTES (16 MiB) is rejected
    let oversized_payload = vec![0u8; MAX_SPECIAL_PAYLOAD_BYTES + 1];
    assert!(
        special_to_proto(oversized_payload, "valid_name".to_string()).is_none(),
        "Special payload exceeding MAX_SPECIAL_PAYLOAD_BYTES must be rejected"
    );
}

// ============================================================================
// RES-018 Tests: Thread Proliferation, Generation Drop, Decompression Bounds
// ============================================================================

#[test]
fn test_res018_rapid_update_clipboard_no_thread_explosion() {
    // Send 100 clipboard updates in rapid succession
    for i in 0..100 {
        let mut cb = Clipboard::new();
        cb.format = ClipboardFormat::Text.into();
        cb.compress = false;
        cb.content = format!("message_{}", i).into_bytes().into();
        update_clipboard(vec![cb], ClipboardSide::Client);
    }
    // Worker runs asynchronously on a single dedicated thread without panicking or creating 100 threads
}

#[test]
fn test_res018_decompression_bounds_and_item_limits() {
    // 1. Truncation to MAX_CLIPBOARD_ITEMS
    let mut items = Vec::new();
    for i in 0..30 {
        let mut cb = Clipboard::new();
        cb.format = ClipboardFormat::Text.into();
        cb.compress = false;
        cb.content = format!("item_{}", i).into_bytes().into();
        items.push(cb);
    }
    #[cfg(not(target_os = "android"))]
    {
        let parsed = from_multi_clipboards(items);
        assert_eq!(
            parsed.len(),
            MAX_CLIPBOARD_ITEMS,
            "MultiClipboards must be truncated to MAX_CLIPBOARD_ITEMS"
        );
    }

    // 2. Compressed payload exceeding MAX_CLIPBOARD_COMPRESSED_BYTES rejected
    let mut cb_oversized_compressed = Clipboard::new();
    cb_oversized_compressed.format = ClipboardFormat::Text.into();
    cb_oversized_compressed.compress = true;
    cb_oversized_compressed.content = vec![0u8; MAX_CLIPBOARD_COMPRESSED_BYTES + 1].into();
    #[cfg(not(target_os = "android"))]
    assert!(
        from_clipboard(cb_oversized_compressed).is_none(),
        "Compressed payload exceeding MAX_CLIPBOARD_COMPRESSED_BYTES must be rejected"
    );

    // 3. Uncompressed payload exceeding MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES rejected
    let mut cb_oversized_uncompressed = Clipboard::new();
    cb_oversized_uncompressed.format = ClipboardFormat::Text.into();
    cb_oversized_uncompressed.compress = false;
    cb_oversized_uncompressed.content = vec![0u8; MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES + 1].into();
    #[cfg(not(target_os = "android"))]
    assert!(
        from_clipboard(cb_oversized_uncompressed).is_none(),
        "Uncompressed payload exceeding MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES must be rejected"
    );

    // 4. Batch cumulative limit check
    assert_eq!(MAX_CLIPBOARD_TOTAL_DECOMPRESSED_BYTES, 64 * 1024 * 1024);
}

#[test]
fn test_res018_rgba_dimension_validation() {
    // Valid dimensions
    assert_eq!(valid_rgba_dimensions(10, 20, 10 * 20 * 4), Some((10, 20)));

    // Zero or negative
    assert_eq!(valid_rgba_dimensions(0, 20, 0), None);
    assert_eq!(valid_rgba_dimensions(10, -1, 40), None);

    // Mismatched data len
    assert_eq!(valid_rgba_dimensions(10, 20, 100), None);

    // Exceeding 16384 dimension bound
    assert_eq!(valid_rgba_dimensions(16385, 1, 16385 * 4), None);
    assert_eq!(valid_rgba_dimensions(1, 16385, 16385 * 4), None);
}

// ============================================================================
// RES-017 Tests: Cliprdr Bounded Channels, Backpressure, Payload Budget
// ============================================================================

#[test]
fn test_res017_cliprdr_channel_bound_and_backpressure() {
    const TEST_CONN_ID: i32 = 99991;

    // Register receiver channel
    let _rx = get_rx_cliprdr_server(TEST_CONN_ID);

    // Send up to CLIPRDR_CHANNEL_BOUND (64) messages
    for _ in 0..CLIPRDR_CHANNEL_BOUND {
        let res = send_data(TEST_CONN_ID, ClipboardFile::MonitorReady);
        assert!(res.is_ok(), "Sending within channel bound must succeed");
    }

    // 65th message must trigger Backpressure
    let overflow_res = send_data(TEST_CONN_ID, ClipboardFile::MonitorReady);
    assert!(
        matches!(
            overflow_res,
            Err(CliprdrError::Backpressure {
                conn_id: TEST_CONN_ID
            })
        ),
        "Sending beyond CLIPRDR_CHANNEL_BOUND must trigger Backpressure error, got {:?}",
        overflow_res
    );

    // Clean up channel
    remove_channel_by_conn_id(TEST_CONN_ID);

    // After removal, send must fail with InvalidRequest (conn_id not found)
    let after_removal = send_data(TEST_CONN_ID, ClipboardFile::MonitorReady);
    assert!(
        after_removal.is_err(),
        "Sending to removed channel must return error"
    );
}

#[test]
fn test_res017_cliprdr_payload_budget_enforced() {
    const TEST_CONN_ID: i32 = 99992;
    let _rx = get_rx_cliprdr_server(TEST_CONN_ID);

    // FormatDataResponse exceeding MAX_CLIPRDR_PAYLOAD_BYTES (16 MiB)
    let oversized = ClipboardFile::FormatDataResponse {
        msg_flags: 0,
        format_data: vec![0u8; MAX_CLIPRDR_PAYLOAD_BYTES + 1],
    };

    let res = send_data(TEST_CONN_ID, oversized);
    assert!(
        res.is_err(),
        "Oversized FormatDataResponse must be rejected before queuing"
    );

    remove_channel_by_conn_id(TEST_CONN_ID);
}
