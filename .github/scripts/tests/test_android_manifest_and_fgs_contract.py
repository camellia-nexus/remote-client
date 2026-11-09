#!/usr/bin/env python3
"""Contract and regression tests for Android Host Service, JNI Memory Safety & MediaProjection (Batch 46).

Validates:
- AUTH-009: Complete removal of DEBUG_BOOT_COMPLETED broadcast action from manifests and code.
- RES-040: Android Host Supervisor lifecycle, JNI stopServer, HandlerThread and thread pool cleanup.
- COMPAT-005: Android 14+ FGS permissions (MEDIA_PROJECTION, MICROPHONE), FGS types, MediaProjection.Callback registration, fail-closed capture.
- UNSAFE-003: JNI DirectByteBuffer copy-before-return bounds and cleanup in scrap/ffi.rs and FrameRaw.
"""

import os
import re
import unittest
import xml.etree.ElementTree as ET

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
MANIFEST_PATH = os.path.join(REPO_ROOT, "flutter/android/app/src/main/AndroidManifest.xml")
MAIN_SERVICE_PATH = os.path.join(REPO_ROOT, "flutter/android/app/src/main/kotlin/com/camellia/remote/MainService.kt")
BOOT_RECEIVER_PATH = os.path.join(REPO_ROOT, "flutter/android/app/src/main/kotlin/com/camellia/remote/BootReceiver.kt")
MAIN_ACTIVITY_PATH = os.path.join(REPO_ROOT, "flutter/android/app/src/main/kotlin/com/camellia/remote/MainActivity.kt")
FFI_KT_PATH = os.path.join(REPO_ROOT, "flutter/android/app/src/main/kotlin/ffi.kt")
FLUTTER_FFI_RS_PATH = os.path.join(REPO_ROOT, "src/flutter_ffi.rs")
SUPERVISOR_RS_PATH = os.path.join(REPO_ROOT, "src/server/android_supervisor.rs")
SCRAP_FFI_RS_PATH = os.path.join(REPO_ROOT, "libs/scrap/src/android/ffi.rs")
FRAME_RAW_RS_PATH = os.path.join(REPO_ROOT, "libs/scrap/src/common/frame_raw.rs")


class AndroidHostContractTests(unittest.TestCase):
    def test_auth_009_no_debug_boot_completed(self):
        """AUTH-009: Assert complete absence of DEBUG_BOOT_COMPLETED in Android source tree."""
        android_dir = os.path.join(REPO_ROOT, "flutter/android/app/src/main")
        for root, _, files in os.walk(android_dir):
            for file in files:
                if file.endswith((".xml", ".kt", ".java", ".gradle")):
                    filepath = os.path.join(root, file)
                    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
                        content = f.read()
                    self.assertNotIn(
                        "DEBUG_BOOT_COMPLETED",
                        content,
                        f"Found prohibited DEBUG_BOOT_COMPLETED in {filepath}",
                    )

    def test_compat_005_manifest_fgs_permissions_and_types(self):
        """COMPAT-005: Assert required FGS permissions and service types in AndroidManifest.xml."""
        self.assertTrue(os.path.exists(MANIFEST_PATH), f"Missing {MANIFEST_PATH}")
        with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
            manifest_text = f.read()

        # Check permissions
        self.assertIn("android.permission.FOREGROUND_SERVICE", manifest_text)
        self.assertIn("android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION", manifest_text)
        self.assertIn("android.permission.FOREGROUND_SERVICE_MICROPHONE", manifest_text)

        # Parse XML
        tree = ET.parse(MANIFEST_PATH)
        root = tree.getroot()
        ns = {"android": "http://schemas.android.com/apk/res/android"}

        application = root.find("application")
        self.assertIsNotNone(application)

        # Find MainService
        main_service = None
        for service in application.findall("service"):
            name = service.attrib.get(f"{{{ns['android']}}}name")
            if name in (".MainService", "com.camellia.remote.MainService"):
                main_service = service
                break

        self.assertIsNotNone(main_service, "MainService not declared in AndroidManifest.xml")
        fgs_type = main_service.attrib.get(f"{{{ns['android']}}}foregroundServiceType", "")
        self.assertIn("mediaProjection", fgs_type)
        self.assertIn("microphone", fgs_type)

    def test_boot_receiver_strict_intent_filters(self):
        """AUTH-009: BootReceiver only handles official system boot intents."""
        with open(BOOT_RECEIVER_PATH, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("Intent.ACTION_BOOT_COMPLETED", content)
        self.assertIn("QUICKBOOT_POWERON", content)
        self.assertNotIn("DEBUG_BOOT_COMPLETED", content)

    def test_compat_005_mediaprojection_callback_and_fail_closed_capture(self):
        """COMPAT-005: MainService must register MediaProjection.Callback and enforce fail-closed capture."""
        with open(MAIN_SERVICE_PATH, "r", encoding="utf-8") as f:
            content = f.read()

        # Check MediaProjection.Callback registration
        self.assertIn("projectionCallback", content)
        self.assertIn("mp.registerCallback(projectionCallback", content)
        self.assertIn("override fun onStop()", content)
        self.assertIn("handleProjectionStopped()", content)

        # Check fail-closed startCapture
        self.assertIn("createOrSetVirtualDisplay", content)
        self.assertIn("if (!vdOk || virtualDisplay == null)", content)
        self.assertIn("stopCapture()", content)
        self.assertIn("return false", content)

        # Check voice call FGS promotion
        self.assertIn("updateForegroundServiceType()", content)
        self.assertIn("FOREGROUND_SERVICE_TYPE_MICROPHONE", content)
        self.assertIn("FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION", content)

    def test_res_040_supervisor_and_teardown(self):
        """RES-040: Supervisor and teardown methods exist in Kotlin and Rust."""
        with open(MAIN_SERVICE_PATH, "r", encoding="utf-8") as f:
            service_code = f.read()

        # Teardown calls
        self.assertIn("FFI.stopServer()", service_code)
        self.assertIn("FFI.cleanupMainService()", service_code)
        self.assertIn("serviceLooper?.quitSafely()", service_code)
        self.assertIn("sendVP9Thread.shutdown()", service_code)

        # ffi.kt declarations
        with open(FFI_KT_PATH, "r", encoding="utf-8") as f:
            ffi_kt = f.read()
        self.assertIn("external fun stopServer()", ffi_kt)
        self.assertIn("external fun cleanupMainService()", ffi_kt)

        # Rust FFI JNI methods
        with open(FLUTTER_FFI_RS_PATH, "r", encoding="utf-8") as f:
            flutter_ffi = f.read()
        self.assertIn("Java_ffi_FFI_startServer", flutter_ffi)
        self.assertIn("Java_ffi_FFI_stopServer", flutter_ffi)
        self.assertIn("start_android_server", flutter_ffi)
        self.assertIn("stop_android_server", flutter_ffi)

        # Supervisor implementation
        with open(SUPERVISOR_RS_PATH, "r", encoding="utf-8") as f:
            supervisor = f.read()
        self.assertIn("start_android_server", supervisor)
        self.assertIn("stop_android_server", supervisor)
        self.assertIn("is_android_server_active", supervisor)

    def test_unsafe_003_frame_raw_bounds_and_copy_contract(self):
        """UNSAFE-003: Scrap FrameRaw enforces bounds, synchronous copy, and cleanup."""
        with open(FRAME_RAW_RS_PATH, "r", encoding="utf-8") as f:
            frame_raw = f.read()

        self.assertIn("MAX_VIDEO_FRAME_BYTES", frame_raw)
        self.assertIn("MAX_AUDIO_FRAME_BYTES", frame_raw)
        self.assertIn("pub fn update(&mut self, slice: &[u8])", frame_raw)
        self.assertIn("self.buffer.extend_from_slice(slice)", frame_raw)
        self.assertIn("self.buffer.shrink_to_fit()", frame_raw)

        with open(SCRAP_FFI_RS_PATH, "r", encoding="utf-8") as f:
            scrap_ffi = f.read()
        self.assertIn("Java_ffi_FFI_cleanupMainService", scrap_ffi)
        self.assertIn("VIDEO_RAW.lock()", scrap_ffi)
        self.assertIn("AUDIO_RAW.lock()", scrap_ffi)
        self.assertIn("raw.update(slice)", scrap_ffi)


if __name__ == "__main__":
    unittest.main()
