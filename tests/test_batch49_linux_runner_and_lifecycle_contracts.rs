//! Batch 49 Contract Verification: Linux Runner, Provenance & Lifecycle Hardening Cluster
//! Covers:
//! - PLATFORM-012: Linux host MethodChannel malformed args, int64 delta bounds, and unknown method response.
//! - PROV-004: Linux release pins immutable AppImageKit 1.9.1 binary with SHA-256 / byte-size checks and provenance metadata.
//! - PLATFORM-013: Linux loader reports fatal dynlib or symbol loading failure with non-zero exit codes (127/126).
//! - RES-061: Linux runner and pinned plugins perform native resource, emission hook, and per-view teardown.

use std::fs;
use std::path::PathBuf;

fn get_workspace_client_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_platform012_linux_host_method_channel_contract() {
    let client_dir = get_workspace_client_dir();
    let app_cc_path = client_dir.join("flutter/linux/my_application.cc");
    let bump_cc_path = client_dir.join("flutter/linux/bump_mouse_x11.cc");

    assert!(app_cc_path.exists(), "my_application.cc must exist");
    assert!(bump_cc_path.exists(), "bump_mouse_x11.cc must exist");

    let app_cc = fs::read_to_string(&app_cc_path).expect("Failed to read my_application.cc");
    let bump_cc = fs::read_to_string(&bump_cc_path).expect("Failed to read bump_mouse_x11.cc");

    // Must validate method name not null
    assert!(
        app_cc.contains("if (method_name == nullptr)"),
        "host_channel_call_handler must check method_name for null"
    );
    assert!(
        app_cc.contains("\"invalid_method\""),
        "host_channel_call_handler must return invalid_method error"
    );

    // Must handle bumpMouse method
    assert!(
        app_cc.contains("strcmp(method_name, \"bumpMouse\") == 0"),
        "host_channel_call_handler must handle bumpMouse"
    );

    // Must support both Map and List arguments
    assert!(
        app_cc.contains("FL_VALUE_TYPE_MAP"),
        "host_channel_call_handler must support Map arguments"
    );
    assert!(
        app_cc.contains("FL_VALUE_TYPE_LIST"),
        "host_channel_call_handler must support List arguments"
    );

    // Must check coordinate types and bounds
    assert!(
        app_cc.contains("kMaxCoordDelta"),
        "host_channel_call_handler must enforce kMaxCoordDelta bounds"
    );
    assert!(
        app_cc.contains("\"out_of_bounds\""),
        "host_channel_call_handler must return out_of_bounds error"
    );

    // Unknown method must respond not-implemented to prevent Dart call hang
    assert!(
        app_cc.contains("fl_method_not_implemented_response_new()"),
        "host_channel_call_handler must return not-implemented response for unknown methods"
    );

    // bump_mouse_x11 null guards
    assert!(
        bump_cc.contains("if (display == nullptr)"),
        "bump_mouse_x11 must guard display"
    );
    assert!(
        bump_cc.contains("if (seat == nullptr)"),
        "bump_mouse_x11 must guard seat"
    );
    assert!(
        bump_cc.contains("if (mouse_device == nullptr)"),
        "bump_mouse_x11 must guard mouse_device"
    );
    assert!(
        bump_cc.contains("if (screen == nullptr)"),
        "bump_mouse_x11 must guard screen"
    );
}

#[test]
fn test_prov004_linux_package_appimagetool_pinning() {
    let client_dir = get_workspace_client_dir();
    let pkg_path = client_dir.join(".github/scripts/package-linux.sh");

    assert!(pkg_path.exists(), "package-linux.sh must exist");
    let script = fs::read_to_string(&pkg_path).expect("Failed to read package-linux.sh");

    // Version must be explicitly pinned to 1.9.1
    assert!(
        script.contains("APPIMAGETOOL_VERSION=\"1.9.1\""),
        "package-linux.sh must pin AppImageKit version 1.9.1"
    );

    // Verified official download URL
    assert!(
        script.contains(
            "https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VERSION}"
        ),
        "package-linux.sh must use official immutable release URL"
    );

    // SHA-256 for x86_64
    assert!(
        script.contains("ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"),
        "package-linux.sh must contain x86_64 SHA-256 checksum"
    );

    // SHA-256 for aarch64
    assert!(
        script.contains("f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158"),
        "package-linux.sh must contain aarch64 SHA-256 checksum"
    );

    // Byte sizes
    assert!(
        script.contains("15092216"),
        "package-linux.sh must verify x86_64 byte size"
    );
    assert!(
        script.contains("14678536"),
        "package-linux.sh must verify aarch64 byte size"
    );

    // Cache dir support
    assert!(
        script.contains("APPIMAGETOOL_CACHE_DIR"),
        "package-linux.sh must support pre-cached appimagetool"
    );

    // Provenance metadata JSON generation
    assert!(
        script.contains("artifacts/toolchain-appimagetool-${appimage_arch}.json"),
        "package-linux.sh must generate provenance metadata JSON"
    );
}

#[test]
fn test_platform013_tri_state_core_main_and_loader_safety() {
    let client_dir = get_workspace_client_dir();
    let flutter_rs_path = client_dir.join("src/flutter.rs");
    let main_cc_path = client_dir.join("flutter/linux/main.cc");

    assert!(flutter_rs_path.exists(), "src/flutter.rs must exist");
    assert!(main_cc_path.exists(), "main.cc must exist");

    let flutter_rs = fs::read_to_string(&flutter_rs_path).expect("Failed to read src/flutter.rs");
    let main_cc = fs::read_to_string(&main_cc_path).expect("Failed to read main.cc");

    // Rust C ABI export
    assert!(
        flutter_rs.contains("CORE_MAIN_STATUS_START_UI: c_int = 1"),
        "flutter.rs must define CORE_MAIN_STATUS_START_UI"
    );
    assert!(
        flutter_rs.contains("CORE_MAIN_STATUS_HANDLED_EXIT: c_int = 0"),
        "flutter.rs must define CORE_MAIN_STATUS_HANDLED_EXIT"
    );
    assert!(
        flutter_rs.contains("CORE_MAIN_STATUS_FATAL: c_int = -1"),
        "flutter.rs must define CORE_MAIN_STATUS_FATAL"
    );
    assert!(
        flutter_rs.contains("pub unsafe extern \"C\" fn camellia_remote_core_main_status"),
        "flutter.rs must export camellia_remote_core_main_status"
    );
    assert!(
        flutter_rs.contains("std::panic::catch_unwind"),
        "camellia_remote_core_main_status must wrap in catch_unwind"
    );

    // C++ loader exit code contract
    assert!(
        main_cc.contains("enum class CoreMainResult"),
        "main.cc must define CoreMainResult enum"
    );
    assert!(
        main_cc.contains("*exit_code = 127;"),
        "main.cc must set exit_code 127 on dlopen failure"
    );
    assert!(
        main_cc.contains("*exit_code = 126;"),
        "main.cc must set exit_code 126 on dlsym failure"
    );
    assert!(
        main_cc.contains("if (path == nullptr || *path == '\\0')"),
        "main.cc is_command_exists must guard null PATH"
    );
    assert!(
        main_cc.contains("if (status == static_cast<int>(CoreMainResult::Fatal))"),
        "main.cc main() must handle Fatal result non-zero exit"
    );
}

#[test]
fn test_res061_linux_runner_and_pinned_plugins_lifecycle_cleanup() {
    let client_dir = get_workspace_client_dir();

    // 1. my_application icon unref
    let app_cc = fs::read_to_string(client_dir.join("flutter/linux/my_application.cc"))
        .expect("Failed to read my_application.cc");
    assert!(
        app_cc.contains("g_object_unref(icon);"),
        "my_application.cc must unref loaded icons"
    );

    // 2. desktop_multi_window flutter_window & base_flutter_window
    let fw_cc = fs::read_to_string(
        client_dir.join("flutter/plugins/desktop_multi_window/linux/flutter_window.cc"),
    )
    .expect("Failed to read flutter_window.cc");
    assert!(
        fw_cc.contains("g_object_unref(icon);"),
        "flutter_window.cc must unref loaded icons"
    );
    assert!(
        fw_cc.contains("g_autofree gchar *window_id_str = g_strdup_printf"),
        "flutter_window.cc must use g_autofree on window_id_str"
    );

    let base_cc = fs::read_to_string(
        client_dir.join("flutter/plugins/desktop_multi_window/linux/base_flutter_window.cc"),
    )
    .expect("Failed to read base_flutter_window.cc");
    assert!(
        base_cc.contains("g_list_free(children);"),
        "base_flutter_window.cc findEventBox must free children GList"
    );

    // 3. texture_rgba_renderer finalize & dispose
    let tex_h = fs::read_to_string(client_dir.join(
        "flutter/plugins/texture_rgba_renderer/linux/include/texture_rgba_renderer/texture_rgba_renderer.h",
    ))
    .expect("Failed to read texture_rgba_renderer.h");
    assert!(
        tex_h.contains("texture_rgba_finalize"),
        "texture_rgba_renderer.h must declare finalize"
    );
    assert!(
        tex_h.contains("g_mutex_clear(&self->mutex);"),
        "texture_rgba_renderer finalize must clear mutex"
    );

    let tex_cc = fs::read_to_string(
        client_dir
            .join("flutter/plugins/texture_rgba_renderer/linux/texture_rgba_renderer_plugin.cc"),
    )
    .expect("Failed to read texture_rgba_renderer_plugin.cc");
    assert!(
        tex_cc.contains("g_object_unref(tex);"),
        "texture_rgba_renderer_plugin.cc must unref texture on close and dispose"
    );

    // 4. window_manager find_event_box list free & hook removal
    let wm_cc = fs::read_to_string(
        client_dir.join("flutter/plugins/window_manager/linux/window_manager_plugin.cc"),
    )
    .expect("Failed to read window_manager_plugin.cc");
    assert!(
        wm_cc.contains("g_list_free(children);"),
        "window_manager_plugin.cc find_event_box must free children GList"
    );
    assert!(
        wm_cc.contains("g_signal_remove_emission_hook"),
        "window_manager_plugin.cc must remove emission hook on dispose"
    );
    assert!(
        wm_cc.contains("g_clear_object(&self->channel);"),
        "window_manager_plugin.cc must clear channel on dispose"
    );
    assert!(
        wm_cc.contains("g_clear_object(&self->registrar);"),
        "window_manager_plugin.cc must clear registrar on dispose"
    );

    // 5. desktop_drop
    let dd_cc = fs::read_to_string(
        client_dir.join("flutter/plugins/desktop_drop/linux/desktop_drop_plugin.cc"),
    )
    .expect("Failed to read desktop_drop_plugin.cc");
    assert!(
        dd_cc.contains("g_autofree gchar * lowercaseDesktopEnv = g_ascii_strdown(desktopEnv, -1);"),
        "desktop_drop_plugin.cc must use g_autofree on lowercaseDesktopEnv"
    );
    assert!(
        !dd_cc.contains("strdup(\"application/vnd.portal.filetransfer\")"),
        "desktop_drop_plugin.cc must not leak strdup in static entries"
    );
    assert!(
        dd_cc.contains("g_object_set_data_full(G_OBJECT(fl_view), \"desktop-drop-channel\", channel, g_object_unref);"),
        "desktop_drop_plugin.cc must bind channel to view lifecycle"
    );

    // 6. screen_retriever
    let sr_cc = fs::read_to_string(
        client_dir.join("flutter/plugins/screen_retriever/linux/screen_retriever_plugin.cc"),
    )
    .expect("Failed to read screen_retriever_plugin.cc");
    assert!(
        sr_cc.contains("g_clear_object(&self->registrar);"),
        "screen_retriever_plugin.cc must clear registrar on dispose"
    );
}
