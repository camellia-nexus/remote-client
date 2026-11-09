//! Batch 48 Contract Verification: Linux Native Window & GObject Safety Cluster
//! Covers:
//! - UNSAFE-012: Linux multi-window lifecycle, emission hook disconnect, and deferred destruction.
//! - UNSAFE-013: Linux custom cursor GObject struct raw pointer safety, dispose unrefs, and pixbuf bounds.
//! - STATE-029: Linux cross-window RPC error responses, non-null responses, and Dart timeouts.

use std::fs;
use std::path::PathBuf;

fn get_workspace_client_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_unsafe012_linux_flutter_window_emission_hooks_and_cleanup() {
    let client_dir = get_workspace_client_dir();
    let header_path =
        client_dir.join("flutter/plugins/desktop_multi_window/linux/flutter_window.h");
    let cc_path = client_dir.join("flutter/plugins/desktop_multi_window/linux/flutter_window.cc");

    assert!(header_path.exists(), "flutter_window.h must exist");
    assert!(cc_path.exists(), "flutter_window.cc must exist");

    let header = fs::read_to_string(&header_path).expect("Failed to read flutter_window.h");
    let cc = fs::read_to_string(&cc_path).expect("Failed to read flutter_window.cc");

    // Both press and release emission hook IDs must be tracked
    assert!(
        header.contains("gulong pressedEmissionHook"),
        "flutter_window.h must track pressedEmissionHook"
    );
    assert!(
        header.contains("gulong releasedEmissionHook"),
        "flutter_window.h must track releasedEmissionHook"
    );
    assert!(
        header.contains("void CleanupHooks();"),
        "flutter_window.h must declare CleanupHooks()"
    );

    // Both hooks must be registered via g_signal_add_emission_hook
    assert!(
        cc.contains("this->pressedEmissionHook = g_signal_add_emission_hook"),
        "flutter_window.cc must assign pressedEmissionHook"
    );
    assert!(
        cc.contains("this->releasedEmissionHook = g_signal_add_emission_hook"),
        "flutter_window.cc must assign releasedEmissionHook"
    );

    // CleanupHooks implementation must remove both hooks and disconnect handlers
    assert!(
        cc.contains("void FlutterWindow::CleanupHooks()"),
        "flutter_window.cc must implement CleanupHooks"
    );
    assert!(
        cc.contains("g_signal_remove_emission_hook(sig_id, this->pressedEmissionHook)"),
        "CleanupHooks must remove pressedEmissionHook"
    );
    assert!(
        cc.contains("g_signal_remove_emission_hook(sig_id, this->releasedEmissionHook)"),
        "CleanupHooks must remove releasedEmissionHook"
    );
    assert!(
        cc.contains("g_signal_handlers_disconnect_matched"),
        "CleanupHooks must disconnect signal handlers"
    );

    // Destructor must call CleanupHooks()
    assert!(
        cc.contains("CleanupHooks();"),
        "FlutterWindow destructor must call CleanupHooks"
    );
}

#[test]
fn test_unsafe012_on_window_close_uaf_elimination_and_deferred_destroy() {
    let client_dir = get_workspace_client_dir();
    let cc_path = client_dir.join("flutter/plugins/desktop_multi_window/linux/flutter_window.cc");
    let mgr_path =
        client_dir.join("flutter/plugins/desktop_multi_window/linux/multi_window_manager.cc");

    let cc = fs::read_to_string(&cc_path).expect("Failed to read flutter_window.cc");
    let mgr = fs::read_to_string(&mgr_path).expect("Failed to read multi_window_manager.cc");

    // In onWindowClose: must copy id_ locally, call CleanupHooks, and return FALSE
    assert!(
        cc.contains("int64_t id = self->id_;"),
        "onWindowClose must capture id_ by value before callbacks"
    );
    assert!(
        cc.contains("self->CleanupHooks();"),
        "onWindowClose must invoke CleanupHooks"
    );
    assert!(
        cc.contains("callback->OnWindowDestroy(id);"),
        "onWindowClose must pass local id to callback"
    );
    assert!(
        !cc.contains("return self->isPreventClose;"),
        "onWindowClose must never return self->isPreventClose after destruction"
    );

    // MultiWindowManager::OnWindowDestroy must defer destruction via g_idle_add
    assert!(
        mgr.contains("g_idle_add"),
        "OnWindowDestroy must defer erase via g_idle_add to avoid reentrancy crash"
    );
    assert!(
        mgr.contains("windows_.erase("),
        "Deferred callback must erase window from windows_ map"
    );
}

#[test]
fn test_unsafe013_custom_cursor_gobject_struct_and_dispose_safety() {
    let client_dir = get_workspace_client_dir();
    let cursor_cc_path = client_dir
        .join("flutter/plugins/flutter_custom_cursor/linux/flutter_custom_cursor_plugin.cc");
    assert!(
        cursor_cc_path.exists(),
        "flutter_custom_cursor_plugin.cc must exist"
    );

    let cc = fs::read_to_string(&cursor_cc_path)
        .expect("Failed to read flutter_custom_cursor_plugin.cc");

    // Struct must NOT contain std::unique_ptr (which is unconstructed by g_object_new)
    assert!(
        !cc.contains("unique_ptr<unordered_map"),
        "GObject struct must not contain std::unique_ptr"
    );
    assert!(
        cc.contains("std::unordered_map<std::string, GdkCursor*>* cache;"),
        "GObject struct must use raw pointer std::unordered_map"
    );

    // Init must allocate cache with operator new
    assert!(
        cc.contains("self->cache = new std::unordered_map<std::string, GdkCursor*>();"),
        "init must initialize cache with operator new"
    );

    // Dispose must unref all GdkCursor objects, delete cache, and unref registrar
    assert!(
        cc.contains("static void flutter_custom_cursor_plugin_dispose(GObject *object)"),
        "Plugin must implement GObject dispose"
    );
    assert!(
        cc.contains("g_object_unref(pair.second);"),
        "dispose must unref every cached GdkCursor"
    );
    assert!(
        cc.contains("delete self->cache;"),
        "dispose must delete cache"
    );
    assert!(
        cc.contains("g_object_unref(self->registrar);"),
        "dispose must unref registrar"
    );
}

#[test]
fn test_unsafe013_custom_cursor_error_paths_and_pixbuf_bounds() {
    let client_dir = get_workspace_client_dir();
    let cursor_cc_path = client_dir
        .join("flutter/plugins/flutter_custom_cursor/linux/flutter_custom_cursor_plugin.cc");
    let cc = fs::read_to_string(&cursor_cc_path)
        .expect("Failed to read flutter_custom_cursor_plugin.cc");

    // create_custom_cursor returns FlMethodResponse*, not std::string
    assert!(
        cc.contains("static FlMethodResponse* create_custom_cursor("),
        "create_custom_cursor must return FlMethodResponse*"
    );
    assert!(
        !cc.contains("std::string create_custom_cursor("),
        "create_custom_cursor must not return std::string"
    );

    // Loader write and close must check GError
    assert!(
        cc.contains("gdk_pixbuf_loader_write"),
        "Must call gdk_pixbuf_loader_write"
    );
    assert!(
        cc.contains("gdk_pixbuf_loader_close"),
        "Must call gdk_pixbuf_loader_close"
    );

    // Hotspot coordinates must be validated against pixbuf dimensions
    assert!(
        cc.contains("hot_x >= width"),
        "hot_x must be bound-checked against width"
    );
    assert!(
        cc.contains("hot_y >= height"),
        "hot_y must be bound-checked against height"
    );

    // Overwriting an existing cursor in cache must unref the previous cursor
    assert!(
        cc.contains("g_object_unref(it->second);"),
        "Overwriting cursor key must unref previous GdkCursor"
    );
}

#[test]
fn test_state029_window_channel_rpc_error_response_and_cleanup() {
    let client_dir = get_workspace_client_dir();
    let channel_cc_path =
        client_dir.join("flutter/plugins/desktop_multi_window/linux/window_channel.cc");
    assert!(channel_cc_path.exists(), "window_channel.cc must exist");

    let cc = fs::read_to_string(&channel_cc_path).expect("Failed to read window_channel.cc");

    // WindowChannel::InvokeMethod must handle error != nullptr by responding with an error response
    assert!(
        cc.contains("fl_method_error_response_new("),
        "InvokeMethod must produce an FlMethodErrorResponse when call fails"
    );
    assert!(
        cc.contains("g_error_free(error);"),
        "InvokeMethod must free GError on error"
    );
    assert!(
        cc.contains("g_object_unref(result);"),
        "InvokeMethod must unref response after fl_method_call_respond"
    );
}

#[test]
fn test_state029_pubspec_and_vendoring_integrity() {
    let client_dir = get_workspace_client_dir();
    let pubspec_path = client_dir.join("flutter/pubspec.yaml");
    let pubspec = fs::read_to_string(&pubspec_path).expect("Failed to read pubspec.yaml");

    // Both plugins must be vendored via local path dependencies
    assert!(
        pubspec.contains("desktop_multi_window:\n    path: plugins/desktop_multi_window"),
        "desktop_multi_window must be pointed to plugins/desktop_multi_window"
    );
    assert!(
        pubspec.contains("flutter_custom_cursor:\n    path: plugins/flutter_custom_cursor"),
        "flutter_custom_cursor must be pointed to plugins/flutter_custom_cursor"
    );
}
