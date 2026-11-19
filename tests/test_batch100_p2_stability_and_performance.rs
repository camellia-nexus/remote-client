//! Contract and Regression Test Suite for Batch 100:
//! - Phase 2 (P2 Brand Compliance & Cross-Platform Stability Governance):
//!   - CLIP-001 (BUG-04): Windows clipboard owner marker normalization and brand fix.
//!   - PLATFORM-019 (BUG-05): Android clipboard 1MB Binder transaction limit protection.
//!   - PLATFORM-020 (BUG-06): Linux Wayland uinput relative mouse move symmetric rounding.
//!   - BUILD-023 (BUG-07): macOS Plist brand residue removal and launchd direct binary execution.
//! - Phase 3 (P2 Performance & Quality Optimization):
//!   - VIDEO-001 (BUG-08): Windows DXGI temporary Access Lost auto-recovery retry state machine.
//!   - VIDEO-002 (FEAT-01): Post-scroll stillness detection and high-quality re-encoded frame dispatch.

#![deny(warnings)]

use arboard::ClipboardData;
use camellia_remote::clipboard::{
    append_owner_marker, ClipboardSide, CAMELLIA_CLIPBOARD_OWNER_FORMAT,
    RUSTDESK_CLIPBOARD_OWNER_FORMAT,
};
use camellia_remote::server::uinput::symmetric_round_half;
use camellia_remote::server::video_service::{
    is_dxgi_access_lost, millis_since_last_scroll, notify_scrolled, DxgiRecoveryStateMachine,
    MAX_DXGI_RETRY_COUNT, SCROLL_STILL_SETTLE_MS,
};
use std::fs;
use std::io::{Error, ErrorKind};
use std::thread;
use std::time::Duration;

// =========================================================================
// CLIP-001: Windows Clipboard Owner Marker Normalization & Brand Fix
// =========================================================================

#[test]
fn test_clip001_owner_format_and_head_insertion() {
    // 1. Verify format identifier matches the brand specification
    assert_eq!(
        CAMELLIA_CLIPBOARD_OWNER_FORMAT,
        "dyn.com.camellia.remote.owner"
    );
    assert_eq!(
        RUSTDESK_CLIPBOARD_OWNER_FORMAT,
        "dyn.com.camellia.remote.owner"
    );

    // 2. Verify append_owner_marker inserts the marker at index 0 (first element)
    let payload = vec![
        ClipboardData::Text("Hello world".to_string()),
        ClipboardData::Html("<b>Hello</b>".to_string()),
    ];
    let marked = append_owner_marker(payload, ClipboardSide::Host);

    assert_eq!(marked.len(), 3);
    match &marked[0] {
        ClipboardData::Special((format, data)) => {
            assert_eq!(format, CAMELLIA_CLIPBOARD_OWNER_FORMAT);
            assert_eq!(data, &ClipboardSide::Host.get_owner_data());
        }
        _ => panic!(
            "Expected ClipboardData::Special at index 0, found {:?}",
            marked[0]
        ),
    }

    // Existing payload items follow the owner marker
    match &marked[1] {
        ClipboardData::Text(t) => assert_eq!(t, "Hello world"),
        _ => panic!("Expected text at index 1"),
    }
    match &marked[2] {
        ClipboardData::Html(h) => assert_eq!(h, "<b>Hello</b>"),
        _ => panic!("Expected html at index 2"),
    }
}

// =========================================================================
// PLATFORM-019: Android Clipboard 1MB Binder Transaction Limit Protection
// =========================================================================

#[test]
fn test_platform019_android_clipboard_1mb_limit_and_utf8_truncation() {
    const MAX_BINDER_BYTES: usize = 1024 * 1024;

    // Helper mirroring RdClipboardManager.kt's truncateUtf8 implementation
    fn truncate_utf8(text: &str, max_bytes: usize) -> String {
        let bytes = text.as_bytes();
        if bytes.len() <= max_bytes {
            return text.to_string();
        }
        let mut end = max_bytes;
        while end > 0 && (bytes[end] & 0xC0) == 0x80 {
            end -= 1;
        }
        if end > 0 && (bytes[end - 1] & 0x80) != 0 {
            let lead = bytes[end - 1];
            let seq_len = if (lead & 0xE0) == 0xC0 {
                2
            } else if (lead & 0xF0) == 0xE0 {
                3
            } else if (lead & 0xF8) == 0xF0 {
                4
            } else {
                1
            };
            if (end - 1) + seq_len > max_bytes {
                end -= 1;
            }
        }
        String::from_utf8(bytes[..end].to_vec()).expect("Valid UTF-8 after safe truncation")
    }

    // 1. Payloads under 1MB remain untouched
    let small_text = "Standard clipboard text";
    assert_eq!(truncate_utf8(small_text, MAX_BINDER_BYTES), small_text);

    // 2. Multi-byte UTF-8 boundary safety (Chinese characters: 3 bytes each)
    let chinese_sample = "山茶远程控制系统".repeat(100);
    let cut_at = 20; // 20 is not a multiple of 3
    let truncated = truncate_utf8(&chinese_sample, cut_at);
    assert!(truncated.as_bytes().len() <= cut_at);
    assert_eq!(truncated.as_bytes().len(), 18); // 6 characters * 3 bytes = 18 bytes
    assert!(std::str::from_utf8(truncated.as_bytes()).is_ok());

    // 3. 4-byte UTF-8 emoji boundary safety
    let emoji_sample = "🚀🎯🔥🎉".repeat(50);
    let cut_emoji = 15; // 4-byte emojis, cut at 15
    let truncated_emoji = truncate_utf8(&emoji_sample, cut_emoji);
    assert!(truncated_emoji.as_bytes().len() <= cut_emoji);
    assert_eq!(truncated_emoji.as_bytes().len(), 12); // 3 emojis * 4 bytes = 12 bytes

    // 4. Massive 2MB payload is safely clamped to <= 1MB
    let huge_text = "A".repeat(2 * 1024 * 1024);
    let clamped = truncate_utf8(&huge_text, MAX_BINDER_BYTES);
    assert_eq!(clamped.as_bytes().len(), MAX_BINDER_BYTES);

    // 5. Verify RdClipboardManager.kt file contains MAX_BINDER_CLIPBOARD_BYTES
    let kt_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/flutter/android/app/src/main/kotlin/com/camellia/remote/RdClipboardManager.kt"
    );
    let kt_content = fs::read_to_string(kt_path).expect("Read RdClipboardManager.kt");
    assert!(
        kt_content.contains("MAX_BINDER_CLIPBOARD_BYTES: Int = 1024 * 1024"),
        "RdClipboardManager.kt must define MAX_BINDER_CLIPBOARD_BYTES"
    );
    assert!(
        kt_content.contains("TransactionTooLargeException"),
        "RdClipboardManager.kt must reference protection against TransactionTooLargeException"
    );
}

// =========================================================================
// PLATFORM-020: Linux Wayland uinput Relative Mouse Move Symmetric Rounding
// =========================================================================

#[test]
fn test_platform020_uinput_symmetric_rounding_and_drift_elimination() {
    // 1. Verify exact values
    assert_eq!(symmetric_round_half(0), 0);
    assert_eq!(symmetric_round_half(1), 1);
    assert_eq!(symmetric_round_half(-1), -1);
    assert_eq!(symmetric_round_half(2), 1);
    assert_eq!(symmetric_round_half(-2), -1);
    assert_eq!(symmetric_round_half(3), 2);
    assert_eq!(symmetric_round_half(-3), -2);
    assert_eq!(symmetric_round_half(4), 2);
    assert_eq!(symmetric_round_half(-4), -2);

    // Extreme integer boundaries
    assert!(symmetric_round_half(i32::MAX) > 0);
    assert!(symmetric_round_half(i32::MIN) < 0);

    // 2. Strict symmetry across a range of displacements
    for x in 1..=100 {
        let pos = symmetric_round_half(x);
        let neg = symmetric_round_half(-x);
        assert_eq!(
            pos, -neg,
            "Symmetric rounding failed for displacement {}: pos={}, neg={}",
            x, pos, neg
        );
    }

    // 3. Contrast with flawed (x as f32 / 2.).ceil() algorithm:
    // With ceil(), +1 => 1, but -1 => 0 (swallowed!).
    // Over 100 jitter oscillations (+1, -1), ceil() produces +100 drift to the bottom-right.
    // Symmetric rounding produces exactly 0 drift.
    let mut drift_sym = 0;
    let mut drift_ceil = 0;
    for _ in 0..100 {
        drift_sym += symmetric_round_half(1);
        drift_sym += symmetric_round_half(-1);

        drift_ceil += (1.0f32 / 2.0).ceil() as i32;
        drift_ceil += (-1.0f32 / 2.0).ceil() as i32;
    }
    assert_eq!(
        drift_sym, 0,
        "Symmetric rounding must have zero drift on balanced input"
    );
    assert_eq!(
        drift_ceil, 100,
        "Old ceil algorithm has demonstrable 100-pixel drift bug"
    );
}

// =========================================================================
// BUILD-023: macOS Plist Brand Residue Removal & launchd Direct Execution
// =========================================================================

#[test]
fn test_build023_macos_plists_and_windows_icon_branding() {
    let daemon_plist_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/src/platform/privileges_scripts/daemon.plist"
    );
    let agent_plist_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/src/platform/privileges_scripts/agent.plist"
    );
    let icon_rc_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/flutter/plugins/desktop_multi_window/windows/icon.rc"
    );

    // 1. Verify daemon.plist
    let daemon_content = fs::read_to_string(daemon_plist_path).expect("Read daemon.plist");
    assert!(
        !daemon_content.contains("com.carriez.rustdesk"),
        "daemon.plist must not contain com.carriez.rustdesk"
    );
    assert!(
        daemon_content.contains("<string>com.camellia.remote</string>"),
        "daemon.plist must contain com.camellia.remote"
    );
    assert!(
        !daemon_content.contains("/bin/sh"),
        "daemon.plist ProgramArguments must not use /bin/sh -c wrapper"
    );
    assert!(
        daemon_content
            .contains("<string>/Applications/Camellia.app/Contents/MacOS/service</string>"),
        "daemon.plist must directly execute service binary"
    );
    assert!(
        daemon_content.contains("/var/log/camellia_remote_service.err"),
        "daemon.plist standard error log path must be camellia_remote_service.err"
    );
    assert!(
        daemon_content.contains("/var/log/camellia_remote_service.out"),
        "daemon.plist standard out log path must be camellia_remote_service.out"
    );

    // 2. Verify agent.plist
    let agent_content = fs::read_to_string(agent_plist_path).expect("Read agent.plist");
    assert!(
        !agent_content.contains("com.carriez.rustdesk"),
        "agent.plist must not contain com.carriez.rustdesk"
    );
    assert!(
        agent_content.contains("<string>com.camellia.remote</string>"),
        "agent.plist must contain com.camellia.remote"
    );

    // 3. Verify icon.rc
    let rc_content = fs::read_to_string(icon_rc_path).expect("Read icon.rc");
    assert!(
        !rc_content.contains("com.carriez"),
        "icon.rc must not contain com.carriez"
    );
    assert!(
        rc_content.contains(r#"VALUE "CompanyName", "Camellia Computing""#),
        "icon.rc must declare CompanyName as Camellia Computing"
    );
    assert!(
        rc_content.contains(r#"VALUE "LegalCopyright", "Copyright (C) 2026 Camellia Computing. All rights reserved.""#),
        "icon.rc must declare LegalCopyright for Camellia Computing"
    );

    // 4. Verify macos.rs write_plists does not contain com.carriez brand residue
    let macos_rs_path = concat!(env!("CARGO_MANIFEST_DIR"), "/src/platform/macos.rs");
    let macos_content = fs::read_to_string(macos_rs_path).expect("Read macos.rs");
    assert!(
        !macos_content.contains("com.carriez.{}_service.plist"),
        "macos.rs write_plists must not contain com.carriez.{{}}_service.plist"
    );
    assert!(
        !macos_content.contains("com.carriez.{}_server.plist"),
        "macos.rs write_plists must not contain com.carriez.{{}}_server.plist"
    );
    assert!(
        macos_content
            .contains(r#""/Library/LaunchDaemons/{}_service.plist", crate::get_full_name()"#)
            || macos_content.contains(r#""/Library/LaunchDaemons/{}_service.plist","#),
        "macos.rs write_plists must use crate::get_full_name() for daemon plist path"
    );
}

// =========================================================================
// VIDEO-001: Windows DXGI Temporary Access Lost Recovery State Machine
// =========================================================================

#[test]
fn test_video001_dxgi_access_lost_recovery_state_machine() {
    // 1. Error classifier
    let reset_err = Error::new(ErrorKind::ConnectionReset, "DXGI Access Lost");
    assert!(is_dxgi_access_lost(&reset_err));

    let aborted_err = Error::new(ErrorKind::ConnectionAborted, "Session disconnected");
    assert!(is_dxgi_access_lost(&aborted_err));

    let interrupted_err = Error::new(ErrorKind::Interrupted, "Not currently available");
    assert!(is_dxgi_access_lost(&interrupted_err));

    let perm_err = Error::new(ErrorKind::PermissionDenied, "UAC secure desktop");
    assert!(is_dxgi_access_lost(&perm_err));

    let code_err = Error::new(ErrorKind::Other, "Error code: 0x887A0026");
    assert!(is_dxgi_access_lost(&code_err));

    let code_err_lower = Error::new(ErrorKind::Other, "Error code: 0x887a0026");
    assert!(is_dxgi_access_lost(&code_err_lower));

    let text_err_lower = Error::new(ErrorKind::Other, "access lost during capture");
    assert!(is_dxgi_access_lost(&text_err_lower));

    let unrelated_err = Error::new(ErrorKind::InvalidInput, "Bad argument");
    assert!(!is_dxgi_access_lost(&unrelated_err));

    // 2. State machine lifecycle
    let max_retries = MAX_DXGI_RETRY_COUNT;
    let mut sm = DxgiRecoveryStateMachine::new(max_retries);
    assert_eq!(sm.retry_count, 0);

    // Simulate transient failure during UAC desktop switch (e.g. 5 failed frames)
    for i in 1..=5 {
        assert!(sm.should_retry(), "Must permit retry {i}");
        assert_eq!(sm.retry_count, i);
    }

    // Capture recovers on the 6th frame
    sm.on_success();
    assert_eq!(
        sm.retry_count, 0,
        "Retry counter must reset to 0 upon successful frame capture"
    );

    // Exhaustive failure exceeding max_retries
    for _ in 0..max_retries {
        assert!(sm.should_retry());
    }
    assert_eq!(sm.retry_count, max_retries);
    assert!(
        !sm.should_retry(),
        "State machine must refuse further retries when max_retries reached, triggering GDI fallback"
    );
}

// =========================================================================
// VIDEO-002: Post-Scroll Stillness Detection & High-Quality Re-encoding
// =========================================================================

#[test]
fn test_video002_post_scroll_stillness_detection() {
    assert_eq!(SCROLL_STILL_SETTLE_MS, 150);

    // 1. Notify scroll event
    notify_scrolled();

    // 2. Millis since scroll should be Some and very small immediately after
    let elapsed = millis_since_last_scroll();
    assert!(elapsed.is_some());
    assert!(elapsed.unwrap() < 50);

    // 3. After sleeping beyond settle threshold, elapsed exceeds settle duration
    thread::sleep(Duration::from_millis(160));
    let elapsed_after = millis_since_last_scroll().unwrap();
    assert!(
        elapsed_after >= SCROLL_STILL_SETTLE_MS,
        "Elapsed {}ms should exceed {}ms settle threshold",
        elapsed_after,
        SCROLL_STILL_SETTLE_MS
    );
}
