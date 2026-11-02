#![cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    feature = "flutter"
))]

use camellia_remote::flutter::FlutterHandler;
use camellia_remote::ui_session_interface::InvokeUiSession;
use camellia_remote_protocol::compress::{compress, MAX_TERMINAL_DECOMPRESSED_SIZE};
use camellia_remote_protocol::message_proto::{
    TerminalClosed, TerminalData, TerminalError, TerminalOpened, TerminalResponse,
};

#[test]
fn test_res026_terminal_decompressed_size_constant_is_bounded() {
    assert_eq!(MAX_TERMINAL_DECOMPRESSED_SIZE, 128 * 1024);
}

#[test]
fn test_res026_handler_tracks_active_terminals_lifecycle() {
    let handler = FlutterHandler::default();
    assert!(!handler.is_terminal_active(1));

    // Opened with success = false must not mark terminal active
    let mut resp_fail = TerminalResponse::new();
    let mut opened_fail = TerminalOpened::new();
    opened_fail.terminal_id = 1;
    opened_fail.success = false;
    opened_fail.message = "Failed to spawn PTY".into();
    resp_fail.set_opened(opened_fail);

    handler.handle_terminal_response(resp_fail);
    assert!(!handler.is_terminal_active(1));

    // Opened with success = true marks terminal active
    let mut resp_ok = TerminalResponse::new();
    let mut opened_ok = TerminalOpened::new();
    opened_ok.terminal_id = 1;
    opened_ok.success = true;
    resp_ok.set_opened(opened_ok);

    handler.handle_terminal_response(resp_ok);
    assert!(handler.is_terminal_active(1));

    // Closed removes active terminal
    let mut resp_close = TerminalResponse::new();
    let mut closed = TerminalClosed::new();
    closed.terminal_id = 1;
    closed.exit_code = 0;
    resp_close.set_closed(closed);

    handler.handle_terminal_response(resp_close);
    assert!(!handler.is_terminal_active(1));

    // Error response also evicts active terminal
    handler.mark_terminal_active(2);
    assert!(handler.is_terminal_active(2));

    let mut resp_err = TerminalResponse::new();
    let mut err = TerminalError::new();
    err.terminal_id = 2;
    err.message = "PTY hangup".into();
    resp_err.set_error(err);

    handler.handle_terminal_response(resp_err);
    assert!(!handler.is_terminal_active(2));
}

#[test]
fn test_res026_data_for_unknown_terminal_id_is_dropped() {
    let handler = FlutterHandler::default();
    assert!(!handler.is_terminal_active(999));

    let valid_data = vec![b'a'; 4096];
    let compressed_data = compress(&valid_data).unwrap();

    let mut resp_data = TerminalResponse::new();
    let mut term_data = TerminalData::new();
    term_data.terminal_id = 999;
    term_data.data = compressed_data.into();
    term_data.compressed = true;
    resp_data.set_data(term_data);

    // Must be dropped safely without crashing or marking active
    handler.handle_terminal_response(resp_data);
    assert!(!handler.is_terminal_active(999));
}

#[test]
fn test_res026_valid_terminal_chunks_and_boundaries() {
    let handler = FlutterHandler::default();
    handler.mark_terminal_active(10);

    // Standard 4 KiB chunk
    let chunk_4k = vec![b'x'; 4 * 1024];
    let compressed_4k = compress(&chunk_4k).unwrap();
    let mut resp = TerminalResponse::new();
    let mut data_4k = TerminalData::new();
    data_4k.terminal_id = 10;
    data_4k.data = compressed_4k.into();
    data_4k.compressed = true;
    resp.set_data(data_4k);

    handler.handle_terminal_response(resp);
    assert!(handler.is_terminal_active(10));

    // Replay 8 KiB chunk
    let chunk_8k = vec![b'y'; 8 * 1024];
    let compressed_8k = compress(&chunk_8k).unwrap();
    let mut resp_8k = TerminalResponse::new();
    let mut data_8k = TerminalData::new();
    data_8k.terminal_id = 10;
    data_8k.data = compressed_8k.into();
    data_8k.compressed = true;
    resp_8k.set_data(data_8k);

    handler.handle_terminal_response(resp_8k);
    assert!(handler.is_terminal_active(10));

    // Maximum allowed 128 KiB boundary
    let chunk_max = vec![b'z'; MAX_TERMINAL_DECOMPRESSED_SIZE];
    let compressed_max = compress(&chunk_max).unwrap();
    let mut resp_max = TerminalResponse::new();
    let mut data_max = TerminalData::new();
    data_max.terminal_id = 10;
    data_max.data = compressed_max.into();
    data_max.compressed = true;
    resp_max.set_data(data_max);

    handler.handle_terminal_response(resp_max);
    assert!(handler.is_terminal_active(10));
}

#[test]
fn test_res026_compression_bomb_fails_closed_and_evicts_terminal() {
    let handler = FlutterHandler::default();
    handler.mark_terminal_active(42);
    assert!(handler.is_terminal_active(42));

    // 2 MiB of zeros compressed into a tiny payload (massive compression ratio)
    let bomb_payload = vec![0u8; 2 * 1024 * 1024];
    let compressed_bomb = compress(&bomb_payload).unwrap();
    assert!(
        compressed_bomb.len() < 200,
        "Zstd must compress zeros heavily"
    );

    let mut resp_bomb = TerminalResponse::new();
    let mut data_bomb = TerminalData::new();
    data_bomb.terminal_id = 42;
    data_bomb.data = compressed_bomb.into();
    data_bomb.compressed = true;
    resp_bomb.set_data(data_bomb);

    // Handling the compression bomb must fail closed and evict terminal 42
    handler.handle_terminal_response(resp_bomb);
    assert!(
        !handler.is_terminal_active(42),
        "Terminal must be evicted upon receiving compression bomb exceeding limit"
    );
}

#[test]
fn test_res026_corrupt_compressed_stream_fails_closed_and_evicts_terminal() {
    let handler = FlutterHandler::default();
    handler.mark_terminal_active(77);
    assert!(handler.is_terminal_active(77));

    let corrupt_bytes = vec![0x28, 0xb5, 0x2f, 0xfd, 0xff, 0xff, 0xff, 0xff];
    let mut resp_corrupt = TerminalResponse::new();
    let mut data_corrupt = TerminalData::new();
    data_corrupt.terminal_id = 77;
    data_corrupt.data = corrupt_bytes.into();
    data_corrupt.compressed = true;
    resp_corrupt.set_data(data_corrupt);

    handler.handle_terminal_response(resp_corrupt);
    assert!(
        !handler.is_terminal_active(77),
        "Terminal must be evicted upon corrupt zstd stream"
    );
}

#[test]
fn test_res026_oversized_uncompressed_data_fails_closed() {
    let handler = FlutterHandler::default();
    handler.mark_terminal_active(88);
    assert!(handler.is_terminal_active(88));

    // 130 KiB uncompressed data (exceeds 128 KiB limit)
    let oversized_uncompressed = vec![b'u'; MAX_TERMINAL_DECOMPRESSED_SIZE + 2048];
    let mut resp = TerminalResponse::new();
    let mut data_oversized = TerminalData::new();
    data_oversized.terminal_id = 88;
    data_oversized.data = oversized_uncompressed.into();
    data_oversized.compressed = false;
    resp.set_data(data_oversized);

    handler.handle_terminal_response(resp);
    assert!(
        !handler.is_terminal_active(88),
        "Terminal must be evicted when uncompressed data exceeds limit"
    );
}
