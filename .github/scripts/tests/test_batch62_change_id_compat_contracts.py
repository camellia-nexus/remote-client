#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 62:
COMPAT-001 — Client 默认公开 Change ID 但当前 Remote Server 明确拒绝全部改 ID 请求.

Verifies:
1. Static code invariants in client/src/common.rs:
   - `get_builtin_option` defaults `OPTION_DISABLE_CHANGE_ID` to "Y" unless explicitly overridden.
   - `is_change_id_disabled()` defaults to true unless explicitly configured to "N".

2. Static code invariants in client/src/core_main.rs:
   - CLI `--set-id` fails fast immediately with:
     "Changing device ID is not supported by the remote rendezvous server"
   - Avoids wasteful network roundtrips, timeouts, or misleading promises.

3. Static code invariants in client/src/ui_interface.rs:
   - `change_id()` fails fast when disabled, setting status to "server_not_support"
     without spawning detached background threads or setting lingering polling states (" ").
   - `change_id_shared_()` fails fast returning "server_not_support" without initiating TCP/network operations.

4. Static code invariants in Flutter UI layers:
   - `common.dart`: `isChangeIdDisabled()` defaults to true unless explicitly 'N'.
   - `desktop_setting_page.dart`: Hides Change ID card and buttons when disabled.
   - `server_page.dart`: Hides mobile popup item/divider and aborts selection when disabled.
   - `dialog.dart`: `changeIdDialog()` aborts immediately when disabled.
   - `web_client_home.dart`: Hides trailing button and aborts `_rotateMyId()` when disabled.

5. Functional simulation of capability evaluation and CLI/UI dispatch.
"""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CLIENT_SRC = REPO_ROOT / "src"
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"


class TestBatch62ChangeIdCompatContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.common_rs = (CLIENT_SRC / "common.rs").read_text(encoding="utf-8")
        cls.core_main_rs = (CLIENT_SRC / "core_main.rs").read_text(encoding="utf-8")
        cls.ui_interface_rs = (CLIENT_SRC / "ui_interface.rs").read_text(encoding="utf-8")
        cls.ipc_rs = (CLIENT_SRC / "ipc.rs").read_text(encoding="utf-8")
        cls.flutter_common_dart = (FLUTTER_LIB / "common.dart").read_text(encoding="utf-8")
        cls.desktop_setting_page_dart = (
            FLUTTER_LIB / "desktop" / "pages" / "desktop_setting_page.dart"
        ).read_text(encoding="utf-8")
        cls.mobile_server_page_dart = (
            FLUTTER_LIB / "mobile" / "pages" / "server_page.dart"
        ).read_text(encoding="utf-8")
        cls.dialog_dart = (
            FLUTTER_LIB / "common" / "widgets" / "dialog.dart"
        ).read_text(encoding="utf-8")
        cls.web_client_home_dart = (
            FLUTTER_LIB / "web" / "web_client_home.dart"
        ).read_text(encoding="utf-8")

    # 1. Common / Builtin Invariants
    def test_common_rs_get_builtin_option_defaults_disable_change_id_to_y(self):
        self.assertIn("keys::OPTION_DISABLE_CHANGE_ID", self.common_rs)
        self.assertIn("val.is_empty()", self.common_rs)
        self.assertIn('return "Y".to_owned()', self.common_rs)

    def test_common_rs_exports_is_change_id_disabled(self):
        self.assertIn("pub fn is_change_id_disabled() -> bool", self.common_rs)
        self.assertIn('get_builtin_option(keys::OPTION_DISABLE_CHANGE_ID) != "N"', self.common_rs)

    def test_ipc_rs_guards_id_write_against_disabled_change_id(self):
        some_value_idx = self.ipc_rs.find("Some(value) => {")
        self.assertGreater(some_value_idx, 0)
        id_write_idx = self.ipc_rs.find('if name == "id"', some_value_idx)
        self.assertGreater(id_write_idx, some_value_idx)
        block = self.ipc_rs[id_write_idx : id_write_idx + 400]
        self.assertIn("crate::common::is_change_id_disabled()", block)
        self.assertIn("updated = false;", block)

    # 2. CLI Fail-Fast Invariants
    def test_core_main_cli_set_id_fail_fast_message(self):
        self.assertIn('args[0] == "--set-id"', self.core_main_rs)
        expected_msg = "Changing device ID is not supported by the remote rendezvous server"
        self.assertIn(expected_msg, self.core_main_rs)
        self.assertIn("crate::common::is_change_id_disabled()", self.core_main_rs)

    def test_core_main_cli_fails_fast_before_network(self):
        set_id_idx = self.core_main_rs.find('args[0] == "--set-id"')
        self.assertGreater(set_id_idx, 0)
        block = self.core_main_rs[set_id_idx : set_id_idx + 800]
        check_disabled_idx = block.find("crate::common::is_change_id_disabled()")
        network_call_idx = block.find("change_id_shared")
        self.assertGreater(check_disabled_idx, 0)
        self.assertGreater(network_call_idx, check_disabled_idx)

    # 3. Rust Bridge Fail-Fast & Thread Safety Invariants
    def test_ui_interface_exports_is_change_id_disabled(self):
        self.assertIn("pub fn is_change_id_disabled() -> bool", self.ui_interface_rs)

    def test_ui_interface_change_id_fails_fast_without_thread_spawn(self):
        change_id_idx = self.ui_interface_rs.find("pub fn change_id(id: String)")
        self.assertGreater(change_id_idx, 0)
        block = self.ui_interface_rs[change_id_idx : change_id_idx + 600]
        self.assertIn("crate::common::is_change_id_disabled()", block)
        self.assertIn('*ASYNC_JOB_STATUS.lock().unwrap() = "server_not_support".to_string()', block)
        
        # Verify return occurs before thread::spawn
        return_idx = block.find("return;")
        spawn_idx = block.find("std::thread::spawn")
        self.assertGreater(return_idx, 0)
        self.assertGreater(spawn_idx, return_idx)

    def test_ui_interface_change_id_shared_fails_fast(self):
        change_id_shared_idx = self.ui_interface_rs.find("pub async fn change_id_shared_(")
        self.assertGreater(change_id_shared_idx, 0)
        block = self.ui_interface_rs[change_id_shared_idx : change_id_shared_idx + 400]
        self.assertIn("crate::common::is_change_id_disabled()", block)
        self.assertIn('return "server_not_support";', block)

    # 4. Flutter UI Layer Invariants
    def test_flutter_common_is_change_id_disabled_defaults_true(self):
        self.assertIn("bool isChangeIdDisabled()", self.flutter_common_dart)
        self.assertIn("bind.mainGetBuildinOption(key: kOptionDisableChangeId)", self.flutter_common_dart)
        self.assertIn("if (opt.isEmpty)", self.flutter_common_dart)
        self.assertIn("return true;", self.flutter_common_dart)
        self.assertIn("return opt != 'N';", self.flutter_common_dart)

    def test_desktop_setting_page_guards_change_id(self):
        self.assertIn("if (!isChangeIdDisabled())", self.desktop_setting_page_dart)
        self.assertIn("_Card(title: 'ID', children: [changeId()])", self.desktop_setting_page_dart)
        
        # changeId widget itself returns SizedBox.shrink() when disabled
        change_id_widget_idx = self.desktop_setting_page_dart.find("Widget changeId()")
        self.assertGreater(change_id_widget_idx, 0)
        block = self.desktop_setting_page_dart[change_id_widget_idx : change_id_widget_idx + 200]
        self.assertIn("if (isChangeIdDisabled())", block)
        self.assertIn("return const SizedBox.shrink();", block)

    def test_mobile_server_page_guards_change_id(self):
        self.assertIn("if (!isChangeIdDisabled())", self.mobile_server_page_dart)
        self.assertIn('value: "changeID"', self.mobile_server_page_dart)
        self.assertIn("if (!isChangeIdDisabled()) const PopupMenuDivider()", self.mobile_server_page_dart)
        
        # onSelected handler also guards against disabled
        on_selected_idx = self.mobile_server_page_dart.find('if (value == "changeID")')
        self.assertGreater(on_selected_idx, 0)
        block = self.mobile_server_page_dart[on_selected_idx : on_selected_idx + 200]
        self.assertIn("if (isChangeIdDisabled())", block)
        self.assertIn("return;", block)

    def test_dialog_change_id_dialog_guards_disabled(self):
        dialog_idx = self.dialog_dart.find("void changeIdDialog()")
        self.assertGreater(dialog_idx, 0)
        block = self.dialog_dart[dialog_idx : dialog_idx + 200]
        self.assertIn("if (isChangeIdDisabled())", block)
        self.assertIn("return;", block)

    def test_web_client_home_guards_change_id(self):
        self.assertIn("trailing: isChangeIdDisabled()", self.web_client_home_dart)
        rotate_idx = self.web_client_home_dart.find("Future<void> _rotateMyId()")
        self.assertGreater(rotate_idx, 0)
        block = self.web_client_home_dart[rotate_idx : rotate_idx + 200]
        self.assertIn("if (isChangeIdDisabled())", block)
        self.assertIn("return;", block)

    # 5. Functional Simulation Tests
    def test_functional_simulation_is_change_id_disabled_contract(self):
        def simulate_rust_get_builtin_option(settings: dict, key: str) -> str:
            if key == "disable-change-id":
                val = settings.get(key, "")
                return "Y" if not val else val
            return settings.get(key, "")

        def simulate_rust_is_change_id_disabled(settings: dict) -> bool:
            return simulate_rust_get_builtin_option(settings, "disable-change-id") != "N"

        def simulate_flutter_is_change_id_disabled(opt: str) -> bool:
            if not opt:
                return True
            return opt != "N"

        # Case 1: Default/empty builtin settings -> disabled
        empty_settings = {}
        rust_opt = simulate_rust_get_builtin_option(empty_settings, "disable-change-id")
        self.assertEqual(rust_opt, "Y")
        self.assertTrue(simulate_rust_is_change_id_disabled(empty_settings))
        self.assertTrue(simulate_flutter_is_change_id_disabled(rust_opt))
        self.assertTrue(simulate_flutter_is_change_id_disabled(""))

        # Case 2: Explicitly disabled with 'Y' -> disabled
        y_settings = {"disable-change-id": "Y"}
        self.assertEqual(simulate_rust_get_builtin_option(y_settings, "disable-change-id"), "Y")
        self.assertTrue(simulate_rust_is_change_id_disabled(y_settings))
        self.assertTrue(simulate_flutter_is_change_id_disabled("Y"))

        # Case 3: Explicitly enabled with 'N' (future-proof) -> enabled
        n_settings = {"disable-change-id": "N"}
        self.assertEqual(simulate_rust_get_builtin_option(n_settings, "disable-change-id"), "N")
        self.assertFalse(simulate_rust_is_change_id_disabled(n_settings))
        self.assertFalse(simulate_flutter_is_change_id_disabled("N"))

        # Case 4: Any invalid/arbitrary option value -> fails closed (disabled)
        for invalid in ["", "true", "false", "0", "1", "unknown"]:
            invalid_settings = {"disable-change-id": invalid}
            self.assertTrue(simulate_rust_is_change_id_disabled(invalid_settings))
            self.assertTrue(simulate_flutter_is_change_id_disabled(invalid))


if __name__ == "__main__":
    unittest.main()
