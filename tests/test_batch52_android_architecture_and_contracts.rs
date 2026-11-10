// test_batch52_android_architecture_and_contracts.rs
//
// Verification suite for Batch 52 (BUILD-014, PLATFORM-016, RES-062).

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_build014_android_abi_filter_and_so_name_contract() {
    let root = get_client_root();

    // 1. build.gradle must specify abiFilters "arm64-v8a" and libc++_shared packaging pick
    let build_gradle = fs::read_to_string(root.join("flutter/android/app/build.gradle"))
        .expect("Failed to read build.gradle");
    assert!(
        build_gradle.contains("abiFilters \"arm64-v8a\""),
        "build.gradle must contain abiFilters \"arm64-v8a\""
    );
    assert!(
        build_gradle.contains("pickFirsts += ['**/libc++_shared.so']"),
        "build.gradle must contain pickFirsts for libc++_shared.so"
    );

    // 2. ffi.kt must call System.loadLibrary("camellia_remote")
    let ffi_kt = fs::read_to_string(root.join("flutter/android/app/src/main/kotlin/ffi.kt"))
        .expect("Failed to read ffi.kt");
    assert!(
        ffi_kt.contains("System.loadLibrary(\"camellia_remote\")"),
        "ffi.kt must load camellia_remote"
    );

    // 3. build.py must stage libcamellia_remote.so
    let build_py = fs::read_to_string(root.join("build.py")).expect("Failed to read build.py");
    assert!(
        build_py.contains("jni_libs / \"libcamellia_remote.so\""),
        "build.py must copy to libcamellia_remote.so"
    );
}

#[test]
fn test_platform016_main_activity_method_channel_contracts() {
    let root = get_client_root();
    let activity = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/MainActivity.kt"),
    )
    .expect("Failed to read MainActivity.kt");

    // cancel_notification must return result.success(true) on valid ID
    assert!(
        activity.contains(
            "mainService?.cancelNotification(id)\n                        result.success(true)"
        ),
        "cancel_notification must reply result.success(true) on valid ID"
    );

    // enable_soft_keyboard must guard boolean argument
    assert!(
        activity
            .contains("result.error(\"invalid_argument\", \"Expected Boolean argument\", null)"),
        "enable_soft_keyboard must reject non-boolean arguments"
    );

    // on_voice_call_started and on_voice_call_closed must reply
    assert!(
        activity
            .contains("val res = onVoiceCallStarted()\n                    result.success(res)"),
        "on_voice_call_started must return result.success(res)"
    );
    assert!(
        activity.contains("val res = onVoiceCallClosed()\n                    result.success(res)"),
        "on_voice_call_closed must return result.success(res)"
    );

    // method handler must catch unhandled exceptions
    assert!(
        activity.contains("result.error(\"internal_error\", e.message, null)"),
        "initFlutterChannel must catch unhandled exceptions"
    );
}

#[test]
fn test_platform016_permission_callback_and_dart_manager() {
    let root = get_client_root();

    // common.kt must deliver all results, not just when all == true
    let common_kt = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/common.kt"),
    )
    .expect("Failed to read common.kt");
    assert!(
        !common_kt.contains("if (all) {\n                Handler"),
        "requestPermission must not gate callback on if (all)"
    );
    assert!(
        common_kt.contains("\"result\" to all"),
        "requestPermission must deliver result to Flutter"
    );

    // common.dart must use request ID and finite timeout
    let common_dart = fs::read_to_string(root.join("flutter/lib/common.dart"))
        .expect("Failed to read common.dart");
    assert!(
        common_dart.contains("static int _requestId = 0;"),
        "AndroidPermissionManager must track _requestId"
    );
    assert!(
        common_dart.contains("Duration(seconds: 15)"),
        "AndroidPermissionManager must use 15s timeout instead of 120s"
    );
    assert!(
        !common_dart.contains("Duration(seconds: 120)"),
        "AndroidPermissionManager must not retain 120s timer"
    );
}

#[test]
fn test_res062_android_lifecycle_and_teardown_contracts() {
    let root = get_client_root();

    // MainActivity binding lifecycle
    let activity = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/MainActivity.kt"),
    )
    .expect("Failed to read MainActivity.kt");
    assert!(
        activity.contains("private var isBound = false"),
        "MainActivity must track isBound"
    );
    assert!(
        activity.contains("audioRecordHandle.destroy()"),
        "MainActivity onDestroy must destroy audioRecordHandle"
    );
    assert!(
        activity.contains("cleanUpFlutterEngine"),
        "MainActivity must clean up FlutterEngine channel handler"
    );

    // MainService destroy
    let service = fs::read_to_string(
        root.join("flutter/android/app/src/main/kotlin/com/camellia/remote/MainService.kt"),
    )
    .expect("Failed to read MainService.kt");
    assert!(
        service.contains("audioRecordHandle.destroy()"),
        "MainService destroy must call audioRecordHandle.destroy()"
    );

    // DesktopDropPlugin config change
    let drop = fs::read_to_string(
        root.join("flutter/plugins/desktop_drop/android/src/main/kotlin/one/mixin/desktop/drop/DesktopDropPlugin.kt"),
    )
    .expect("Failed to read DesktopDropPlugin.kt");
    assert!(
        drop.contains("override fun onDetachedFromActivityForConfigChanges()"),
        "DesktopDropPlugin must handle onDetachedFromActivityForConfigChanges"
    );
    assert!(
        drop.contains("override fun onReattachedToActivityForConfigChanges"),
        "DesktopDropPlugin must handle onReattachedToActivityForConfigChanges"
    );

    // UniLinksPlugin channels and lifecycle
    let unilinks = fs::read_to_string(root.join(
        "flutter/android/uni_links_v2/src/main/java/name/avioli/unilinks/UniLinksPlugin.java",
    ))
    .expect("Failed to read UniLinksPlugin.java");
    assert!(
        unilinks.contains("private MethodChannel methodChannel;"),
        "UniLinksPlugin must store methodChannel"
    );
    assert!(
        unilinks.contains("activityPluginBinding.removeOnNewIntentListener(this);"),
        "UniLinksPlugin must remove intent listener on detach"
    );

    // Rust ffi generation and handle decoupling
    let ffi_rs = fs::read_to_string(root.join("libs/scrap/src/android/ffi.rs"))
        .expect("Failed to read ffi.rs");
    assert!(
        ffi_rs.contains("static MAIN_SERVICE_GENERATION: AtomicU64"),
        "ffi.rs must declare MAIN_SERVICE_GENERATION"
    );
    assert!(
        ffi_rs.contains("fn get_main_service_handles() -> Option<(JavaVM, GlobalRef)>"),
        "ffi.rs must provide get_main_service_handles to drop locks before JNI calls"
    );
}
