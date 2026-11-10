// test_batch54_android_clipboard_contracts.rs
//
// Verification suite for Batch 54 (PLATFORM-018).

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_platform018_android_clipboard_manager_contracts() {
    let root = get_client_root();
    let manager_path =
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/RdClipboardManager.kt");
    let manager = fs::read_to_string(&manager_path).expect("Failed to read RdClipboardManager.kt");

    // 1. ArrayIndexOutOfBoundsException guard: MIME type comparison separated from itemCount loop
    assert!(
        manager.contains("leftMimes != rightMimes"),
        "PLATFORM-018: isClipboardDataEqual must compare MIME types independently of items"
    );
    assert!(
        !manager.contains("for (i in 0 until left.itemCount) {\n            val leftItem = left.getItemAt(i)\n            val rightItem = right.getItemAt(i)\n            val mimeType = left.description.getMimeType(i)"),
        "PLATFORM-018: isClipboardDataEqual must not index description.getMimeType with itemCount loop variable"
    );

    // 2. Empty MIME types / unsupported payload guard
    assert!(
        manager.contains("text == null && html == null"),
        "PLATFORM-018: rustUpdateClipboard must guard against empty text/html before creating ClipDescription"
    );
    assert!(
        manager.contains("mimeTypes.isEmpty()"),
        "PLATFORM-018: rustUpdateClipboard must guard against empty mimeTypes array"
    );

    // 3. Main Looper dispatch for setPrimaryClip
    assert!(
        manager.contains("mainHandler.post"),
        "PLATFORM-018: rustUpdateClipboard must post setPrimaryClip to mainHandler"
    );
    assert!(
        manager.contains("Looper.getMainLooper()"),
        "PLATFORM-018: RdClipboardManager must bind mainHandler to Looper.getMainLooper()"
    );

    // 4. Volatile annotations for cross-thread memory visibility
    let volatile_count = manager.matches("@Volatile").count();
    assert!(
        volatile_count >= 3,
        "PLATFORM-018: RdClipboardManager must have @Volatile annotations on mutable state fields (found {})",
        volatile_count
    );

    // 5. Cleanup method
    assert!(
        manager.contains("fun cleanup()"),
        "PLATFORM-018: RdClipboardManager must provide a cleanup method"
    );
}

#[test]
fn test_platform018_android_clipboard_lifecycle_and_service_contracts() {
    let root = get_client_root();
    let activity = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/MainActivity.kt"),
    )
    .expect("Failed to read MainActivity.kt");

    let service = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/MainService.kt"),
    )
    .expect("Failed to read MainService.kt");

    let floating =
        fs::read_to_string(root.join(
            "flutter/android/app/src/main/kotlin/com/camellia/remote/FloatingWindowService.kt",
        ))
        .expect("Failed to read FloatingWindowService.kt");

    // 1. MainActivity singleton / fallback factory
    assert!(
        activity
            .contains("fun getOrCreateRdClipboardManager(context: Context): RdClipboardManager"),
        "PLATFORM-018: MainActivity must provide getOrCreateRdClipboardManager"
    );
    assert!(
        activity.contains("fun cleanupClipboardManager()"),
        "PLATFORM-018: MainActivity must provide cleanupClipboardManager"
    );
    assert!(
        activity.contains("cleanupClipboardManager()"),
        "PLATFORM-018: MainActivity onDestroy must invoke cleanupClipboardManager"
    );

    // 2. MainService fallback initialization
    assert!(
        service.contains("MainActivity.getOrCreateRdClipboardManager(applicationContext)"),
        "PLATFORM-018: MainService must use getOrCreateRdClipboardManager fallback on capture start"
    );
    assert!(
        service.contains("MainActivity.cleanupClipboardManager()"),
        "PLATFORM-018: MainService destroy must cleanup clipboard manager if activity is absent"
    );

    // 3. FloatingWindowService safe clipboard sync
    assert!(
        floating.contains(
            "MainActivity.getOrCreateRdClipboardManager(applicationContext).syncClipboard(false)"
        ),
        "PLATFORM-018: FloatingWindowService must safely obtain clipboard manager on syncClipboard"
    );
}

#[test]
fn test_platform018_scrap_android_jni_contracts() {
    let root = get_client_root();
    let ffi_rs = fs::read_to_string(root.join("libs/scrap/src/android/ffi.rs"))
        .expect("Failed to read ffi.rs");
    let ffi_kt = fs::read_to_string(root.join("flutter/android/app/src/main/kotlin/ffi.kt"))
        .expect("Failed to read ffi.kt");

    // 1. Kotlin FFI external declaration
    assert!(
        ffi_kt.contains("fun cleanupClipboardManager()"),
        "PLATFORM-018: ffi.kt must declare cleanupClipboardManager"
    );

    // 2. Rust JNI cleanup export
    assert!(
        ffi_rs.contains("Java_ffi_FFI_cleanupClipboardManager"),
        "PLATFORM-018: ffi.rs must export Java_ffi_FFI_cleanupClipboardManager"
    );
    assert!(
        ffi_rs.contains("*CLIPBOARD_MANAGER.write().unwrap() = None"),
        "PLATFORM-018: cleanupClipboardManager must drop the global JObject reference"
    );

    // 3. JNI pending exception checking and clearing
    assert!(
        ffi_rs.contains("env.exception_check().unwrap_or(false)"),
        "PLATFORM-018: JNI clipboard calls must inspect exception_check"
    );
    assert!(
        ffi_rs.contains("let _ = env.exception_clear();"),
        "PLATFORM-018: JNI clipboard calls must invoke exception_clear on pending exception"
    );
}
