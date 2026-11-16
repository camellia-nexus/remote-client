#!/usr/bin/env python3
"""Contract tests for Batch 86: Client Windows Driver, Virtual Display ABI,

and Magnification FFI Safety (FFI-002, UNSAFE-010, ABI-001).
"""

from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parents[3]
MAG_RS = REPO_ROOT / "libs" / "scrap" / "src" / "dxgi" / "mag.rs"
IDD_CONTROLLER_C = (
    REPO_ROOT
    / "libs"
    / "virtual_display"
    / "dylib"
    / "src"
    / "win10"
    / "IddController.c"
)
DYLIB_LIB_RS = REPO_ROOT / "libs" / "virtual_display" / "dylib" / "src" / "lib.rs"
LOADER_LIB_RS = REPO_ROOT / "libs" / "virtual_display" / "src" / "lib.rs"


class TestBatch86WindowsSafety(unittest.TestCase):
    """Verifies contracts for FFI-002, UNSAFE-010, and ABI-001."""

    def test_ffi_002_magnification_callback_bounds_and_null_checks(self):
        """Ensure mag.rs callback validates pointers, dimensions, arithmetic overflow,

        buffer limits, and recovers safely from poisoned locks without panic.
        """
        self.assertTrue(MAG_RS.exists(), f"Missing {MAG_RS}")
        content = MAG_RS.read_text(encoding="utf-8")

        # 1. Bounded buffer size constant
        self.assertIn("MAX_MAG_BUFFER_SIZE", content)
        self.assertIn("256 * 1024 * 1024", content)

        # 2. Pointer null check
        self.assertIn("srcdata.is_null()", content)

        # 3. Size bound check
        self.assertIn("srcheader.cbSize > MAX_MAG_BUFFER_SIZE", content)

        # 4. Dimension non-zero checks
        self.assertIn("srcheader.width == 0", content)
        self.assertIn("srcheader.height == 0", content)
        self.assertIn("srcheader.stride == 0", content)

        # 5. Checked arithmetic for stride * height + offset
        self.assertIn("checked_mul", content)
        self.assertIn("checked_add", content)
        self.assertIn("srcheader.cbSize < required_bytes", content)

        # 6. Safe poison handling on Mutex (no unwrap across FFI)
        self.assertIn("into_inner()", content)

        # 7. Safe slice copy without raw indexing
        self.assertIn("copy_from_slice", content)

    def test_unsafe_010_swdevice_callback_lifetime_and_refcounting(self):
        """Ensure IddController.c uses heap-allocated context with reference counting,

        preventing stack use-after-free, closed handle signaling, and handle leaks.
        """
        self.assertTrue(IDD_CONTROLLER_C.exists(), f"Missing {IDD_CONTROLLER_C}")
        content = IDD_CONTROLLER_C.read_text(encoding="utf-8")

        # 1. Struct has refCount and copied lifetime
        self.assertIn("LONG refCount;", content)
        self.assertIn("SW_DEVICE_LIFETIME lifetime;", content)
        self.assertIn("BOOL hasLifetime;", content)

        # 2. HeapAlloc used for context lifecycle
        self.assertIn("HeapAlloc", content)
        self.assertIn("pCtx->refCount = 2;", content)

        # 3. Synchronous failure cleanup
        self.assertIn("CloseHandle(hEvent);", content)
        self.assertIn("HeapFree(GetProcessHeap(), 0, pCtx);", content)

        # 4. InterlockedDecrement used for dual-owner reclamation
        self.assertIn("InterlockedDecrement(&pCtx->refCount)", content)
        self.assertIn("InterlockedDecrement(&callbackContext->refCount)", content)

    def test_abi_001_virtual_display_c_abi_and_version_handshake(self):
        """Ensure virtual_display dylib and loader enforce versioned C ABI handshakes,

        magic validation, and caller-buffered error strings.
        """
        self.assertTrue(DYLIB_LIB_RS.exists(), f"Missing {DYLIB_LIB_RS}")
        self.assertTrue(LOADER_LIB_RS.exists(), f"Missing {LOADER_LIB_RS}")

        dylib_content = DYLIB_LIB_RS.read_text(encoding="utf-8")
        loader_content = LOADER_LIB_RS.read_text(encoding="utf-8")

        # 1. Magic and version constants match
        magic = "0x56495254"
        self.assertIn(magic, dylib_content)
        self.assertIn(magic, loader_content)
        self.assertIn("VIRTUAL_DISPLAY_ABI_MAGIC", dylib_content)
        self.assertIn("VIRTUAL_DISPLAY_ABI_VERSION", dylib_content)

        # 2. Exported C-ABI functions
        self.assertIn('pub extern "C" fn virtual_display_abi_magic', dylib_content)
        self.assertIn('pub extern "C" fn virtual_display_abi_version', dylib_content)
        self.assertIn('pub extern "C" fn virtual_display_create_device', dylib_content)
        self.assertIn(
            'pub extern "C" fn virtual_display_install_update_driver', dylib_content
        )
        self.assertIn(
            'pub extern "C" fn virtual_display_plug_in_monitor', dylib_content
        )
        self.assertIn(
            'pub extern "C" fn virtual_display_get_last_error', dylib_content
        )

        # 3. Loader validation and incompatibility rejection
        self.assertIn("virtual_display_abi_magic", loader_content)
        self.assertIn("virtual_display_abi_version", loader_content)
        self.assertIn("Incompatible virtual display library ABI", loader_content)
        self.assertIn("is_versioned_c_abi", loader_content)
        self.assertIn("get_error_message", loader_content)


if __name__ == "__main__":
    unittest.main()
