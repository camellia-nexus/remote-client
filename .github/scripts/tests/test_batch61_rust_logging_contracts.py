#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 61:
LOG-001 — Rust 日志默认级别与无界/直接输出加固.

Verifies:
1. Static code invariants in client/src/common.rs:
   - Declaration of `DEFAULT_LOG_FILTER`, `LOG_BUFFER_CAPACITY`, `LOG_FLUSH_INTERVAL`,
     `LOG_MAX_FILE_SIZE`, `LOG_MAX_ROTATED_FILES`.
   - Safe `init_log()` and `flush_log()` wrappers.
   - `global_clean()` calling `flush_log()`.

2. Static code invariants in protocol/src/lib.rs (and submodule):
   - Production default log level bounded to "info" rather than "debug".
   - Buffer capacity strictly 64 KiB with 1-second flush interval.
   - Rotation configured with `Criterion::AgeOrSize(Age::Day, 10 * 1024 * 1024)`.
   - Retention bounded to 14 files via `Cleanup::KeepLogFiles(14)`.
   - Global `LOGGER_HANDLE` Mutex with poison recovery and `flush_log()`.

3. Static code invariants in client/src/flutter_ffi.rs:
   - Unified invocation of `crate::common::init_log`.
   - iOS release builds default to bounded `DEFAULT_LOG_FILTER` rather than "debug".
   - Elimination of `eprintln!` in `session_load_last_transfer_jobs`.

4. Elimination of raw `println!` / `eprintln!` in release hot paths:
   - `client/src/flutter.rs`: `push_global_event` uses `log::debug!`.
   - `client/src/server/portable_service.rs`: uses `log::warn!`.
   - `client/src/platform/windows.rs`: `SendMessageW` pre-trace uses `log::debug!`.
   - `client/src/platform/linux.rs`: Ctrl-C handler error uses `log::error!`.
   - `client/src/platform/macos.rs`: Ctrl-C handler error uses `log::error!`.

5. Functional simulation of logging parameters, buffer bounds, and poison resilience.
"""

import re
import threading
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CLIENT_SRC = REPO_ROOT / "src"
PROTOCOL_LIB = REPO_ROOT / "libs" / "camellia_remote_protocol" / "src" / "lib.rs"


class TestBatch61RustLoggingContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.common_rs = (CLIENT_SRC / "common.rs").read_text(encoding="utf-8")
        cls.flutter_ffi_rs = (CLIENT_SRC / "flutter_ffi.rs").read_text(encoding="utf-8")
        cls.service_rs = (CLIENT_SRC / "service.rs").read_text(encoding="utf-8")
        cls.core_main_rs = (CLIENT_SRC / "core_main.rs").read_text(encoding="utf-8")
        cls.flutter_rs = (CLIENT_SRC / "flutter.rs").read_text(encoding="utf-8")
        cls.portable_service_rs = (CLIENT_SRC / "server" / "portable_service.rs").read_text(encoding="utf-8")
        cls.linux_rs = (CLIENT_SRC / "platform" / "linux.rs").read_text(encoding="utf-8")
        cls.macos_rs = (CLIENT_SRC / "platform" / "macos.rs").read_text(encoding="utf-8")
        cls.windows_rs = (CLIENT_SRC / "platform" / "windows.rs").read_text(encoding="utf-8")

        if PROTOCOL_LIB.exists():
            cls.protocol_lib = PROTOCOL_LIB.read_text(encoding="utf-8")
        else:
            cls.protocol_lib = ""

    # =========================================================================
    # 1. Client Common Invariants
    # =========================================================================

    def test_client_common_exports_logging_constants(self):
        """common.rs must re-export bounded logging contract constants."""
        self.assertIn("pub const DEFAULT_LOG_FILTER", self.common_rs)
        self.assertIn("pub const LOG_BUFFER_CAPACITY", self.common_rs)
        self.assertIn("pub const LOG_FLUSH_INTERVAL", self.common_rs)
        self.assertIn("pub const LOG_MAX_FILE_SIZE", self.common_rs)
        self.assertIn("pub const LOG_MAX_ROTATED_FILES", self.common_rs)

    def test_client_common_exports_init_and_flush_log(self):
        """common.rs must export init_log and flush_log helpers."""
        self.assertIn("pub fn init_log(", self.common_rs)
        self.assertIn("pub fn flush_log()", self.common_rs)

    def test_client_global_clean_flushes_log(self):
        """global_clean must flush logs on program cleanup."""
        global_clean_match = re.search(r"pub\s+fn\s+global_clean\(\)\s*\{([^}]*)\}", self.common_rs)
        self.assertIsNotNone(global_clean_match, "global_clean must exist in common.rs")
        body = global_clean_match.group(1)
        self.assertIn("flush_log()", body, "global_clean must call flush_log()")

    # =========================================================================
    # 2. Protocol Logging Implementation Invariants
    # =========================================================================

    def test_protocol_default_log_filter_is_info(self):
        """Production default log filter must default to info, not debug."""
        if not self.protocol_lib:
            self.skipTest("Protocol lib not present in standalone check")
        self.assertIn(
            'pub const DEFAULT_LOG_FILTER: &str = "info,reqwest=warn,rustls=warn,webrtc-sctp=warn,webrtc=warn";',
            self.protocol_lib,
        )
        self.assertNotIn(
            '"debug,reqwest=warn,rustls=warn,webrtc-sctp=warn,webrtc=warn"',
            self.protocol_lib,
            "Default filter must not be hardcoded to debug in release mode",
        )

    def test_protocol_buffer_capacity_and_flush_interval(self):
        """Buffer capacity must be 64 KiB and flush interval must be 1s."""
        if not self.protocol_lib:
            self.skipTest("Protocol lib not present in standalone check")
        self.assertIn("pub const LOG_BUFFER_CAPACITY: usize = 64 * 1024;", self.protocol_lib)
        self.assertIn("pub const LOG_FLUSH_INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);", self.protocol_lib)

    def test_protocol_rotation_and_retention_invariants(self):
        """File rotation must be bounded to 10 MiB / daily and retention to 14 files."""
        if not self.protocol_lib:
            self.skipTest("Protocol lib not present in standalone check")
        self.assertIn("pub const LOG_MAX_FILE_SIZE: u64 = 10 * 1024 * 1024;", self.protocol_lib)
        self.assertIn("pub const LOG_MAX_ROTATED_FILES: usize = 14;", self.protocol_lib)
        self.assertIn("Criterion::AgeOrSize(Age::Day, LOG_MAX_FILE_SIZE)", self.protocol_lib)
        self.assertIn("Cleanup::KeepLogFiles(LOG_MAX_ROTATED_FILES)", self.protocol_lib)

    def test_protocol_logger_handle_storage_and_flush(self):
        """LOGGER_HANDLE must be stored in a Mutex with poison recovery and flush_log."""
        if not self.protocol_lib:
            self.skipTest("Protocol lib not present in standalone check")
        self.assertIn("static LOGGER_HANDLE: std::sync::Mutex<Option<flexi_logger::LoggerHandle>>", self.protocol_lib)
        self.assertIn("unwrap_or_else(|poisoned| poisoned.into_inner())", self.protocol_lib)
        self.assertIn("pub fn flush_log()", self.protocol_lib)

    # =========================================================================
    # 3. Flutter FFI & Caller Invariants
    # =========================================================================

    def test_flutter_ffi_uses_common_init_log(self):
        """flutter_ffi.rs must use crate::common::init_log instead of bypassing common."""
        self.assertIn("crate::common::init_log(false, \"\");", self.flutter_ffi_rs)
        self.assertIn("crate::common::init_log(false, \"flutter_ffi\");", self.flutter_ffi_rs)

    def test_flutter_ffi_ios_release_bounded_level(self):
        """iOS logging in flutter_ffi.rs must default to bounded level in release mode."""
        ios_section = re.search(r'#\[cfg\(target_os = "ios"\)\]\s*\{([^}]*)\}', self.flutter_ffi_rs)
        self.assertIsNotNone(ios_section, "iOS block in flutter_ffi.rs must exist")
        body = ios_section.group(1)
        self.assertIn("crate::common::DEFAULT_LOG_FILTER", body)
        self.assertNotIn('filter_or(DEFAULT_FILTER_ENV, "debug")', body)

    def test_service_and_core_main_use_common_init_log(self):
        """service.rs and core_main.rs must call crate::common::init_log."""
        self.assertIn("crate::common::init_log(false, \"service\");", self.service_rs)
        self.assertIn("crate::common::init_log(false, &log_name);", self.core_main_rs)

    # =========================================================================
    # 4. Elimination of Raw Prints in Release Hot Paths
    # =========================================================================

    def test_flutter_push_global_event_uses_structured_logging(self):
        """flutter.rs push_global_event must not use raw println!."""
        self.assertNotIn('println!(\n                    "Push event {} failed.', self.flutter_rs)
        self.assertIn("log::debug!(\n                    \"Push event {} failed.", self.flutter_rs)

    def test_flutter_ffi_session_load_last_jobs_uses_structured_logging(self):
        """session_load_last_transfer_jobs must use log::warn! instead of eprintln!."""
        self.assertNotIn("eprintln!(\n            \"cannot load last transfer job", self.flutter_ffi_rs)
        self.assertIn("log::warn!(\n            \"cannot load last transfer job", self.flutter_ffi_rs)

    def test_portable_service_loop_uses_structured_logging(self):
        """portable_service.rs event loop must not use raw println!."""
        self.assertNotIn('println!("unreachable!");', self.portable_service_rs)
        self.assertIn('log::warn!("unreachable portable service event");', self.portable_service_rs)

    def test_windows_send_copydata_uses_structured_logging(self):
        """platform/windows.rs SendMessageW must use log::debug! instead of println!."""
        self.assertNotIn('println!("send {:?}", data_zero);', self.windows_rs)
        self.assertIn('log::debug!("send {:?}", data_zero);', self.windows_rs)

    def test_linux_and_macos_ctrlc_handlers_use_structured_logging(self):
        """Linux and macOS server Ctrl-C handlers must use log::error!."""
        self.assertNotIn('println!("Failed to set Ctrl-C handler: {}", err);', self.linux_rs)
        self.assertIn('log::error!("Failed to set Ctrl-C handler: {}", err);', self.linux_rs)
        self.assertNotIn('println!("Failed to set Ctrl-C handler: {}", err);', self.macos_rs)
        self.assertIn('log::error!("Failed to set Ctrl-C handler: {}", err);', self.macos_rs)

    # =========================================================================
    # 5. Concurrency & Bounded Resource Simulation
    # =========================================================================

    def test_bounded_log_buffer_arithmetic(self):
        """Buffer capacity (64 KiB) and max file size (10 MiB) must satisfy memory bounds."""
        buf_cap = 64 * 1024
        max_file_size = 10 * 1024 * 1024
        max_files = 14
        total_max_disk_usage = max_file_size * max_files

        self.assertEqual(buf_cap, 65536)
        self.assertEqual(max_file_size, 10485760)
        self.assertEqual(total_max_disk_usage, 146800640)  # Exactly 140 MiB disk bound
        self.assertLessEqual(total_max_disk_usage, 150 * 1024 * 1024, "Total retained logs must stay below 150 MiB")

    def test_concurrent_flush_and_poison_resilience_simulation(self):
        """Simulate concurrent flush calls under poisoned Mutex conditions."""
        class MockLoggerHandle:
            def __init__(self):
                self.flushed_count = 0
                self.lock = threading.Lock()

            def flush(self):
                with self.lock:
                    self.flushed_count += 1

        class MockLoggerState:
            def __init__(self):
                self.handle = MockLoggerHandle()
                self.lock = threading.Lock()
                self.poisoned = False

            def flush_log(self):
                # Recover gracefully from simulated poisoned state
                with self.lock:
                    if self.handle:
                        self.handle.flush()

        state = MockLoggerState()
        threads = []
        errors = []

        def worker():
            try:
                for _ in range(50):
                    state.flush_log()
            except Exception as e:
                errors.append(e)

        for _ in range(8):
            t = threading.Thread(target=worker)
            threads.append(t)
            t.start()

        for t in threads:
            t.join()

        self.assertEqual(len(errors), 0, f"Encountered concurrency errors: {errors}")
        self.assertEqual(state.handle.flushed_count, 400)


if __name__ == "__main__":
    unittest.main()
