#!/usr/bin/env python3
"""
Contract verification suite for Linux Multi-Window, GObject Safety, and RPC contracts
(UNSAFE-012, UNSAFE-013, STATE-029).
"""

import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

class LinuxMultiWindowAndCursorContractTests(unittest.TestCase):
    def test_unsafe012_flutter_window_emission_hooks_and_cleanup(self):
        """UNSAFE-012: FlutterWindow tracks both press and release emission hooks and cleans them up."""
        header_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "flutter_window.h")
        self.assertTrue(os.path.exists(header_path), f"Missing {header_path}")
        with open(header_path, "r", encoding="utf-8") as f:
            header_content = f.read()

        self.assertIn("gulong pressedEmissionHook", header_content)
        self.assertIn("gulong releasedEmissionHook", header_content)
        self.assertIn("void CleanupHooks();", header_content)

        src_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "flutter_window.cc")
        self.assertTrue(os.path.exists(src_path), f"Missing {src_path}")
        with open(src_path, "r", encoding="utf-8") as f:
            src_content = f.read()

        # Both hooks must be assigned
        self.assertIn("this->pressedEmissionHook = g_signal_add_emission_hook", src_content)
        self.assertIn("this->releasedEmissionHook = g_signal_add_emission_hook", src_content)

        # CleanupHooks must remove both hooks and disconnect handlers
        self.assertIn("void FlutterWindow::CleanupHooks()", src_content)
        self.assertIn("g_signal_remove_emission_hook(sig_id, this->pressedEmissionHook)", src_content)
        self.assertIn("g_signal_remove_emission_hook(sig_id, this->releasedEmissionHook)", src_content)
        self.assertIn("g_signal_handlers_disconnect_matched", src_content)

        # Destructor must call CleanupHooks
        self.assertRegex(src_content, r"FlutterWindow::~FlutterWindow\(\)\s*\{\s*CleanupHooks\(\);")

    def test_unsafe012_on_window_close_uaf_elimination(self):
        """UNSAFE-012: onWindowClose does not dereference self after OnWindowDestroy and returns FALSE."""
        src_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "flutter_window.cc")
        with open(src_path, "r", encoding="utf-8") as f:
            src_content = f.read()

        close_fn_match = re.search(r"gboolean onWindowClose\(GtkWidget \*widget, GdkEvent \*, gpointer arg\)\s*\{(.*?)\n\}", src_content, re.DOTALL)
        self.assertIsNotNone(close_fn_match, "onWindowClose function not found")
        close_body = close_fn_match.group(1)

        # Must copy id and check prevent close before destroy
        self.assertIn("int64_t id = self->id_;", close_body)
        self.assertIn("self->CleanupHooks();", close_body)
        self.assertIn("callback->OnWindowDestroy(id);", close_body)

        # Must not do "return self->isPreventClose" at the end of onWindowClose
        self.assertNotIn("return self->isPreventClose;", close_body)
        self.assertTrue(close_body.strip().endswith("return FALSE;"))

    def test_unsafe012_multi_window_manager_deferred_destroy(self):
        """UNSAFE-012: MultiWindowManager defers window destruction via g_idle_add."""
        mgr_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "multi_window_manager.cc")
        self.assertTrue(os.path.exists(mgr_path), f"Missing {mgr_path}")
        with open(mgr_path, "r", encoding="utf-8") as f:
            mgr_content = f.read()

        destroy_match = re.search(r"void MultiWindowManager::OnWindowDestroy\(int64_t id\)\s*\{(.*?)\n\}", mgr_content, re.DOTALL)
        self.assertIsNotNone(destroy_match, "OnWindowDestroy function not found")
        destroy_body = destroy_match.group(1)

        self.assertIn("g_idle_add", destroy_body)
        self.assertIn("windows_.erase", destroy_body)

    def test_unsafe013_custom_cursor_gobject_struct_and_dispose(self):
        """UNSAFE-013: GObject struct uses raw pointer for cache and cleans up cursors and registrar on dispose."""
        cursor_path = os.path.join(REPO_ROOT, "flutter", "plugins", "flutter_custom_cursor", "linux", "flutter_custom_cursor_plugin.cc")
        self.assertTrue(os.path.exists(cursor_path), f"Missing {cursor_path}")
        with open(cursor_path, "r", encoding="utf-8") as f:
            cursor_content = f.read()

        # Struct must NOT embed std::unique_ptr
        self.assertNotIn("unique_ptr<unordered_map", cursor_content)
        self.assertIn("std::unordered_map<std::string, GdkCursor*>* cache;", cursor_content)

        # Init must use operator new
        self.assertIn("self->cache = new std::unordered_map<std::string, GdkCursor*>();", cursor_content)

        # Dispose must unref cursors, delete cache, and unref registrar
        dispose_match = re.search(r"static void flutter_custom_cursor_plugin_dispose\(GObject \*object\)\s*\{(.*?)\n\}", cursor_content, re.DOTALL)
        self.assertIsNotNone(dispose_match, "flutter_custom_cursor_plugin_dispose not found")
        dispose_body = dispose_match.group(1)

        self.assertIn("g_object_unref(pair.second)", dispose_body)
        self.assertIn("delete self->cache;", dispose_body)
        self.assertIn("g_object_unref(self->registrar)", dispose_body)

    def test_unsafe013_custom_cursor_error_paths_and_no_null_string(self):
        """UNSAFE-013: create_custom_cursor returns FlMethodResponse* (no return nullptr into std::string) and validates pixbuf."""
        cursor_path = os.path.join(REPO_ROOT, "flutter", "plugins", "flutter_custom_cursor", "linux", "flutter_custom_cursor_plugin.cc")
        with open(cursor_path, "r", encoding="utf-8") as f:
            cursor_content = f.read()

        # create_custom_cursor must return FlMethodResponse*, not std::string
        self.assertIn("static FlMethodResponse* create_custom_cursor(", cursor_content)
        self.assertNotIn("std::string create_custom_cursor(", cursor_content)

        # Must validate loader write and close errors
        self.assertIn("gdk_pixbuf_loader_write", cursor_content)
        self.assertIn("gdk_pixbuf_loader_close", cursor_content)
        self.assertIn("gdk_pixbuf_loader_get_pixbuf", cursor_content)

        # Must validate hotspot bounds
        self.assertIn("hot_x >= width", cursor_content)
        self.assertIn("hot_y >= height", cursor_content)

        # Must unref previous cursor on overwrite
        self.assertIn("g_object_unref(it->second)", cursor_content)

    def test_state029_window_channel_rpc_error_handling(self):
        """STATE-029: WindowChannel responds with error response on failure and unrefs result."""
        channel_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "linux", "window_channel.cc")
        self.assertTrue(os.path.exists(channel_path), f"Missing {channel_path}")
        with open(channel_path, "r", encoding="utf-8") as f:
            channel_content = f.read()

        self.assertIn("fl_method_error_response_new", channel_content)
        self.assertIn("g_error_free(error)", channel_content)
        self.assertIn("g_object_unref(result)", channel_content)

    def test_state029_dart_invoke_method_timeout_and_fallback(self):
        """STATE-029: Dart DesktopMultiWindow.invokeMethod enforces timeout and handles coords error gracefully."""
        dart_path = os.path.join(REPO_ROOT, "flutter", "plugins", "desktop_multi_window", "lib", "desktop_multi_window.dart")
        self.assertTrue(os.path.exists(dart_path), f"Missing {dart_path}")
        with open(dart_path, "r", encoding="utf-8") as f:
            dart_content = f.read()

        self.assertIn(".timeout(timeout)", dart_content)
        self.assertIn("on TimeoutException", dart_content)

        mgr_dart_path = os.path.join(REPO_ROOT, "flutter", "lib", "utils", "multi_window_manager.dart")
        with open(mgr_dart_path, "r", encoding="utf-8") as f:
            mgr_dart_content = f.read()

        # getOtherRemoteWindowCoordsFromMain must be wrapped in try/catch
        coords_match = re.search(r"Future<List<RemoteWindowCoords>> getOtherRemoteWindowCoordsFromMain\(\) async \{(.*?)\n  \}", mgr_dart_content, re.DOTALL)
        self.assertIsNotNone(coords_match, "getOtherRemoteWindowCoordsFromMain not found")
        coords_body = coords_match.group(1)
        self.assertIn("try {", coords_body)
        self.assertIn("catch (e) {", coords_body)

if __name__ == "__main__":
    unittest.main()
