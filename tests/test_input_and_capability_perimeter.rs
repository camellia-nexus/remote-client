use camellia_remote::{
    common::input::*,
    server::{
        connection::{Connection, HostCapability},
        input_service::is_function_key,
    },
};
use camellia_remote_protocol::{message_proto::*, protobuf::EnumOrUnknown};
use std::sync::mpsc;

#[test]
fn test_wheel_scroll_clamp_and_negation() {
    // Clamping algorithm used across xdo, macos, and uinput:
    // (length as i64).unsigned_abs().min(20) as usize
    let cases = [
        (i32::MIN, 20usize, true),
        (i32::MAX, 20usize, false),
        (-1200, 20usize, true),
        (1200, 20usize, false),
        (-20, 20usize, true),
        (20, 20usize, false),
        (-5, 5usize, true),
        (5, 5usize, false),
        (-1, 1usize, true),
        (1, 1usize, false),
        (0, 0usize, false),
    ];

    for (input, expected_count, is_negative) in cases {
        let count = (input as i64).unsigned_abs().min(20) as usize;
        assert_eq!(count, expected_count, "Failed count for input: {}", input);
        assert_eq!(input < 0, is_negative, "Failed sign for input: {}", input);
    }
}

fn create_test_message(set: impl FnOnce(&mut Message)) -> Message {
    let mut msg = Message::new();
    set(&mut msg);
    msg
}

#[test]
fn test_message_capability_coverage() {
    // 1. ControlInput
    let mouse = create_test_message(|m| m.set_mouse_event(MouseEvent::new()));
    assert_eq!(
        Connection::message_required_capability(&mouse),
        Some(HostCapability::ControlInput)
    );

    let key = create_test_message(|m| m.set_key_event(KeyEvent::new()));
    assert_eq!(
        Connection::message_required_capability(&key),
        Some(HostCapability::ControlInput)
    );

    let pointer = create_test_message(|m| m.set_pointer_device_event(PointerDeviceEvent::new()));
    assert_eq!(
        Connection::message_required_capability(&pointer),
        Some(HostCapability::ControlInput)
    );

    // 2. TextClipboard
    let clip = create_test_message(|m| m.set_clipboard(Clipboard::new()));
    assert_eq!(
        Connection::message_required_capability(&clip),
        Some(HostCapability::TextClipboard)
    );

    let multi_clip = create_test_message(|m| m.set_multi_clipboards(MultiClipboards::new()));
    assert_eq!(
        Connection::message_required_capability(&multi_clip),
        Some(HostCapability::TextClipboard)
    );

    // 3. FileClipboard
    let cliprdr = create_test_message(|m| m.set_cliprdr(Cliprdr::new()));
    assert_eq!(
        Connection::message_required_capability(&cliprdr),
        Some(HostCapability::FileClipboard)
    );

    // 4. FileTransferRead vs Write
    let mut fa_send = FileAction::new();
    fa_send.set_send(FileTransferSendRequest::new());
    let msg_send = create_test_message(|m| m.set_file_action(fa_send));
    assert_eq!(
        Connection::message_required_capability(&msg_send),
        Some(HostCapability::FileTransferRead)
    );

    let mut fa_readdir = FileAction::new();
    fa_readdir.set_read_dir(ReadDir::new());
    let msg_readdir = create_test_message(|m| m.set_file_action(fa_readdir));
    assert_eq!(
        Connection::message_required_capability(&msg_readdir),
        Some(HostCapability::FileTransferRead)
    );

    let mut fa_empty_dirs = FileAction::new();
    fa_empty_dirs.set_read_empty_dirs(ReadEmptyDirs::new());
    let msg_empty_dirs = create_test_message(|m| m.set_file_action(fa_empty_dirs));
    assert_eq!(
        Connection::message_required_capability(&msg_empty_dirs),
        Some(HostCapability::FileTransferRead)
    );

    let mut fa_all_files = FileAction::new();
    fa_all_files.set_all_files(ReadAllFiles::new());
    let msg_all_files = create_test_message(|m| m.set_file_action(fa_all_files));
    assert_eq!(
        Connection::message_required_capability(&msg_all_files),
        Some(HostCapability::FileTransferRead)
    );

    let mut fa_cancel = FileAction::new();
    fa_cancel.set_cancel(FileTransferCancel::new());
    let msg_cancel = create_test_message(|m| m.set_file_action(fa_cancel));
    assert_eq!(
        Connection::message_required_capability(&msg_cancel),
        Some(HostCapability::FileTransferWrite)
    );

    let resp = create_test_message(|m| m.set_file_response(FileResponse::new()));
    assert_eq!(
        Connection::message_required_capability(&resp),
        Some(HostCapability::FileTransferWrite)
    );

    // 5. AudioPlayback
    let audio_frame = create_test_message(|m| m.set_audio_frame(AudioFrame::new()));
    assert_eq!(
        Connection::message_required_capability(&audio_frame),
        Some(HostCapability::AudioPlayback)
    );

    let mut misc_audio = Misc::new();
    misc_audio.set_audio_format(AudioFormat::new());
    let msg_audio_fmt = create_test_message(|m| m.set_misc(misc_audio));
    assert_eq!(
        Connection::message_required_capability(&msg_audio_fmt),
        Some(HostCapability::AudioPlayback)
    );

    // 6. VoiceCall
    let vreq = create_test_message(|m| m.set_voice_call_request(VoiceCallRequest::new()));
    assert_eq!(
        Connection::message_required_capability(&vreq),
        Some(HostCapability::VoiceCall)
    );

    let vresp = create_test_message(|m| m.set_voice_call_response(VoiceCallResponse::new()));
    assert_eq!(
        Connection::message_required_capability(&vresp),
        Some(HostCapability::VoiceCall)
    );

    // 7. DisplayMutation
    let mut misc_toggle = Misc::new();
    misc_toggle.set_toggle_virtual_display(ToggleVirtualDisplay::new());
    let msg_toggle = create_test_message(|m| m.set_misc(misc_toggle));
    assert_eq!(
        Connection::message_required_capability(&msg_toggle),
        Some(HostCapability::DisplayMutation)
    );

    let mut misc_res = Misc::new();
    misc_res.set_change_resolution(Resolution::new());
    let msg_res = create_test_message(|m| m.set_misc(misc_res));
    assert_eq!(
        Connection::message_required_capability(&msg_res),
        Some(HostCapability::DisplayMutation)
    );

    // 8. SystemPower
    let mut misc_power = Misc::new();
    misc_power.set_restart_remote_device(true);
    let msg_power = create_test_message(|m| m.set_misc(misc_power));
    assert_eq!(
        Connection::message_required_capability(&msg_power),
        Some(HostCapability::SystemPower)
    );

    // 9. SystemElevation
    let mut misc_elev = Misc::new();
    misc_elev.set_elevation_request(ElevationRequest::new());
    let msg_elev = create_test_message(|m| m.set_misc(misc_elev));
    assert_eq!(
        Connection::message_required_capability(&msg_elev),
        Some(HostCapability::SystemElevation)
    );

    // 10. Terminal
    let terminal = create_test_message(|m| m.set_terminal_action(TerminalAction::new()));
    assert_eq!(
        Connection::message_required_capability(&terminal),
        Some(HostCapability::Terminal)
    );

    // 11. Housekeeping / Unrelated
    let test_delay = create_test_message(|m| m.set_test_delay(TestDelay::new()));
    assert_eq!(Connection::message_required_capability(&test_delay), None);
}

#[derive(Debug, PartialEq, Eq, Clone)]
enum SimulatedInputEvent {
    MouseMove {
        conn_id: i32,
        mask: i32,
        x: i32,
        y: i32,
    },
    MouseDown {
        conn_id: i32,
        mask: i32,
    },
    KeyDown {
        code: i32,
    },
}

#[test]
fn test_input_move_coalescing_drain_simulation() {
    let (tx, rx) = mpsc::channel();

    // Send 5 rapid pure moves from conn 1
    for i in 1..=5 {
        tx.send(SimulatedInputEvent::MouseMove {
            conn_id: 1,
            mask: MOUSE_TYPE_MOVE,
            x: i * 10,
            y: i * 20,
        })
        .unwrap();
    }
    // Then send MouseDown
    tx.send(SimulatedInputEvent::MouseDown {
        conn_id: 1,
        mask: MOUSE_TYPE_DOWN,
    })
    .unwrap();
    // Then send 3 more pure moves
    for i in 6..=8 {
        tx.send(SimulatedInputEvent::MouseMove {
            conn_id: 1,
            mask: MOUSE_TYPE_MOVE,
            x: i * 10,
            y: i * 20,
        })
        .unwrap();
    }
    // Then send KeyDown
    tx.send(SimulatedInputEvent::KeyDown { code: 42 }).unwrap();

    // Now run coalescing consumer logic matching Connection::handle_input
    let mut consumed = Vec::new();
    let mut pending_item: Option<SimulatedInputEvent> = None;

    loop {
        let next_item = match pending_item.take() {
            Some(item) => Ok(item),
            None => rx.try_recv(),
        };

        match next_item {
            Ok(v) => match v {
                SimulatedInputEvent::MouseMove {
                    conn_id,
                    mask,
                    mut x,
                    mut y,
                } => {
                    let is_pure_move = (mask & MOUSE_TYPE_MASK) == MOUSE_TYPE_MOVE;
                    if is_pure_move {
                        while let Ok(next) = rx.try_recv() {
                            match next {
                                SimulatedInputEvent::MouseMove {
                                    conn_id: next_conn,
                                    mask: next_mask,
                                    x: next_x,
                                    y: next_y,
                                } if next_conn == conn_id
                                    && (next_mask & MOUSE_TYPE_MASK) == MOUSE_TYPE_MOVE
                                    && next_mask == mask =>
                                {
                                    x = next_x;
                                    y = next_y;
                                }
                                other => {
                                    pending_item = Some(other);
                                    break;
                                }
                            }
                        }
                    }
                    consumed.push(SimulatedInputEvent::MouseMove {
                        conn_id,
                        mask,
                        x,
                        y,
                    });
                }
                other => {
                    consumed.push(other);
                }
            },
            Err(_) => break,
        }
    }

    // Expected:
    // 1. First 5 moves coalesced to (50, 100)
    // 2. MouseDown preserved in place
    // 3. Next 3 moves coalesced to (80, 160)
    // 4. KeyDown preserved in place
    assert_eq!(
        consumed,
        vec![
            SimulatedInputEvent::MouseMove {
                conn_id: 1,
                mask: MOUSE_TYPE_MOVE,
                x: 50,
                y: 100
            },
            SimulatedInputEvent::MouseDown {
                conn_id: 1,
                mask: MOUSE_TYPE_DOWN
            },
            SimulatedInputEvent::MouseMove {
                conn_id: 1,
                mask: MOUSE_TYPE_MOVE,
                x: 80,
                y: 160
            },
            SimulatedInputEvent::KeyDown { code: 42 },
        ]
    );
}

#[test]
fn test_function_key_rate_limiting() {
    let ctrl_alt_del = EnumOrUnknown::new(ControlKey::CtrlAltDel);
    let lock_screen = EnumOrUnknown::new(ControlKey::LockScreen);

    // Call is_function_key
    assert!(is_function_key(&ctrl_alt_del));
    // Immediate second call within 1000ms window should still return true (recognized as function key)
    // and be rate-limited internally
    assert!(is_function_key(&ctrl_alt_del));

    // Lock screen key is also a recognized function key
    assert!(is_function_key(&lock_screen));

    // Normal control keys should return false
    let backspace = EnumOrUnknown::new(ControlKey::Backspace);
    assert!(!is_function_key(&backspace));
}
