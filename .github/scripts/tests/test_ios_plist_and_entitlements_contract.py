#!/usr/bin/env python3
"""Contract and static compliance tests for iOS Platform Hardening (Batch 47).

Validates:
- CRED-011 (P1): Application Support isolation, legacy Documents migration, and homeDir separation.
- COMPAT-004 (P1): Voice call platform contract and fail-closed state on iOS.
- PLATFORM-011 (P1): Local network usage description, multicast entitlement, and LAN error handling.
"""

import os
import plistlib
import re
import unittest
import xml.etree.ElementTree as ET

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
INFO_PLIST_PATH = os.path.join(REPO_ROOT, "flutter/ios/Runner/Info.plist")
RUNNER_ENTITLEMENTS_PATH = os.path.join(REPO_ROOT, "flutter/ios/Runner/Runner.entitlements")
NATIVE_MODEL_PATH = os.path.join(REPO_ROOT, "flutter/lib/models/native_model.dart")
FLUTTER_FFI_PATH = os.path.join(REPO_ROOT, "src/flutter_ffi.rs")
IO_LOOP_PATH = os.path.join(REPO_ROOT, "src/client/io_loop.rs")
LAN_RS_PATH = os.path.join(REPO_ROOT, "src/lan.rs")
REMOTE_PAGE_PATH = os.path.join(REPO_ROOT, "flutter/lib/mobile/pages/remote_page.dart")
VIEW_CAMERA_PAGE_PATH = os.path.join(REPO_ROOT, "flutter/lib/mobile/pages/view_camera_page.dart")


class Batch47IosContractTests(unittest.TestCase):
    def test_platform_011_info_plist_local_network_description(self):
        """PLATFORM-011: Verify NSLocalNetworkUsageDescription in Runner Info.plist."""
        self.assertTrue(os.path.exists(INFO_PLIST_PATH), f"Missing {INFO_PLIST_PATH}")
        with open(INFO_PLIST_PATH, "rb") as f:
            plist_data = plistlib.load(f)

        self.assertIn(
            "NSLocalNetworkUsageDescription",
            plist_data,
            "Info.plist must define NSLocalNetworkUsageDescription",
        )
        desc = plist_data["NSLocalNetworkUsageDescription"]
        self.assertIsInstance(desc, str)
        self.assertTrue(len(desc.strip()) > 10, "Description must be a meaningful explanation")
        self.assertIn("local network", desc.lower())

    def test_platform_011_runner_entitlements_multicast(self):
        """PLATFORM-011: Verify com.apple.developer.networking.multicast entitlement."""
        self.assertTrue(os.path.exists(RUNNER_ENTITLEMENTS_PATH), f"Missing {RUNNER_ENTITLEMENTS_PATH}")
        with open(RUNNER_ENTITLEMENTS_PATH, "rb") as f:
            entitlements = plistlib.load(f)

        self.assertIn(
            "com.apple.developer.networking.multicast",
            entitlements,
            "Runner.entitlements must declare com.apple.developer.networking.multicast",
        )
        self.assertTrue(
            entitlements["com.apple.developer.networking.multicast"] is True,
            "com.apple.developer.networking.multicast must be set to boolean true",
        )

    def test_platform_011_lan_error_resilience(self):
        """PLATFORM-011: Verify UDP bind and send errors are gracefully handled without panicking."""
        self.assertTrue(os.path.exists(LAN_RS_PATH), f"Missing {LAN_RS_PATH}")
        with open(LAN_RS_PATH, "r", encoding="utf-8") as f:
            content = f.read()

        # Check create_broadcast_sockets handles Err
        self.assertIn("Failed to bind broadcast UDP socket", content)
        self.assertIn("Failed to set_broadcast", content)

        # Check send_query handles send_to Err
        self.assertIn("Failed to send LAN discovery query", content)

        # Check discover_impl handles send_query Err
        self.assertIn("LAN discovery query failed", content)

    def test_cred_011_flutter_storage_separation_and_migration(self):
        """CRED-011: Verify NativeModel uses Application Support on iOS and migrates legacy data."""
        self.assertTrue(os.path.exists(NATIVE_MODEL_PATH), f"Missing {NATIVE_MODEL_PATH}")
        with open(NATIVE_MODEL_PATH, "r", encoding="utf-8") as f:
            content = f.read()

        # Must get Application Support on iOS
        self.assertIn("getApplicationSupportDirectory()", content)
        self.assertIn("migrateIosLegacyStorage", content)

        # NativeModel alias contract
        self.assertIn("typedef NativeModel = PlatformFFI;", content)

        # Migration must target legacy configuration files and outbox/cache
        self.assertIn("camellia_remote.toml", content)
        self.assertIn("peers", content)
        self.assertIn("config2.toml", content)
        self.assertIn("audit-evidence-outbox-v1", content)
        self.assertIn("camellia_remote_ab", content)
        self.assertIn("camellia_remote_group", content)

        # Truncation recovery safety
        self.assertIn("targetHasData", content)

        # iOS home dir must resolve via mainGetDataDirIos with docDir
        self.assertIn("mainGetDataDirIos", content)
        self.assertRegex(
            content,
            r"_homeDir\s*=\s*_ffiBind\.mainGetDataDirIos\(\s*appDir:\s*docDir",
            "iOS homeDir must point to Documents/data via mainGetDataDirIos(appDir: docDir)",
        )

    def test_cred_011_rust_flutter_ffi_app_dir_and_data_dir(self):
        """CRED-011: Verify Rust flutter_ffi initializes APP_DIR on iOS and preserves it in get_data_dir."""
        self.assertTrue(os.path.exists(FLUTTER_FFI_PATH), f"Missing {FLUTTER_FFI_PATH}")
        with open(FLUTTER_FFI_PATH, "r", encoding="utf-8") as f:
            content = f.read()

        # initialize() must allow setting APP_DIR on iOS when provided
        init_match = re.search(r"fn initialize\([^)]*\)\s*\{([^}]+(?:\{[^}]*\}[^}]*)*)\}", content)
        self.assertIsNotNone(init_match, "Could not find initialize() in flutter_ffi.rs")
        init_body = init_match.group(1)
        self.assertIn("*config::APP_DIR.write().unwrap() = app_dir.to_owned();", init_body)

        # main_get_data_dir_ios must NOT overwrite config::APP_DIR
        fn_marker = "pub fn main_get_data_dir_ios("
        start_idx = content.find(fn_marker)
        self.assertNotEqual(start_idx, -1, "Could not find main_get_data_dir_ios in flutter_ffi.rs")
        body_start = content.find("{", start_idx)
        self.assertNotEqual(body_start, -1)
        depth = 0
        body_end = body_start
        for i, char in enumerate(content[body_start:], start=body_start):
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    body_end = i
                    break
        data_dir_body = content[body_start + 1:body_end]
        self.assertNotIn(
            "*config::APP_DIR.write().unwrap() = app_dir",
            data_dir_body,
            "main_get_data_dir_ios must NOT overwrite config::APP_DIR",
        )
        self.assertIn(".join(\"data\")", data_dir_body)

    def test_compat_004_io_loop_voice_call_contracts(self):
        """COMPAT-004: Verify voice call fail-closed handling in client/io_loop.rs."""
        self.assertTrue(os.path.exists(IO_LOOP_PATH), f"Missing {IO_LOOP_PATH}")
        with open(IO_LOOP_PATH, "r", encoding="utf-8") as f:
            content = f.read()

        # In Data::NewVoiceCall, iOS must fail closed immediately
        self.assertIn("Voice call request blocked on iOS (not supported)", content)
        self.assertIn("Voice call is not supported on iOS", content)

        # In VoiceCallRequest, iOS must reject incoming call
        self.assertIn("Rejecting incoming voice call on unsupported platform (iOS)", content)
        self.assertTrue(
            re.search(
                r"crate::client::new_voice_call_response\(\s*request\.req_timestamp,\s*false,?\s*\)",
                content,
            ),
            "Expected crate::client::new_voice_call_response(request.req_timestamp, false) in io_loop.rs",
        )

        # In VoiceCallResponse, must check start_voice_call() and fail closed if None
        self.assertIn("Voice call is not supported on this platform", content)
        self.assertIn("Voice call accepted by peer, but local audio capture failed or is unsupported", content)
        self.assertIn("self.voice_call_worker = Some(worker);", content)

    def test_compat_004_flutter_ui_voice_call_visibility_guards(self):
        """COMPAT-004: Verify Flutter UI only presents voice call when platform supports it."""
        for path in [REMOTE_PAGE_PATH, VIEW_CAMERA_PAGE_PATH]:
            self.assertTrue(os.path.exists(path), f"Missing {path}")
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()

            # showChatOptions must guard Voice call option
            self.assertIn("KEY_IS_SUPPORT_VOICE_CALL", content)
            self.assertIn("isAndroid", content)
            self.assertIn("End voice call", content)
            self.assertIn("isInVoice", content)


if __name__ == "__main__":
    unittest.main()
