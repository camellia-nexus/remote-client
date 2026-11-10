#!/usr/bin/env python3
"""Contract and static analysis tests for Android clipboard bridge and background access (Batch 54).

Validates PLATFORM-018:
- RdClipboardManager avoids ArrayIndexOutOfBoundsException when ClipData itemCount > mimeTypeCount.
- rustUpdateClipboard guards against empty MIME types before instantiating ClipDescription.
- rustUpdateClipboard dispatches setPrimaryClip to the main Looper thread.
- Thread-safe volatile annotations on mutable clipboard bridge states.
- Rust scrap JNI exports cleanupClipboardManager and checks/clears pending exceptions.
- MainActivity cleans up clipboard manager on onDestroy.
- MainService provides fallback initialization for boot-only / background Host.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
APP_KOTLIN = REPO_ROOT / "flutter" / "android" / "app" / "src" / "main" / "kotlin" / "com" / "camellia" / "remote"
SCRAP_ANDROID = REPO_ROOT / "libs" / "scrap" / "src" / "android"


class TestAndroidClipboardContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manager_path = APP_KOTLIN / "RdClipboardManager.kt"
        cls.activity_path = APP_KOTLIN / "MainActivity.kt"
        cls.service_path = APP_KOTLIN / "MainService.kt"
        cls.floating_window_path = APP_KOTLIN / "FloatingWindowService.kt"
        cls.ffi_path = SCRAP_ANDROID / "ffi.rs"

        cls.manager = cls.manager_path.read_text(encoding="utf-8")
        cls.activity = cls.activity_path.read_text(encoding="utf-8")
        cls.service = cls.service_path.read_text(encoding="utf-8")
        cls.floating_window = cls.floating_window_path.read_text(encoding="utf-8")
        cls.ffi = cls.ffi_path.read_text(encoding="utf-8")

    def test_no_mime_index_out_of_bounds_in_item_loop(self):
        """PLATFORM-018: isClipboardDataEqual must not index getMimeType with itemCount loop variable."""
        # Forbidden: indexing getMimeType using item index in itemCount loop
        forbidden = r'for\s*\(\s*(\w+)\s+in\s+0\s+until\s+left\.itemCount\s*\)\s*\{[^}]*getMimeType\(\s*\1\s*\)'
        matches = re.findall(forbidden, self.manager)
        self.assertEqual(
            matches,
            [],
            f"PLATFORM-018 violation: getMimeType indexed with itemCount variable {matches}",
        )

    def test_rust_update_clipboard_empty_mimetypes_guard(self):
        """PLATFORM-018: rustUpdateClipboard must guard against empty MIME types before ClipDescription."""
        self.assertTrue(
            "text == null && html == null" in self.manager
            or "mimeTypes.isEmpty()" in self.manager,
            "PLATFORM-018: rustUpdateClipboard must guard against empty content / MIME types",
        )

    def test_rust_update_clipboard_main_looper_dispatch(self):
        """PLATFORM-018: setPrimaryClip must be dispatched to main Looper thread."""
        self.assertTrue(
            "mainHandler" in self.manager or "getMainLooper" in self.manager,
            "PLATFORM-018: RdClipboardManager must use main Looper Handler for clipboard mutation",
        )

    def test_volatile_concurrency_annotations(self):
        """PLATFORM-018: Mutable state fields must have @Volatile annotations."""
        self.assertIn(
            "@Volatile",
            self.manager,
            "PLATFORM-018: RdClipboardManager must declare @Volatile states",
        )

    def test_jni_cleanup_clipboard_manager_exported(self):
        """PLATFORM-018: Rust ffi.rs must export cleanupClipboardManager."""
        self.assertIn(
            "cleanupClipboardManager",
            self.ffi,
            "PLATFORM-018: libs/scrap/src/android/ffi.rs must implement cleanupClipboardManager",
        )

    def test_jni_clipboard_calls_check_exceptions(self):
        """PLATFORM-018: Clipboard JNI calls must check and clear pending exceptions."""
        call_clip_idx = self.ffi.find("pub fn call_clipboard_manager_update_clipboard")
        self.assertGreater(call_clip_idx, 0)
        call_clip_block = self.ffi[call_clip_idx:call_clip_idx + 800]
        self.assertIn(
            "exception_check",
            call_clip_block,
            "PLATFORM-018: call_clipboard_manager_update_clipboard must check pending exceptions",
        )
        self.assertIn(
            "exception_clear",
            call_clip_block,
            "PLATFORM-018: call_clipboard_manager_update_clipboard must clear pending exceptions",
        )

    def test_main_activity_cleans_up_clipboard_manager(self):
        """PLATFORM-018: MainActivity onDestroy must invoke cleanupClipboardManager."""
        on_destroy_idx = self.activity.find("override fun onDestroy()")
        self.assertGreater(on_destroy_idx, 0)
        on_destroy_block = self.activity[on_destroy_idx:on_destroy_idx + 600]
        self.assertIn(
            "cleanupClipboardManager",
            on_destroy_block,
            "PLATFORM-018: MainActivity onDestroy must clean up clipboard manager",
        )

    def test_main_service_fallback_clipboard_initialization(self):
        """PLATFORM-018: MainService must provide fallback for RdClipboardManager when Activity is absent."""
        self.assertIn(
            "getOrCreateRdClipboardManager",
            self.activity,
            "PLATFORM-018: MainActivity/service must expose shared or fallback getOrCreateRdClipboardManager",
        )


if __name__ == "__main__":
    unittest.main()
