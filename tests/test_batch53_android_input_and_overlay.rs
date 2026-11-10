// test_batch53_android_input_and_overlay.rs
//
// Verification suite for Batch 53 (LOG-007, PLATFORM-017, COMPAT-006).

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_log007_android_input_service_and_mapper_privacy_contracts() {
    let root = get_client_root();
    let input_service = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/InputService.kt"),
    )
    .expect("Failed to read InputService.kt");

    let mapper =
        fs::read_to_string(root.join(
            "flutter/android/app/src/main/kotlin/com/camellia/remote/KeyboardKeyEventMapper.kt",
        ))
        .expect("Failed to read KeyboardKeyEventMapper.kt");

    // LOG-007: InputService must not log plaintext keystrokes, submitted text, or active accessibility nodes
    let forbidden_input_service_patterns = [
        "textToCommit",
        "possibleNodes",
        "focusInput",
        "childFromFocusInput",
        "childFromFocusAccessibilityInput",
        "rootInActiveWindow",
    ];

    for pattern in forbidden_input_service_patterns {
        for line in input_service.lines() {
            if line.trim_start().starts_with("Log.") {
                assert!(
                    !line.contains(pattern),
                    "LOG-007 violation: InputService.kt line logs sensitive pattern '{}': {}",
                    pattern,
                    line
                );
            }
        }
    }

    // LOG-007: KeyboardKeyEventMapper must not log keycodes or unicode values
    for line in mapper.lines() {
        if line.trim_start().starts_with("Log.") {
            assert!(
                !line.contains("unicode") && !line.contains("keycode"),
                "LOG-007 violation: KeyboardKeyEventMapper.kt line logs sensitive keys: {}",
                line
            );
        }
    }
}

#[test]
fn test_platform017_android_unicode_bounds_and_jni_exception_contracts() {
    let root = get_client_root();

    let mapper =
        fs::read_to_string(root.join(
            "flutter/android/app/src/main/kotlin/com/camellia/remote/KeyboardKeyEventMapper.kt",
        ))
        .expect("Failed to read KeyboardKeyEventMapper.kt");

    let input_service = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/InputService.kt"),
    )
    .expect("Failed to read InputService.kt");

    let ffi = fs::read_to_string(root.join("libs/scrap/src/android/ffi.rs"))
        .expect("Failed to read ffi.rs");

    // 1. Supplementary code points and validation in KeyboardKeyEventMapper
    assert!(
        mapper.contains("Character.isValidCodePoint"),
        "PLATFORM-017: KeyboardKeyEventMapper must validate Character.isValidCodePoint"
    );
    assert!(
        !mapper.contains("unicode.toChar()"),
        "PLATFORM-017: KeyboardKeyEventMapper must not truncate Unicode with toChar()"
    );
    assert!(
        mapper.contains("Character.toChars"),
        "PLATFORM-017: KeyboardKeyEventMapper must convert code points via Character.toChars"
    );

    // 2. Code point validation in InputService
    assert!(
        input_service.contains("Character.isValidCodePoint(chr)"),
        "PLATFORM-017: InputService must validate Character.isValidCodePoint(chr)"
    );
    assert!(
        input_service.contains("Character.toChars(chr)"),
        "PLATFORM-017: InputService must use Character.toChars(chr)"
    );

    // 3. Coordinate bounds clamping and main Looper redirection in InputService
    assert!(
        input_service.contains("Looper.myLooper() != Looper.getMainLooper()"),
        "PLATFORM-017: InputService must enforce main Looper dispatch"
    );
    assert!(
        input_service.contains(".coerceIn(0L, maxBoundX.toLong())"),
        "PLATFORM-017: InputService must clamp X coordinates within screen bounds"
    );
    assert!(
        input_service.contains(".coerceIn(0L, maxBoundY.toLong())"),
        "PLATFORM-017: InputService must clamp Y coordinates within screen bounds"
    );

    // 4. JNI thread pending exception checking in Rust ffi
    assert!(
        ffi.contains("exception_check"),
        "PLATFORM-017: Rust ffi.rs must check for pending JNI exceptions"
    );
    assert!(
        ffi.contains("exception_clear"),
        "PLATFORM-017: Rust ffi.rs must clear pending JNI exceptions"
    );
}

#[test]
fn test_compat006_floating_window_touch_lifecycle_and_stop_fallback() {
    let root = get_client_root();

    let floating_window =
        fs::read_to_string(root.join(
            "flutter/android/app/src/main/kotlin/com/camellia/remote/FloatingWindowService.kt",
        ))
        .expect("Failed to read FloatingWindowService.kt");

    let main_activity = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/MainActivity.kt"),
    )
    .expect("Failed to read MainActivity.kt");

    let server_page = fs::read_to_string(root.join("flutter/lib/mobile/pages/server_page.dart"))
        .expect("Failed to read server_page.dart");

    // 1. FloatingWindowService touch consumption
    assert!(
        floating_window.contains("MotionEvent.ACTION_DOWN ->"),
        "COMPAT-006: FloatingWindowService must handle MotionEvent.ACTION_DOWN"
    );
    assert!(
        floating_window.contains("MotionEvent.ACTION_CANCEL ->"),
        "COMPAT-006: FloatingWindowService must handle MotionEvent.ACTION_CANCEL"
    );
    assert!(
        !floating_window.contains("return false\n    }\n\n    private fun moveToScreenSide"),
        "COMPAT-006: onTouch must not unconditionally return false"
    );

    // 2. Attachment tracking and safe removal
    assert!(
        floating_window.contains("isAttached = true"),
        "COMPAT-006: FloatingWindowService must mark isAttached = true after addView"
    );
    assert!(
        floating_window.contains("if (isAttached) {"),
        "COMPAT-006: FloatingWindowService must guard removeView with isAttached check"
    );

    // 3. Direct stop fallback
    assert!(
        floating_window.contains("stopService(Intent(this, MainService::class.java))"),
        "COMPAT-006: FloatingWindowService must fall back to direct stopService(MainService)"
    );

    // 4. MainActivity background service start protection
    let on_stop_idx = main_activity
        .find("override fun onStop()")
        .expect("MainActivity must implement onStop");
    let on_stop_snippet = &main_activity[on_stop_idx..on_stop_idx + 400];
    assert!(
        on_stop_snippet.contains("try {") && on_stop_snippet.contains("startService(Intent(this, FloatingWindowService::class.java))"),
        "COMPAT-006: MainActivity.onStop must wrap startService in try/catch for Android 8+ background restrictions"
    );

    // 5. Dart server_page stop_service contract
    assert!(
        server_page.contains("case \"stop_service\":\n          {\n            print(\n              \"stop_service by kotlin"),
        "COMPAT-006: server_page.dart must handle stop_service message"
    );
    assert!(
        !server_page.contains("case \"stop_service\":\n          {\n            print(\n              \"stop_service by kotlin, isStart:${gFFI.serverModel.isStart}\",\n            );\n            if (gFFI.serverModel.isStart) {"),
        "COMPAT-006: server_page.dart must not gate stopService() on isStart"
    );
}
