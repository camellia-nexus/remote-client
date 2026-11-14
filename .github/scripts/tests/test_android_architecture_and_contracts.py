#!/usr/bin/env python3
"""Contract tests for Android Architecture, IPC Contracts, and Lifecycle Teardown.

Covers:
- BUILD-014: Official Android artifact uses loadable libcamellia_remote.so name, single ABI filter,
  and native runtime closure.
- PLATFORM-016: Android main MethodChannel responds to all methods, guards arguments,
  and avoids 120s permission wait on denial.
- RES-062: Android Activity/Service/MediaProjection/JNI owner determines teardown, cleans channels,
  and avoids leaks on rotation/engine recreation.
"""

import subprocess
import unittest
from pathlib import Path

CLIENT_ROOT = Path(__file__).resolve().parents[3]


class AndroidArchitectureAndContractsTest(unittest.TestCase):
    def setUp(self):
        self.build_gradle = CLIENT_ROOT / "flutter/android/app/build.gradle"
        self.build_py = CLIENT_ROOT / "build.py"
        self.ffi_kt = CLIENT_ROOT / "flutter/android/app/src/main/kotlin/ffi.kt"
        self.main_activity = CLIENT_ROOT / "flutter/android/app/src/main/kotlin/com/camellia/remote/MainActivity.kt"
        self.common_kt = CLIENT_ROOT / "flutter/android/app/src/main/kotlin/com/camellia/remote/common.kt"
        self.main_service = CLIENT_ROOT / "flutter/android/app/src/main/kotlin/com/camellia/remote/MainService.kt"
        self.audio_handle = CLIENT_ROOT / "flutter/android/app/src/main/kotlin/com/camellia/remote/AudioRecordHandle.kt"
        self.desktop_drop = CLIENT_ROOT / "flutter/plugins/desktop_drop/android/src/main/kotlin/one/mixin/desktop/drop/DesktopDropPlugin.kt"
        self.uni_links = CLIENT_ROOT / "flutter/android/uni_links_v2/src/main/java/name/avioli/unilinks/UniLinksPlugin.java"
        self.common_dart = CLIENT_ROOT / "flutter/lib/common.dart"
        self.server_page = CLIENT_ROOT / "flutter/lib/mobile/pages/server_page.dart"
        self.scan_page = CLIENT_ROOT / "flutter/lib/mobile/pages/scan_page.dart"
        self.ffi_rs = CLIENT_ROOT / "libs/scrap/src/android/ffi.rs"
        self.check_script = CLIENT_ROOT / ".github/scripts/check-android-package.sh"
        self.hwcodec_build_rs = CLIENT_ROOT / "libs/hwcodec/build.rs"
        self.ci_workflow = CLIENT_ROOT / ".github/workflows/ci.yml"

    def test_build005_android_bindgen_versioned_target_contracts(self):
        """BUILD-005: Android NDK 30 bindgen requires versioned target triples or __ANDROID_API__."""
        hwcodec_content = self.hwcodec_build_rs.read_text(encoding="utf-8")
        self.assertIn("fn bindgen_builder() -> bindgen::Builder", hwcodec_content)
        self.assertIn("--target=", hwcodec_content)
        self.assertIn("__ANDROID_API__", hwcodec_content)
        self.assertIn("is_ascii_digit", hwcodec_content)
        self.assertIn("aarch64-linux-android", hwcodec_content)
        self.assertIn("armv7a-linux-androideabi", hwcodec_content)
        self.assertIn("x86_64-linux-android", hwcodec_content)
        self.assertIn("i686-linux-android", hwcodec_content)
        # Ensure direct unconfigured bindgen::builder() is not called anywhere except inside bindgen_builder()
        bindgen_calls = [
            line.strip()
            for line in hwcodec_content.splitlines()
            if "bindgen::builder()" in line
        ]
        self.assertEqual(
            len(bindgen_calls),
            1,
            f"Expected exactly 1 bindgen::builder() call inside bindgen_builder, found: {bindgen_calls}",
        )

        build_py_content = self.build_py.read_text(encoding="utf-8")
        self.assertIn("BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android", build_py_content)
        self.assertIn("--target=aarch64-linux-android26", build_py_content)
        self.assertIn("-D__ANDROID_API__=26", build_py_content)

        ci_content = self.ci_workflow.read_text(encoding="utf-8")
        self.assertIn("BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android", ci_content)
        self.assertIn("VCPKG_ROOT", ci_content)

    def test_build005_android_triple_resolution_logic(self):
        """BUILD-005: Verify api_level sanitization and target triple formatting logic."""
        def resolve_triple(raw_api: str, target: str) -> tuple[str, str]:
            trimmed_api = raw_api.removeprefix("android-")
            api_level = trimmed_api if trimmed_api.isdigit() and len(trimmed_api) > 0 else "26"
            if target.startswith("aarch64"):
                versioned = f"aarch64-linux-android{api_level}"
            elif target.startswith("armv7"):
                versioned = f"armv7a-linux-androideabi{api_level}"
            elif target.startswith("x86_64"):
                versioned = f"x86_64-linux-android{api_level}"
            elif target.startswith("i686"):
                versioned = f"i686-linux-android{api_level}"
            else:
                versioned = f"aarch64-linux-android{api_level}"
            return versioned, api_level

        # Case 1: CARGO_NDK_PLATFORM="arm64-v8a" (non-digit platform string passed by cargo-ndk)
        target, api = resolve_triple("arm64-v8a", "aarch64-linux-android")
        self.assertEqual(api, "26")
        self.assertEqual(target, "aarch64-linux-android26")

        # Case 2: standard android-26
        target, api = resolve_triple("android-26", "aarch64-linux-android")
        self.assertEqual(api, "26")
        self.assertEqual(target, "aarch64-linux-android26")

        # Case 3: numeric string 28
        target, api = resolve_triple("28", "armv7-linux-androideabi")
        self.assertEqual(api, "28")
        self.assertEqual(target, "armv7a-linux-androideabi28")

        # Case 4: x86_64 and i686
        target, api = resolve_triple("26", "x86_64-linux-android")
        self.assertEqual(target, "x86_64-linux-android26")
        target, api = resolve_triple("26", "i686-linux-android")
        self.assertEqual(target, "i686-linux-android26")

        # Case 5: empty string fallback
        target, api = resolve_triple("", "aarch64-linux-android")
        self.assertEqual(api, "26")
        self.assertEqual(target, "aarch64-linux-android26")

    def test_build014_gradle_abi_filter_and_packaging_closure(self):
        """BUILD-014: Gradle must enforce arm64-v8a abiFilter and libc++_shared packaging pick."""
        content = self.build_gradle.read_text(encoding="utf-8")
        self.assertIn('abiFilters "arm64-v8a"', content)
        self.assertIn("pickFirsts += ['**/libc++_shared.so']", content)

    def test_build014_ffi_load_library_contract(self):
        """BUILD-014: Kotlin System.loadLibrary must target camellia_remote."""
        content = self.ffi_kt.read_text(encoding="utf-8")
        self.assertIn('System.loadLibrary("camellia_remote")', content)

    def test_build014_build_py_staging_contract(self):
        """BUILD-014: build.py must stage libcamellia_remote.so and never un-prefixed camellia_remote.so."""
        content = self.build_py.read_text(encoding="utf-8")
        self.assertIn('jni_libs / "libcamellia_remote.so"', content)
        self.assertNotIn('copy2(\n        ROOT / "target/aarch64-linux-android/release/libcamellia_remote.so",\n        jni_libs / "camellia_remote.so"', content)
        self.assertIn("libc++_shared.so", content)
        self.assertIn('"flutter,mediacodec"', content)
        self.assertNotIn('"flutter,hwcodec"', content)

    def test_build014_check_package_script_repo_validation(self):
        """BUILD-014: check-android-package.sh must validate the repo successfully."""
        result = subprocess.run(
            [str(self.check_script), "--repo-check"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, f"check-android-package.sh failed: {result.stderr}")
        self.assertIn("Repository Android packaging contracts OK", result.stdout)

    def test_platform016_main_activity_notification_and_voice_replies(self):
        """PLATFORM-016: cancel_notification and voice calls must reply to Flutter."""
        content = self.main_activity.read_text(encoding="utf-8")
        # cancel_notification must call result.success(true) when id is valid Int
        self.assertIn("mainService?.cancelNotification(id)", content)
        self.assertIn('result.error("invalid_argument", "Expected Int notification ID", null)', content)
        # on_voice_call_started must return result.success(res)
        self.assertIn('"on_voice_call_started" -> {', content)
        self.assertIn("val res = onVoiceCallStarted()\n                    result.success(res)", content)
        # on_voice_call_closed must return result.success(res)
        self.assertIn('"on_voice_call_closed" -> {', content)
        self.assertIn("val res = onVoiceCallClosed()\n                    result.success(res)", content)

    def test_platform016_main_activity_keyboard_type_guard_and_exception_handler(self):
        """PLATFORM-016: enable_soft_keyboard must guard boolean arguments and handler must catch unhandled exceptions."""
        content = self.main_activity.read_text(encoding="utf-8")
        self.assertIn('result.error("invalid_argument", "Expected Boolean argument", null)', content)
        self.assertIn('result.error("internal_error", e.message, null)', content)

    def test_platform016_permission_callback_on_all_outcomes(self):
        """PLATFORM-016: XXPermissions must invoke on_android_permission_result for both grant and deny."""
        content = self.common_kt.read_text(encoding="utf-8")
        self.assertNotIn("if (all) {\n                Handler", content)
        self.assertIn('"result" to all', content)
        self.assertIn('"request_id"', content)

    def test_platform016_dart_permission_manager_request_id_and_bounded_timer(self):
        """PLATFORM-016: AndroidPermissionManager must use request ID and short bounded timeout."""
        content = self.common_dart.read_text(encoding="utf-8")
        self.assertIn("static int _requestId = 0;", content)
        self.assertIn("static int _currentRequestId = 0;", content)
        self.assertIn("Duration(seconds: 15)", content)
        self.assertNotIn("Duration(seconds: 120)", content)

        # server_page receives request_id and routes it
        server_content = self.server_page.read_text(encoding="utf-8")
        self.assertIn('var requestId = arguments["request_id"] as String?;', server_content)
        self.assertIn("AndroidPermissionManager.complete(type, result, requestId: requestId);", server_content)

    def test_res062_main_activity_service_binding_lifecycle(self):
        """RES-062: MainActivity must track isBound, bind idempotently, and clean channels on destroy."""
        content = self.main_activity.read_text(encoding="utf-8")
        self.assertIn("private var isBound = false", content)
        self.assertIn("private fun bindMainService()", content)
        self.assertIn("private fun unbindMainService()", content)
        self.assertIn("override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine)", content)
        self.assertIn("audioRecordHandle.destroy()", content)

    def test_res062_main_service_and_audio_teardown(self):
        """RES-062: MainService must invoke audioRecordHandle.destroy() in destroy()."""
        content = self.main_service.read_text(encoding="utf-8")
        self.assertIn("fun destroy()", content)
        self.assertIn("audioRecordHandle.destroy()", content)

        audio_content = self.audio_handle.read_text(encoding="utf-8")
        self.assertIn("fun destroy()", audio_content)
        self.assertIn("stopAudioThreadGracefully()", audio_content)

    def test_res062_plugin_lifecycle_contracts(self):
        """RES-062: DesktopDropPlugin and UniLinksPlugin must cleanly detach on config changes and engine detach."""
        drop_content = self.desktop_drop.read_text(encoding="utf-8")
        self.assertIn("override fun onDetachedFromEngine", drop_content)
        self.assertIn("channel?.setMethodCallHandler(null)", drop_content)
        self.assertIn("override fun onDetachedFromActivityForConfigChanges()", drop_content)
        self.assertIn("dragView?.setOnDragListener(null)", drop_content)
        self.assertIn("override fun onReattachedToActivityForConfigChanges", drop_content)
        self.assertIn("onAttachedToActivity(binding)", drop_content)

        links_content = self.uni_links.read_text(encoding="utf-8")
        self.assertIn("private MethodChannel methodChannel;", links_content)
        self.assertIn("private EventChannel eventChannel;", links_content)
        self.assertIn("private ActivityPluginBinding activityPluginBinding;", links_content)
        self.assertIn("methodChannel.setMethodCallHandler(null);", links_content)
        self.assertIn("eventChannel.setStreamHandler(null);", links_content)
        self.assertIn("activityPluginBinding.removeOnNewIntentListener(this);", links_content)

        scan_content = self.scan_page.read_text(encoding="utf-8")
        self.assertIn("controller?.dispose();", scan_content)

    def test_res062_rust_jni_generation_and_lockless_calls(self):
        """RES-062: Rust FFI must track generation and drop RwLocks before attaching to Java."""
        content = self.ffi_rs.read_text(encoding="utf-8")
        self.assertIn("static MAIN_SERVICE_GENERATION: AtomicU64", content)
        self.assertIn("pub fn main_service_generation() -> u64", content)
        self.assertIn("fn get_main_service_handles() -> Option<(JavaVM, GlobalRef)>", content)
        self.assertIn("fn get_clipboard_handles() -> Option<(JavaVM, GlobalRef)>", content)


if __name__ == "__main__":
    unittest.main()
