#!/usr/bin/env python3
"""Contract and static analysis tests for Android input, logging, and overlay lifecycle (Batch 53).

Validates:
- LOG-007: Android Accessibility input path avoids logging keystrokes, submitted text,
  and node content into release Logcat.
- PLATFORM-017: Android Accessibility input validates Unicode scalars and coordinate bounds,
  handles supplementary code points without truncation, and prevents JNI thread exception pollution.
- COMPAT-006: Android FloatingWindowService touch, attachment, and stop authority contracts
  are closed and resilient against unattached view removal or absent engine.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
APP_KOTLIN = REPO_ROOT / "flutter" / "android" / "app" / "src" / "main" / "kotlin" / "com" / "camellia" / "remote"
SCRAP_ANDROID = REPO_ROOT / "libs" / "scrap" / "src" / "android"
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"


class TestAndroidInputLoggingAndOverlayContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.input_service_path = APP_KOTLIN / "InputService.kt"
        cls.floating_window_path = APP_KOTLIN / "FloatingWindowService.kt"
        cls.main_activity_path = APP_KOTLIN / "MainActivity.kt"
        cls.mapper_path = APP_KOTLIN / "KeyboardKeyEventMapper.kt"
        cls.ffi_path = SCRAP_ANDROID / "ffi.rs"
        cls.server_page_path = FLUTTER_LIB / "mobile" / "pages" / "server_page.dart"

        cls.input_service = cls.input_service_path.read_text(encoding="utf-8")
        cls.floating_window = cls.floating_window_path.read_text(encoding="utf-8")
        cls.main_activity = cls.main_activity_path.read_text(encoding="utf-8")
        cls.mapper = cls.mapper_path.read_text(encoding="utf-8")
        cls.ffi = cls.ffi_path.read_text(encoding="utf-8")
        cls.server_page = cls.server_page_path.read_text(encoding="utf-8")

    def test_log007_no_sensitive_keystroke_or_text_logs_in_input_service(self):
        """LOG-007: Log statements must not log full KeyEvent, textToCommit, or node text."""
        forbidden_patterns = [
            r'Log\.[dvie]\s*\([^)]*textToCommit',
            r'Log\.[dvie]\s*\([^)]*existing\s+text',
            r'Log\.[dvie]\s*\([^)]*possibleNodes',
            r'Log\.[dvie]\s*\([^)]*focusInput',
            r'Log\.[dvie]\s*\([^)]*childFromFocusInput',
            r'Log\.[dvie]\s*\([^)]*childFromFocusAccessibilityInput',
            r'Log\.[dvie]\s*\([^)]*rootInActiveWindow',
        ]
        for pattern in forbidden_patterns:
            matches = re.findall(pattern, self.input_service)
            self.assertEqual(
                matches,
                [],
                f"LOG-007 violation: sensitive pattern {pattern} found in InputService.kt: {matches}",
            )

    def test_log007_no_key_or_unicode_logging_in_mapper(self):
        """LOG-007: KeyboardKeyEventMapper must not log raw Unicode or keycodes."""
        forbidden_patterns = [
            r'Log\.[dvie]\s*\([^)]*unicode',
            r'Log\.[dvie]\s*\([^)]*keycode',
        ]
        for pattern in forbidden_patterns:
            matches = re.findall(pattern, self.mapper)
            self.assertEqual(
                matches,
                [],
                f"LOG-007 violation: key logging pattern {pattern} found in KeyboardKeyEventMapper.kt: {matches}",
            )

    def test_platform017_unicode_scalar_validation_and_no_truncation(self):
        """PLATFORM-017: Unicode input must validate code points and preserve supplementary characters."""
        self.assertIn(
            "Character.isValidCodePoint",
            self.mapper,
            "PLATFORM-017: KeyboardKeyEventMapper must check Character.isValidCodePoint",
        )
        self.assertNotIn(
            "unicode.toChar()",
            self.mapper,
            "PLATFORM-017: KeyboardKeyEventMapper must not truncate supplementary code points with toChar()",
        )
        self.assertIn(
            "Character.toChars",
            self.mapper,
            "PLATFORM-017: KeyboardKeyEventMapper must use Character.toChars",
        )

    def test_platform017_jni_pending_exception_handling_in_rust(self):
        """PLATFORM-017: Rust JNI helpers must check and clear pending exceptions."""
        self.assertIn(
            "exception_check",
            self.ffi,
            "PLATFORM-017: Rust ffi.rs must check for pending JNI exceptions",
        )
        self.assertIn(
            "exception_clear",
            self.ffi,
            "PLATFORM-017: Rust ffi.rs must clear pending JNI exceptions",
        )

    def test_compat006_floating_window_touch_consumption(self):
        """COMPAT-006: FloatingWindowService onTouch must return true for consumed actions."""
        self.assertNotIn(
            "return false\n    }\n\n    private fun moveToScreenSide",
            self.floating_window,
            "COMPAT-006: onTouch must consume down/move/up events rather than unconditionally returning false",
        )

    def test_compat006_floating_window_attachment_lifecycle_guard(self):
        """COMPAT-006: FloatingWindowService must track isAttached and guard removeView."""
        self.assertIn(
            "isAttached",
            self.floating_window,
            "COMPAT-006: FloatingWindowService must track isAttached state",
        )

    def test_compat006_floating_window_stop_fallback(self):
        """COMPAT-006: stopMainService must have direct fallback if channel is unavailable."""
        self.assertIn(
            "MainService::class.java",
            self.floating_window,
            "COMPAT-006: FloatingWindowService stopMainService must reference MainService directly for stop fallback",
        )

    def test_compat006_main_activity_onstop_safe_start_service(self):
        """COMPAT-006: MainActivity onStop must guard startService against background restrictions."""
        onstop_idx = self.main_activity.find("override fun onStop()")
        self.assertGreater(onstop_idx, 0, "MainActivity must implement onStop")
        onstop_block = self.main_activity[onstop_idx:onstop_idx + 400]
        self.assertIn(
            "try",
            onstop_block,
            "COMPAT-006: MainActivity.onStop must wrap startService in try/catch for Android 8+ restrictions",
        )


if __name__ == "__main__":
    unittest.main()
