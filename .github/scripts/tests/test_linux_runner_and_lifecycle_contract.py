#!/usr/bin/env python3
"""
Contract verification suite for Linux Runner, Provenance, and Native Lifecycle Hardening
(PLATFORM-012, PROV-004, RES-061, PLATFORM-013).
"""

import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

class LinuxRunnerAndLifecycleContractTests(unittest.TestCase):
    # --------------------------------------------------------------------------
    # PLATFORM-012: Linux Host MethodChannel Hardening & Bounds Validation
    # --------------------------------------------------------------------------
    def test_platform012_host_channel_call_handler_validation(self):
        """PLATFORM-012: host_channel_call_handler validates method, arguments, bounds, and unknown methods."""
        app_path = os.path.join(REPO_ROOT, "flutter", "linux", "my_application.cc")
        self.assertTrue(os.path.exists(app_path), f"Missing {app_path}")
        with open(app_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("void host_channel_call_handler(FlMethodChannel* channel", content)

        # Must check method == nullptr
        self.assertIn("if (method_name == nullptr)", content)
        self.assertIn("invalid_method", content)

        # Must check bumpMouse method
        self.assertIn('strcmp(method_name, "bumpMouse") == 0', content)

        # Must handle both Map and List argument types
        self.assertIn("FL_VALUE_TYPE_MAP", content)
        self.assertIn("FL_VALUE_TYPE_LIST", content)

        # Coordinate parsing must support int
        self.assertIn("FL_VALUE_TYPE_INT", content)

        # Bounds validation
        self.assertIn("kMaxCoordDelta", content)
        self.assertIn("out_of_bounds", content)

        # Unrecognized methods must respond with fl_method_not_implemented_response_new
        self.assertIn("fl_method_not_implemented_response_new", content)
        self.assertIn("fl_method_call_respond(method_call, response, nullptr)", content)

    def test_platform012_bump_mouse_x11_null_guards(self):
        """PLATFORM-012: bump_mouse_x11 guards against nullptr for display, seat, device, and screen."""
        x11_path = os.path.join(REPO_ROOT, "flutter", "linux", "bump_mouse_x11.cc")
        self.assertTrue(os.path.exists(x11_path), f"Missing {x11_path}")
        with open(x11_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("if (display == nullptr)", content)
        self.assertIn("if (seat == nullptr)", content)
        self.assertIn("if (mouse_device == nullptr)", content)
        self.assertIn("if (screen == nullptr)", content)
        self.assertIn("return false;", content)

    # --------------------------------------------------------------------------
    # PROV-004: Linux AppImageKit 1.9.1 Immutable Pinning & Provenance
    # --------------------------------------------------------------------------
    def test_prov004_package_linux_appimagetool_pinning(self):
        """PROV-004: package-linux.sh pins AppImageKit 1.9.1 with SHA-256 and size verification."""
        pkg_path = os.path.join(REPO_ROOT, ".github", "scripts", "package-linux.sh")
        self.assertTrue(os.path.exists(pkg_path), f"Missing {pkg_path}")
        with open(pkg_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Must pin exact version 1.9.1
        self.assertIn('APPIMAGETOOL_VERSION="1.9.1"', content)
        self.assertIn("https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VERSION}", content)

        # Must verify SHA-256 for x86_64 and aarch64
        self.assertIn("ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0", content)
        self.assertIn("f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158", content)

        # Must verify byte sizes
        self.assertIn("15092216", content)
        self.assertIn("14678536", content)

        # Must fail closed on checksum or size mismatch
        self.assertIn("expected_size", content)
        self.assertIn("expected_sha256", content)

        # Must generate provenance JSON artifact
        self.assertIn("toolchain-appimagetool-${appimage_arch}.json", content)

    # --------------------------------------------------------------------------
    # PLATFORM-013: Linux Core Main Tri-State Contract & Non-Zero Exit Code
    # --------------------------------------------------------------------------
    def test_platform013_rust_tri_state_export(self):
        """PLATFORM-013: Rust core exports camellia_remote_core_main_status with panic safety."""
        rust_path = os.path.join(REPO_ROOT, "src", "flutter.rs")
        self.assertTrue(os.path.exists(rust_path), f"Missing {rust_path}")
        with open(rust_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("pub const CORE_MAIN_STATUS_START_UI: c_int = 1;", content)
        self.assertIn("pub const CORE_MAIN_STATUS_HANDLED_EXIT: c_int = 0;", content)
        self.assertIn("pub const CORE_MAIN_STATUS_FATAL: c_int = -1;", content)
        self.assertIn("pub unsafe extern \"C\" fn camellia_remote_core_main_status", content)
        self.assertIn("std::panic::catch_unwind", content)

    def test_platform013_linux_main_cc_fatal_loader_exit_codes(self):
        """PLATFORM-013: main.cc detects dlopen/dlsym errors and returns non-zero exit codes."""
        main_path = os.path.join(REPO_ROOT, "flutter", "linux", "main.cc")
        self.assertTrue(os.path.exists(main_path), f"Missing {main_path}")
        with open(main_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Must define CoreMainResult enum
        self.assertIn("enum class CoreMainResult", content)
        self.assertIn("StartUi", content)
        self.assertIn("HandledExit", content)
        self.assertIn("Fatal", content)

        # dlopen failure must set exit_code 127
        self.assertIn("*exit_code = 127;", content)

        # dlsym failure must set exit_code 126
        self.assertIn("*exit_code = 126;", content)

        # PATH safety in is_command_exists
        self.assertIn("if (path == nullptr || *path == '\\0')", content)

        # Immutable dlerror handling
        self.assertIn("std::string err_str(error);", content)

        # main() handles fatal and handled exits
        self.assertIn("if (status == static_cast<int>(CoreMainResult::Fatal))", content)
        self.assertIn("if (status == static_cast<int>(CoreMainResult::HandledExit))", content)

    # --------------------------------------------------------------------------
    # RES-061: Native Resource & Window Lifecycle Teardown
    # --------------------------------------------------------------------------
    def test_res061_my_application_icon_unref(self):
        """RES-061: my_application.cc unrefs GdkPixbuf in default icon list loop."""
        app_path = os.path.join(REPO_ROOT, "flutter", "linux", "my_application.cc")
        with open(app_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Must call g_object_unref(icon) after gtk_window_set_default_icon_list
        self.assertIn("g_object_unref(icon);", content)

    def test_res061_desktop_multi_window_lifecycle_and_leaks(self):
        """RES-061: desktop_multi_window unrefs icons, frees window_id_str, and frees GList in findEventBox."""
        fw_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "flutter_window.cc")
        with open(fw_path, "r", encoding="utf-8") as f:
            fw_content = f.read()

        # Must unref icons in flutter_window.cc
        self.assertIn("g_object_unref(icon);", fw_content)

        # window_id_str must be g_autofree
        self.assertIn("g_autofree gchar *window_id_str = g_strdup_printf", fw_content)

        # base_flutter_window.cc findEventBox must free GList
        base_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "base_flutter_window.cc")
        with open(base_path, "r", encoding="utf-8") as f:
            base_content = f.read()
        self.assertIn("g_list_free(children);", base_content)

    def test_res061_texture_rgba_renderer_finalize_and_dispose(self):
        """RES-061: texture_rgba_renderer registers finalize to clear mutex and unrefs textures on dispose."""
        tex_h = os.path.join(REPO_ROOT, "flutter", "plugins", "texture_rgba_renderer", "linux", "include", "texture_rgba_renderer", "texture_rgba_renderer.h")
        with open(tex_h, "r", encoding="utf-8") as f:
            h_content = f.read()

        self.assertIn("void texture_rgba_finalize(GObject* object)", h_content)
        self.assertIn("g_mutex_clear(&self->mutex);", h_content)
        self.assertIn("delete[] self->buffer;", h_content)
        self.assertIn("delete[] self->prior_buffer;", h_content)
        self.assertIn("G_OBJECT_CLASS(klass)->finalize = texture_rgba_finalize;", h_content)

        tex_plugin = os.path.join(REPO_ROOT, "flutter", "plugins", "texture_rgba_renderer", "linux", "texture_rgba_renderer_plugin.cc")
        with open(tex_plugin, "r", encoding="utf-8") as f:
            plugin_content = f.read()

        self.assertIn("g_object_unref(tex);", plugin_content)
        self.assertIn("texture_rgba_renderer_plugin_dispose", plugin_content)

    def test_res061_window_manager_emission_hook_and_object_clearing(self):
        """RES-061: window_manager frees GList in find_event_box and cleans up hook/registrar/channel on dispose."""
        wm_path = os.path.join(REPO_ROOT, "flutter", "plugins", "window_manager", "linux", "window_manager_plugin.cc")
        with open(wm_path, "r", encoding="utf-8") as f:
            content = f.read()

        # find_event_box frees GList
        self.assertIn("g_list_free(children);", content)

        # emission hook cleanup
        self.assertIn("g_signal_remove_emission_hook", content)
        self.assertIn("g_clear_object(&self->channel);", content)
        self.assertIn("g_clear_object(&self->registrar);", content)

    def test_res061_desktop_drop_lifecycle_and_channel_binding(self):
        """RES-061: desktop_drop frees lowercaseDesktopEnv, uses static entries without strdup, and binds channel."""
        dd_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_drop", "linux", "desktop_drop_plugin.cc")
        with open(dd_path, "r", encoding="utf-8") as f:
            content = f.read()

        # g_autofree on lowercaseDesktopEnv
        self.assertIn("g_autofree gchar * lowercaseDesktopEnv = g_ascii_strdown(desktopEnv, -1);", content)

        # No strdup in static GtkTargetEntry entries[]
        self.assertNotIn('strdup("application/vnd.portal.filetransfer")', content)
        self.assertNotIn('strdup("STRING")', content)

        # Channel bound to fl_view lifecycle
        self.assertIn('g_object_set_data_full(G_OBJECT(fl_view), "desktop-drop-channel", channel, g_object_unref);', content)

    def test_res061_screen_retriever_registrar_clearing(self):
        """RES-061: screen_retriever clears registrar on dispose."""
        sr_path = os.path.join(REPO_ROOT, "flutter", "plugins", "screen_retriever", "linux", "screen_retriever_plugin.cc")
        with open(sr_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("screen_retriever_plugin_dispose", content)
        self.assertIn("g_clear_object(&self->registrar);", content)

if __name__ == "__main__":
    unittest.main()
