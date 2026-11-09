//! Batch 50 Contract Verification: Linux Wayland Shortcuts Inhibitor & Plugin Defensive Contracts Cluster
//! Covers:
//! - PLATFORM-014: Wayland keyboard shortcuts inhibitor non-blocking architecture, per-window enablement, and display caching.
//! - PLATFORM-015: Linux window_manager, desktop_multi_window, screen_retriever, and texture_rgba_renderer defensive contracts.

use std::fs;
use std::path::PathBuf;

fn get_workspace_client_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_platform014_wayland_shortcuts_inhibit_architecture() {
    let client_dir = get_workspace_client_dir();
    let h_path = client_dir.join("flutter/linux/wayland_shortcuts_inhibit.h");
    let cc_path = client_dir.join("flutter/linux/wayland_shortcuts_inhibit.cc");
    let app_path = client_dir.join("flutter/linux/my_application.cc");

    assert!(h_path.exists(), "wayland_shortcuts_inhibit.h must exist");
    assert!(cc_path.exists(), "wayland_shortcuts_inhibit.cc must exist");
    assert!(app_path.exists(), "my_application.cc must exist");

    let h_content =
        fs::read_to_string(&h_path).expect("Failed to read wayland_shortcuts_inhibit.h");
    let cc_content =
        fs::read_to_string(&cc_path).expect("Failed to read wayland_shortcuts_inhibit.cc");
    let app_content = fs::read_to_string(&app_path).expect("Failed to read my_application.cc");

    // Header declarations
    assert!(
        h_content.contains("wayland_shortcuts_inhibit_is_supported(GdkDisplay* display)"),
        "wayland_shortcuts_inhibit.h must declare wayland_shortcuts_inhibit_is_supported"
    );
    assert!(
        h_content.contains("wayland_shortcuts_inhibit_init_for_subwindow(void* view)"),
        "wayland_shortcuts_inhibit.h must declare wayland_shortcuts_inhibit_init_for_subwindow"
    );
    assert!(
        h_content
            .contains("wayland_shortcuts_inhibit_set_enabled(GtkWindow* window, bool enabled)"),
        "wayland_shortcuts_inhibit.h must declare wayland_shortcuts_inhibit_set_enabled"
    );
    assert!(
        h_content.contains("wayland_shortcuts_inhibit_get_state(GtkWindow* window)"),
        "wayland_shortcuts_inhibit.h must declare wayland_shortcuts_inhibit_get_state"
    );
    assert!(
        h_content.contains("wayland_shortcuts_inhibit_teardown(GtkWindow* window)"),
        "wayland_shortcuts_inhibit.h must declare wayland_shortcuts_inhibit_teardown"
    );

    // Implementation caching & non-blocking execution
    assert!(
        cc_content.contains("wayland-shortcuts-display-manager"),
        "wayland_shortcuts_inhibit.cc must cache manager per GdkDisplay"
    );
    assert!(
        cc_content.contains("wl_display_flush(wl_display)"),
        "wayland_shortcuts_inhibit.cc must use non-blocking wl_display_flush"
    );
    assert!(
        cc_content.contains("wid->enabled = false"),
        "wayland_shortcuts_inhibit.cc must default enabled to false for subwindows"
    );
    assert!(
        cc_content.contains("inhibitor_active"),
        "wayland_shortcuts_inhibit.cc must listen to inhibitor_active"
    );
    assert!(
        cc_content.contains("inhibitor_inactive"),
        "wayland_shortcuts_inhibit.cc must listen to inhibitor_inactive"
    );

    // my_application subwindow wiring & method channel
    assert!(
        app_content.contains("subwindow-host-channel"),
        "my_application.cc must set subwindow-host-channel"
    );
    assert!(
        app_content.contains("\"com.camellia.remote/host\""),
        "my_application.cc must register com.camellia.remote/host on subwindows"
    );
    assert!(
        app_content.contains("strcmp(method_name, \"setWaylandShortcutsInhibit\") == 0"),
        "my_application.cc must handle setWaylandShortcutsInhibit"
    );
    assert!(
        app_content.contains("strcmp(method_name, \"getWaylandShortcutsInhibitState\") == 0"),
        "my_application.cc must handle getWaylandShortcutsInhibitState"
    );
}

#[test]
fn test_platform014_dart_shortcuts_inhibit_lifecycle() {
    let client_dir = get_workspace_client_dir();
    let pc_path = client_dir.join("flutter/lib/utils/platform_channel.dart");
    let rp_path = client_dir.join("flutter/lib/desktop/pages/remote_page.dart");

    assert!(pc_path.exists(), "platform_channel.dart must exist");
    assert!(rp_path.exists(), "remote_page.dart must exist");

    let pc_content = fs::read_to_string(&pc_path).expect("Failed to read platform_channel.dart");
    let rp_content = fs::read_to_string(&rp_path).expect("Failed to read remote_page.dart");

    // RdPlatformChannel methods
    assert!(
        pc_content.contains("Future<bool> setWaylandShortcutsInhibit({required bool enabled})"),
        "platform_channel.dart must define setWaylandShortcutsInhibit"
    );
    assert!(
        pc_content.contains("Future<String?> getWaylandShortcutsInhibitState()"),
        "platform_channel.dart must define getWaylandShortcutsInhibitState"
    );

    // RemotePage lifecycle invocations
    assert!(
        rp_content.contains("setWaylandShortcutsInhibit(enabled: true)"),
        "remote_page.dart must enable shortcuts inhibit on remote desktop initialization/restore"
    );
    assert!(
        rp_content.contains("setWaylandShortcutsInhibit(enabled: false)"),
        "remote_page.dart must disable shortcuts inhibit on minimize/teardown"
    );
}

#[test]
fn test_platform015_screen_retriever_and_calc_window_position() {
    let client_dir = get_workspace_client_dir();
    let sr_path =
        client_dir.join("flutter/plugins/screen_retriever/linux/screen_retriever_plugin.cc");
    let calc_path =
        client_dir.join("flutter/plugins/window_manager/lib/src/utils/calc_window_position.dart");

    assert!(sr_path.exists(), "screen_retriever_plugin.cc must exist");
    assert!(calc_path.exists(), "calc_window_position.dart must exist");

    let sr_content =
        fs::read_to_string(&sr_path).expect("Failed to read screen_retriever_plugin.cc");
    let calc_content =
        fs::read_to_string(&calc_path).expect("Failed to read calc_window_position.dart");

    // screen_retriever checks
    assert!(
        sr_content.contains("display == nullptr"),
        "screen_retriever_plugin.cc must check display null"
    );
    assert!(
        sr_content.contains("monitor_count <= 0"),
        "screen_retriever_plugin.cc must check monitor_count <= 0"
    );
    assert!(
        sr_content.contains("fl_method_error_response_new"),
        "screen_retriever_plugin.cc must return fl_method_error_response_new on missing monitors"
    );
    assert!(
        sr_content.contains("if (response == nullptr)"),
        "screen_retriever_plugin.cc must ensure fallback response if response is null"
    );

    // calc_window_position fallbacks and timeouts
    assert!(
        calc_content.contains(".timeout(const Duration(seconds: 2))"),
        "calc_window_position.dart must apply 2-second timeout on RPC calls"
    );
    assert!(
        calc_content.contains("primaryDisplay ??= Display("),
        "calc_window_position.dart must provide fallback primary display"
    );
    assert!(
        calc_content.contains("cursorScreenPoint ??= const Offset(0, 0);"),
        "calc_window_position.dart must provide fallback cursor screen point"
    );
}

#[test]
fn test_platform015_linux_plugin_defensive_contracts() {
    let client_dir = get_workspace_client_dir();
    let tr_path = client_dir
        .join("flutter/plugins/texture_rgba_renderer/linux/texture_rgba_renderer_plugin.cc");
    let wc_path = client_dir.join("flutter/plugins/desktop_multi_window/linux/window_channel.cc");
    let mw_path = client_dir
        .join("flutter/plugins/desktop_multi_window/linux/desktop_multi_window_plugin.cc");
    let wm_path = client_dir.join("flutter/plugins/window_manager/linux/window_manager_plugin.cc");

    assert!(
        tr_path.exists(),
        "texture_rgba_renderer_plugin.cc must exist"
    );
    assert!(wc_path.exists(), "window_channel.cc must exist");
    assert!(
        mw_path.exists(),
        "desktop_multi_window_plugin.cc must exist"
    );
    assert!(wm_path.exists(), "window_manager_plugin.cc must exist");

    let tr_content =
        fs::read_to_string(&tr_path).expect("Failed to read texture_rgba_renderer_plugin.cc");
    let wc_content = fs::read_to_string(&wc_path).expect("Failed to read window_channel.cc");
    let mw_content =
        fs::read_to_string(&mw_path).expect("Failed to read desktop_multi_window_plugin.cc");
    let wm_content = fs::read_to_string(&wm_path).expect("Failed to read window_manager_plugin.cc");

    // texture_rgba_renderer validation
    assert!(
        tr_content.contains("FL_VALUE_TYPE_MAP"),
        "texture_rgba_renderer must check for MAP type"
    );
    assert!(
        tr_content.contains("renderer_map->find(key) == self->renderer_map->end()"),
        "texture_rgba_renderer must guard against missing key lookup"
    );
    assert!(
        tr_content.contains("\"not_found\""),
        "texture_rgba_renderer must return not_found error on missing key"
    );

    // desktop_multi_window validation
    assert!(
        wc_content.contains("targetWindowId"),
        "window_channel.cc must check targetWindowId"
    );
    assert!(
        mw_content.contains("get_int_arg") && mw_content.contains("get_float_arg"),
        "desktop_multi_window_plugin.cc must provide safe arg extractors"
    );
    assert!(
        mw_content.contains("fl_method_not_implemented_response_new()"),
        "desktop_multi_window_plugin.cc must return not_implemented for unknown methods"
    );

    // window_manager validation
    assert!(
        wm_content.contains("get_bool_arg") && wm_content.contains("get_string_arg"),
        "window_manager_plugin.cc must provide safe arg extractors"
    );
    assert!(
        wm_content.contains("get_window(self) == nullptr"),
        "window_manager_plugin.cc must guard against null get_window"
    );
    assert!(
        wm_content.contains("device == nullptr"),
        "window_manager_plugin.cc must guard against null device"
    );
    assert!(
        wm_content.contains("if (response == nullptr)"),
        "window_manager_plugin.cc must ensure fallback error response if null"
    );
}
