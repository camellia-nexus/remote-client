#!/usr/bin/env python3
"""
Contract verification suite for Linux Wayland Shortcuts Inhibitor & Plugin Defensive Contracts
(PLATFORM-014, PLATFORM-015).
"""

import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

class LinuxWaylandAndPluginContractsTests(unittest.TestCase):
    # --------------------------------------------------------------------------
    # PLATFORM-014: Wayland Keyboard Shortcuts Inhibit Non-Blocking Architecture
    # --------------------------------------------------------------------------
    def test_platform014_wayland_shortcuts_header_api(self):
        """PLATFORM-014: wayland_shortcuts_inhibit.h exports necessary APIs and C ABI safety."""
        h_path = os.path.join(REPO_ROOT, "flutter", "linux", "wayland_shortcuts_inhibit.h")
        self.assertTrue(os.path.exists(h_path), f"Missing {h_path}")
        with open(h_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("bool wayland_shortcuts_inhibit_is_supported(GdkDisplay* display);", content)
        self.assertIn("void wayland_shortcuts_inhibit_init_for_subwindow(void* view);", content)
        self.assertIn("bool wayland_shortcuts_inhibit_set_enabled(GtkWindow* window, bool enabled);", content)
        self.assertIn("const char* wayland_shortcuts_inhibit_get_state(GtkWindow* window);", content)
        self.assertIn("void wayland_shortcuts_inhibit_teardown(GtkWindow* window);", content)
        self.assertIn('extern "C"', content)

    def test_platform014_wayland_shortcuts_no_roundtrip_in_focus(self):
        """PLATFORM-014: wayland_shortcuts_inhibit.cc caches manager and flushes without roundtrip in focus path."""
        cc_path = os.path.join(REPO_ROOT, "flutter", "linux", "wayland_shortcuts_inhibit.cc")
        self.assertTrue(os.path.exists(cc_path), f"Missing {cc_path}")
        with open(cc_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Must cache display manager
        self.assertIn("wayland-shortcuts-display-manager", content)
        self.assertIn("zwp_keyboard_shortcuts_inhibit_manager_v1", content)
        self.assertIn("DisplayWaylandManager", content)

        # Focus in/out must not call wl_display_roundtrip
        focus_in_match = re.search(r"static gboolean on_window_focus_in.*?\n\}", content, re.DOTALL)
        self.assertIsNotNone(focus_in_match)
        self.assertNotIn("wl_display_roundtrip", focus_in_match.group(0))

        apply_match = re.search(r"static void apply_inhibitor_nonblocking.*?\n\}", content, re.DOTALL)
        self.assertIsNotNone(apply_match)
        self.assertNotIn("wl_display_roundtrip", apply_match.group(0))
        self.assertIn("wl_display_flush(wl_display)", apply_match.group(0))

        # Default disabled for subwindows and tracking active/inactive
        self.assertIn("wid->enabled = false", content)
        self.assertIn("inhibitor_active", content)
        self.assertIn("inhibitor_inactive", content)
        self.assertIn("INHIBIT_STATE_ACTIVE", content)
        self.assertIn("INHIBIT_STATE_INACTIVE", content)

    def test_platform014_my_application_host_channel_and_subwindow_wiring(self):
        """PLATFORM-014: my_application.cc wires subwindow host channel and inhibit methods."""
        app_path = os.path.join(REPO_ROOT, "flutter", "linux", "my_application.cc")
        self.assertTrue(os.path.exists(app_path), f"Missing {app_path}")
        with open(app_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Subwindow creation wires host channel
        self.assertIn("subwindow-host-channel", content)
        self.assertIn('"com.camellia.remote/host"', content)

        # Host channel handler processes setWaylandShortcutsInhibit & getWaylandShortcutsInhibitState
        self.assertIn('strcmp(method_name, "setWaylandShortcutsInhibit") == 0', content)
        self.assertIn('strcmp(method_name, "getWaylandShortcutsInhibitState") == 0', content)
        self.assertIn("wayland_shortcuts_inhibit_set_enabled", content)
        self.assertIn("wayland_shortcuts_inhibit_get_state", content)

    def test_platform014_dart_platform_channel_and_remote_page(self):
        """PLATFORM-014: Dart platform_channel and remote_page manage shortcut inhibition per remote session."""
        pc_path = os.path.join(REPO_ROOT, "flutter", "lib", "utils", "platform_channel.dart")
        self.assertTrue(os.path.exists(pc_path), f"Missing {pc_path}")
        with open(pc_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("setWaylandShortcutsInhibit", content)
        self.assertIn("getWaylandShortcutsInhibitState", content)

        rp_path = os.path.join(REPO_ROOT, "flutter", "lib", "desktop", "pages", "remote_page.dart")
        self.assertTrue(os.path.exists(rp_path), f"Missing {rp_path}")
        with open(rp_path, "r", encoding="utf-8") as f:
            rp_content = f.read()

        self.assertIn("setWaylandShortcutsInhibit(enabled: true)", rp_content)
        self.assertIn("setWaylandShortcutsInhibit(enabled: false)", rp_content)

    # --------------------------------------------------------------------------
    # PLATFORM-015: Linux Window, Screen & Texture Defensive Contracts
    # --------------------------------------------------------------------------
    def test_platform015_screen_retriever_null_and_error_handling(self):
        """PLATFORM-015: screen_retriever guards display/seat/pointer and never returns NULL FlMethodResponse."""
        sr_path = os.path.join(REPO_ROOT, "flutter", "plugins", "screen_retriever", "linux", "screen_retriever_plugin.cc")
        self.assertTrue(os.path.exists(sr_path), f"Missing {sr_path}")
        with open(sr_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("display == nullptr", content)
        self.assertIn("seat == nullptr", content)
        self.assertIn("pointer == nullptr", content)
        self.assertIn("monitor_count <= 0", content)
        self.assertIn("fl_method_error_response_new", content)
        self.assertIn('"unavailable"', content)
        self.assertIn("if (response == nullptr)", content)

    def test_platform015_calc_window_position_timeouts_and_fallbacks(self):
        """PLATFORM-015: calc_window_position has timeouts and fallbacks for display RPCs."""
        calc_path = os.path.join(REPO_ROOT, "flutter", "plugins", "window_manager", "lib", "src", "utils", "calc_window_position.dart")
        self.assertTrue(os.path.exists(calc_path), f"Missing {calc_path}")
        with open(calc_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn(".timeout(const Duration(seconds: 2))", content)
        self.assertIn("primaryDisplay ??= Display(", content)
        self.assertIn("cursorScreenPoint ??= const Offset(0, 0);", content)

    def test_platform015_texture_rgba_renderer_malformed_defense(self):
        """PLATFORM-015: texture_rgba_renderer validates container, types, and avoids inserting NULL on missing keys."""
        tr_path = os.path.join(REPO_ROOT, "flutter", "plugins", "texture_rgba_renderer", "linux", "texture_rgba_renderer_plugin.cc")
        self.assertTrue(os.path.exists(tr_path), f"Missing {tr_path}")
        with open(tr_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("FL_VALUE_TYPE_MAP", content)
        self.assertIn("FL_VALUE_TYPE_UINT8_LIST", content)
        self.assertIn("FL_VALUE_TYPE_INT", content)
        self.assertIn("renderer_map->find(key) == self->renderer_map->end()", content)
        self.assertIn('"not_found"', content)

    def test_platform015_desktop_multi_window_argument_validation(self):
        """PLATFORM-015: desktop_multi_window validates args types across window_channel and plugin."""
        wc_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "window_channel.cc")
        self.assertTrue(os.path.exists(wc_path), f"Missing {wc_path}")
        with open(wc_path, "r", encoding="utf-8") as f:
            wc_content = f.read()

        self.assertIn("FL_VALUE_TYPE_MAP", wc_content)
        self.assertIn("targetWindowId", wc_content)

        mw_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "desktop_multi_window_plugin.cc")
        self.assertTrue(os.path.exists(mw_path), f"Missing {mw_path}")
        with open(mw_path, "r", encoding="utf-8") as f:
            mw_content = f.read()

        self.assertIn("get_int_arg", mw_content)
        self.assertIn("get_float_arg", mw_content)
        self.assertIn("get_bool_arg", mw_content)
        self.assertIn("get_string_arg", mw_content)
        self.assertIn("fl_method_not_implemented_response_new()", mw_content)

    def test_platform015_window_manager_guards_and_resource_checks(self):
        """PLATFORM-015: window_manager_plugin validates method calls and checks window/display/seat/device."""
        wm_path = os.path.join(REPO_ROOT, "flutter", "plugins", "window_manager", "linux", "window_manager_plugin.cc")
        self.assertTrue(os.path.exists(wm_path), f"Missing {wm_path}")
        with open(wm_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Argument helpers
        self.assertIn("get_bool_arg", content)
        self.assertIn("get_float_arg", content)
        self.assertIn("get_int_arg", content)
        self.assertIn("get_string_arg", content)

        # Window & GdkWindow guards
        self.assertIn("get_window(self) == nullptr", content)
        self.assertIn("get_gdk_window(self)", content)

        # Hardware pointer & seat guards in start_dragging / start_resizing / pop_up_window_menu
        self.assertIn("device == nullptr", content)
        self.assertIn("seat == nullptr", content)
        self.assertIn("display == nullptr", content)
        self.assertIn("screen == nullptr", content)

        # Safe fallback response
        self.assertIn("if (response == nullptr)", content)
        self.assertIn('"internal_error"', content)

if __name__ == "__main__":
    unittest.main()
