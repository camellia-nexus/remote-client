#!/usr/bin/env python3
"""Contract tests for Batch 85: macOS CoreGraphics & Host Channel Safety (PLATFORM-006, PLATFORM-010)."""

import re
import unittest
from pathlib import Path

CLIENT_DIR = Path(__file__).resolve().parents[3]


class TestBatch85MacOSPlatformSafety(unittest.TestCase):
    """Verify macOS platform NULL checks, bounds, and MethodChannel resilience contracts."""

    def test_platform006_macos_rs_cursor_pos_null_safety(self) -> None:
        """PLATFORM-006: Verify get_cursor_pos in macos.rs checks for NULL event."""
        macos_rs = (CLIENT_DIR / "src" / "platform" / "macos.rs").read_text(
            encoding="utf-8"
        )
        # Ensure CGEventCreate is followed by is_null check returning None
        pattern = r"let\s+e\s*=\s*CGEventCreate\(.*?\);\s*if\s+e\.is_null\(\)\s*\{\s*return\s+None;\s*\}"
        self.assertRegex(
            macos_rs,
            pattern,
            "macos.rs get_cursor_pos must check e.is_null() and return None",
        )

    def test_platform006_macos_mm_bit_depth_null_safety(self) -> None:
        """PLATFORM-006: Verify bitDepth in macos.mm checks mode and pixelEncoding for NULL."""
        macos_mm = (CLIENT_DIR / "src" / "platform" / "macos.mm").read_text(
            encoding="utf-8"
        )
        # Ensure bitDepth checks mode == NULL and pixelEncoding == NULL
        self.assertIn("if (mode == NULL)", macos_mm)
        self.assertIn("if (pixelEncoding == NULL)", macos_mm)
        # Ensure getAllModes checks options == NULL
        self.assertIn("if (options == NULL)", macos_mm)

    def test_platform006_macos_mm_event_tap_setup_and_teardown_safety(self) -> None:
        """PLATFORM-006: Verify SetupEventTapOnMainThread and Teardown handle NULL run loop source."""
        macos_mm = (CLIENT_DIR / "src" / "platform" / "macos.mm").read_text(
            encoding="utf-8"
        )
        # Setup must check !g_eventTap and !g_runLoopSource with rollback
        self.assertIn("if (!g_runLoopSource)", macos_mm)
        self.assertIn("CFRelease(g_eventTap);", macos_mm)
        # Teardown must null-check g_runLoopSource before CFRelease
        self.assertIn("if (g_runLoopSource)", macos_mm)

    def test_platform006_enigo_scroll_null_safety(self) -> None:
        """PLATFORM-006: Verify enigo macos_impl.rs checks !mouse_ev.is_null() before post and release."""
        enigo_rs = (
            CLIENT_DIR / "libs" / "enigo" / "src" / "macos" / "macos_impl.rs"
        ).read_text(encoding="utf-8")
        # Find all occurrences of CGEventCreateScrollWheelEvent
        matches = list(re.finditer(r"CGEventCreateScrollWheelEvent", enigo_rs))
        self.assertEqual(
            len(matches),
            5,
            "Should find 5 CGEventCreateScrollWheelEvent references (extern fn + 4 calls across 3 methods)",
        )
        # In all 3 scroll call locations, mouse_ev must be checked for !mouse_ev.is_null()
        null_checks = list(re.finditer(r"if\s+!mouse_ev\.is_null\(\)\s*\{", enigo_rs))
        self.assertEqual(
            len(null_checks),
            3,
            "All 3 scroll implementations must check !mouse_ev.is_null()",
        )

    def test_platform010_swift_theme_no_force_cast(self) -> None:
        """PLATFORM-010: Verify setWindowTheme does not use force cast as! [String: Any]."""
        swift_file = (
            CLIENT_DIR / "flutter" / "macos" / "Runner" / "MainFlutterWindow.swift"
        ).read_text(encoding="utf-8")
        # No force unwrap for setWindowTheme arguments
        self.assertNotIn("call.arguments as! [String: Any]", swift_file)
        self.assertIn("guard let arg = call.arguments as? [String: Any]", swift_file)

    def test_platform010_swift_bump_mouse_validation_and_cg_errors(self) -> None:
        """PLATFORM-010: Verify bumpMouse validates parameters, bounds, and checks CG error codes."""
        swift_file = (
            CLIENT_DIR / "flutter" / "macos" / "Runner" / "MainFlutterWindow.swift"
        ).read_text(encoding="utf-8")
        # Bounds check
        self.assertIn("abs(dx) <= 10000 && abs(dy) <= 10000", swift_file)
        # CGDisplayMoveCursorToPoint error checking
        self.assertIn("if errMove != .success", swift_file)
        self.assertIn("CG_MOVE_FAILED", swift_file)
        # CGAssociateMouseAndMouseCursorPosition error checking
        self.assertIn("if errAssoc != .success", swift_file)
        self.assertIn("CG_ASSOCIATE_FAILED", swift_file)


if __name__ == "__main__":
    unittest.main()
