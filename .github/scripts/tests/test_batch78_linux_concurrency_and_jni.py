#!/usr/bin/env python3
"""Contract and static analysis tests for Batch 78 Client Hardening:
- CONC-005: Thread-safe Wayland PipeWire GStreamer initialization
- CONC-008: Eradicate repeated XSetErrorHandler from 33ms window focus hot path
- FFI-001: Android JNI FFI panic shielding, clipboard bounding, and poison-safe mutex recovery
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CLIENT_ROOT = REPO_ROOT
PIPEWIRE_RS = CLIENT_ROOT / "libs" / "scrap" / "src" / "wayland" / "pipewire.rs"
LINUX_RS = CLIENT_ROOT / "src" / "platform" / "linux.rs"
FFI_RS = CLIENT_ROOT / "libs" / "scrap" / "src" / "android" / "ffi.rs"


class TestBatch78LinuxConcurrencyAndJniContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pipewire_content = PIPEWIRE_RS.read_text(encoding="utf-8")
        cls.linux_content = LINUX_RS.read_text(encoding="utf-8")
        cls.ffi_content = FFI_RS.read_text(encoding="utf-8")

    def test_conc005_pipewire_gstreamer_initialization_thread_safety(self):
        """CONC-005: pipewire.rs must use std::sync::OnceLock instead of unsafe static mut INIT."""
        # Must not contain static mut INIT
        self.assertNotIn(
            "static mut INIT",
            self.pipewire_content,
            "CONC-005 violation: static mut INIT found in pipewire.rs",
        )

        # Must declare OnceLock for gstreamer init
        self.assertIn(
            "std::sync::OnceLock",
            self.pipewire_content,
            "CONC-005 violation: OnceLock not used in pipewire.rs",
        )

        # Must declare public helper function ensure_gstreamer_initialized
        self.assertIn(
            "pub fn ensure_gstreamer_initialized() -> ResultType<()>",
            self.pipewire_content,
            "CONC-005 violation: ensure_gstreamer_initialized not declared in pipewire.rs",
        )

        # request_remote_desktop must call ensure_gstreamer_initialized
        self.assertIn(
            "ensure_gstreamer_initialized()?",
            self.pipewire_content,
            "CONC-005 violation: request_remote_desktop must invoke ensure_gstreamer_initialized()",
        )

    def test_conc008_x_error_handler_hot_path_safety(self):
        """CONC-008: linux.rs must install unified X handler once and not swap XSetErrorHandler per 33ms focus query."""
        # Must declare UNIFIED_X_HANDLER_INIT with std::sync::Once
        self.assertIn(
            "UNIFIED_X_HANDLER_INIT: std::sync::Once",
            self.linux_content,
            "CONC-008 violation: UNIFIED_X_HANDLER_INIT Once not declared in linux.rs",
        )

        # Must store previous handler in atomic ptr
        self.assertIn(
            "PREVIOUS_X_ERROR_HANDLER",
            self.linux_content,
            "CONC-008 violation: PREVIOUS_X_ERROR_HANDLER atomic ptr not declared in linux.rs",
        )

        # Must define ensure_unified_x_error_handler_installed
        self.assertIn(
            "fn ensure_unified_x_error_handler_installed()",
            self.linux_content,
            "CONC-008 violation: ensure_unified_x_error_handler_installed not found in linux.rs",
        )

        # get_focused_display must call ensure_unified_x_error_handler_installed
        self.assertIn(
            "ensure_unified_x_error_handler_installed()",
            self.linux_content,
            "CONC-008 violation: get_focused_display must call ensure_unified_x_error_handler_installed",
        )

        # Focus loop query must track active display and in-flight flag
        self.assertIn("ACTIVE_GEOMETRY_DISPLAY", self.linux_content)
        self.assertIn("ACTIVE_GEOMETRY_IN_FLIGHT", self.linux_content)
        self.assertIn("ACTIVE_GEOMETRY_BAD_WINDOW", self.linux_content)

        # Unified handler must forward non-query errors to previous handler
        self.assertIn(
            "PREVIOUS_X_ERROR_HANDLER.load(Ordering::SeqCst)",
            self.linux_content,
        )

    def test_ffi001_android_jni_panic_shielding(self):
        """FFI-001: All extern system JNI functions must wrap execution in std::panic::catch_unwind."""
        jni_pattern = re.compile(r'pub\s+extern\s+"system"\s+fn\s+(Java_ffi_FFI_\w+)\s*\([^)]*\)\s*(?:->\s*[^\{]+)?\s*\{', re.MULTILINE)
        matches = jni_pattern.findall(self.ffi_content)
        self.assertGreaterEqual(len(matches), 8, f"Expected at least 8 JNI exports, found: {matches}")

        for fn_name in matches:
            fn_idx = self.ffi_content.find(f"fn {fn_name}")
            next_fn_idx = self.ffi_content.find("\npub extern \"system\" fn ", fn_idx + 1)
            fn_body = self.ffi_content[fn_idx:next_fn_idx] if next_fn_idx != -1 else self.ffi_content[fn_idx:]

            self.assertIn(
                "catch_unwind",
                fn_body,
                f"FFI-001 violation: JNI function {fn_name} must wrap body in catch_unwind to prevent unwinding across FFI boundary",
            )

    def test_ffi001_android_clipboard_bounding_and_poison_recovery(self):
        """FFI-001: process_clipboard_bytes enforces 32MiB bounds, min length, and unwrap_or_else poison recovery."""
        self.assertIn(
            "pub const MAX_CLIPBOARD_PAYLOAD_BYTES: usize = 32 * 1024 * 1024;",
            self.ffi_content,
        )
        self.assertIn(
            "pub fn process_clipboard_bytes(data: &[u8]) -> Result<bool, &'static str>",
            self.ffi_content,
        )
        self.assertIn("empty_buffer", self.ffi_content)
        self.assertIn("buffer_too_large", self.ffi_content)
        self.assertIn("invalid_protobuf", self.ffi_content)

        # Verify poison recovery across mutex / rwlock acquisitions in ffi.rs
        self.assertIn(
            "unwrap_or_else(|p| p.into_inner())",
            self.ffi_content,
            "FFI-001 violation: Mutex / RwLock must use poison-safe unwrap_or_else(|p| p.into_inner())",
        )


if __name__ == "__main__":
    unittest.main()
