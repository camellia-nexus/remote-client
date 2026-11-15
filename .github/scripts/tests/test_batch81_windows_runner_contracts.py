#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 81:
Windows Native Runner Robustness & Win32 IPC Lifecycle
(PLATFORM-008, PLATFORM-009, CRASH-002, IPC-001).
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_DIR = REPO_ROOT / "flutter" / "windows" / "runner"
PLUGINS_DIR = REPO_ROOT / "flutter" / "plugins" / "uni_links_desktop" / "windows"
PLATFORM_CHANNEL_DART = REPO_ROOT / "flutter" / "lib" / "utils" / "platform_channel.dart"

class TestBatch81WindowsRunnerContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.flutter_window_cpp = (RUNNER_DIR / "flutter_window.cpp").read_text(encoding="utf-8")
        cls.win32_window_cpp = (RUNNER_DIR / "win32_window.cpp").read_text(encoding="utf-8")
        cls.win32_window_h = (RUNNER_DIR / "win32_window.h").read_text(encoding="utf-8")
        cls.win32_desktop_cpp = (RUNNER_DIR / "win32_desktop.cpp").read_text(encoding="utf-8")
        cls.main_cpp = (RUNNER_DIR / "main.cpp").read_text(encoding="utf-8")
        cls.uni_links_cpp = (PLUGINS_DIR / "uni_links_desktop_plugin.cpp").read_text(encoding="utf-8")
        cls.uni_links_h = (PLUGINS_DIR / "include" / "uni_links_desktop" / "uni_links_desktop_plugin.h").read_text(encoding="utf-8")
        cls.dart_source = PLATFORM_CHANNEL_DART.read_text(encoding="utf-8")

    # =========================================================================
    # 1. PLATFORM-008: MethodChannel Arguments & Completion Invariants
    # =========================================================================
    def test_platform008_arguments_null_guard(self):
        """Arguments must be null-checked before dereference."""
        self.assertIn("arguments == nullptr", self.flutter_window_cpp)
        self.assertIn('result->Error("invalid_arguments"', self.flutter_window_cpp)

    def test_platform008_integer_width_support(self):
        """Arguments extraction must support both int32_t and int64_t."""
        self.assertIn("std::holds_alternative<int32_t>", self.flutter_window_cpp)
        self.assertIn("std::holds_alternative<int64_t>", self.flutter_window_cpp)

    def test_platform008_coordinate_bounds_and_unknown_method(self):
        """Delta coordinates must be bounded and unknown methods must reply NotImplemented."""
        self.assertIn("kMaxCoordDelta", self.flutter_window_cpp)
        self.assertIn('result->Error("out_of_bounds"', self.flutter_window_cpp)
        self.assertIn("result->NotImplemented()", self.flutter_window_cpp)

    def test_platform008_bump_mouse_set_cursor_check(self):
        """Win32Desktop::BumpMouse must check SetCursorPos return value."""
        self.assertIn("::GetCursorPos", self.win32_desktop_cpp)
        self.assertIn("::SetCursorPos", self.win32_desktop_cpp)
        self.assertRegex(self.win32_desktop_cpp, r"if\s*\(!::SetCursorPos\(")

    def test_platform008_dart_timeout_fallback(self):
        """Dart bumpMouse must enforce a timeout and catch platform errors."""
        self.assertIn(".timeout(", self.dart_source)
        self.assertIn("catch (e)", self.dart_source)

    # =========================================================================
    # 2. PLATFORM-009: Startup Transaction & Message Loop Invariants
    # =========================================================================
    def test_platform009_scoped_com_initializer(self):
        """main.cpp must define ScopedComInitializer with S_OK/S_FALSE uninitialization."""
        self.assertIn("class ScopedComInitializer", self.main_cpp)
        self.assertIn("CoInitializeEx", self.main_cpp)
        self.assertIn("CoUninitialize", self.main_cpp)
        self.assertIn("RPC_E_CHANGED_MODE", self.main_cpp)

    def test_platform009_window_class_registration_check(self):
        """RegisterClass failure must be checked and not committed."""
        self.assertIn("ERROR_CLASS_ALREADY_EXISTS", self.win32_window_cpp)

    def test_platform009_taskbar_rollback(self):
        """ITaskbarList failure must clean up window and fail closed."""
        self.assertIn("pTaskbarList->HrInit()", self.win32_window_cpp)
        self.assertIn("pTaskbarList->DeleteTab(", self.win32_window_cpp)
        self.assertIn("Destroy();", self.win32_window_cpp)

    def test_platform009_set_child_content_fallibility(self):
        """SetChildContent must return bool and be verified in OnCreate."""
        self.assertIn("bool SetChildContent(HWND content);", self.win32_window_h)
        self.assertIn("return SetChildContent(", self.flutter_window_cpp)

    def test_platform009_message_loop_negative_one_guard(self):
        """Message loop must handle bRet == -1 failure distinctly."""
        self.assertIn("bRet == -1", self.main_cpp)
        self.assertIn("EXIT_FAILURE", self.main_cpp)

    # =========================================================================
    # 3. CRASH-002: Font-Change & Teardown Safety Invariants
    # =========================================================================
    def test_crash002_wm_fontchange_guard(self):
        """WM_FONTCHANGE must guard flutter_controller_ and engine() before reload."""
        self.assertRegex(
            self.flutter_window_cpp,
            r"case\s+WM_FONTCHANGE:\s+if\s*\(flutter_controller_\s*&&\s*flutter_controller_->engine\(\)\)",
        )

    def test_crash002_destroy_disconnects_user_data(self):
        """Win32Window::Destroy must disconnect GWLP_USERDATA before DestroyWindow."""
        self.assertRegex(
            self.win32_window_cpp,
            r"SetWindowLongPtr\(hwnd,\s*GWLP_USERDATA,\s*0\);[\s\S]*?DestroyWindow\(hwnd\);",
        )

    # =========================================================================
    # 4. IPC-001: Bounded, Authenticated, Non-blocking WM_COPYDATA Invariants
    # =========================================================================
    def test_ipc001_copydata_length_and_utf8_validation(self):
        """WM_COPYDATA handler must validate cds, cbData, and UTF-8 encoding."""
        self.assertIn("UNI_LINKS_MAX_URL_LENGTH", self.uni_links_cpp)
        self.assertIn("MB_ERR_INVALID_CHARS", self.uni_links_cpp)
        self.assertIn("UNI_LINKS_DESKTOP_ACK", self.uni_links_cpp)

    def test_ipc001_sender_timeout_and_process_validation(self):
        """Sender must verify target process identity and use SendMessageTimeoutW."""
        self.assertIn("SendMessageTimeoutW", self.uni_links_cpp)
        self.assertIn("SMTO_ABORTIFHUNG", self.uni_links_cpp)
        self.assertIn("IsTrustedTargetWindow", self.main_cpp)
        self.assertIn("QueryFullProcessImageNameW", self.main_cpp)

    def test_ipc001_single_instance_exit_success(self):
        """Successful single-instance handoff must return EXIT_SUCCESS."""
        self.assertRegex(
            self.main_cpp,
            r"return\s+dispatched\s*\?\s*EXIT_SUCCESS\s*:\s*EXIT_FAILURE;",
        )

if __name__ == "__main__":
    unittest.main()
