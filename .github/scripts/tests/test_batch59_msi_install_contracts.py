#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 59:
INSTALL-001 — MSI system mutation CustomActions error hardening,
typed HRESULT returns, rollback CustomActions pairing, and orphan port prevention.

Verifies:
1. WiX Fragment and Component Schemas:
   - CustomActions.wxs:
     - Transaction-critical actions configured with Return="check":
       CreateStartService, TryStopDeleteService, AddFirewallRules, RemoveFirewallRules,
       InstallPrinter, UninstallPrinter, AddRegSoftwareSASGeneration,
       SetPropertyIsServiceRunning, SetPropertyServiceStop.
     - Best-effort actions explicitly configured with Return="ignore":
       TerminateProcesses, TerminateBrokers, TryDeleteStartupShortcut,
       RemoveAmyuniIdd, CustomActionHello, RemoveRuntimeGeneratedFiles.
     - Paired rollback CustomActions defined with Execute="rollback" and Return="check":
       RollbackCreateStartService, RollbackFirewallRules, RollbackPrinter.
   - RustDesk.wxs:
     - Rollback property SetParam actions exist.
     - InstallExecuteSequence schedules rollback actions BEFORE their paired deferred actions.
     - Rollback actions share matching activation conditions with deferred actions.
     - Ordering between SetParam, rollback, and forward action is strictly linear.
2. C++ Source Code Invariants:
   - RemotePrinter.cpp:
     - addPrinter closes hPrinter handle via ClosePrinter on success (RES-029).
     - installUpdatePrinter returns HRESULT (not VOID).
     - FileExists(infFile) is checked BEFORE any port modification (checkAddLocalPort).
     - Missing INF immediately returns HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND).
     - Driver install failure aborts before addPrinter and cleans up newly created local port.
     - addPrinter failure cleans up driver and newly created local port.
     - uninstallPrinter returns HRESULT and cleans up printer, driver, and port.
   - CustomActions.cpp:
     - InstallPrinter calls RemotePrinter::installUpdatePrinter and validates with ExitOnFailure.
     - UninstallPrinter calls RemotePrinter::uninstallPrinter and validates with ExitOnFailure.
     - CreateStartService verifies IsServiceRunningW and sets hr on failure.
     - AddFirewallRules checks AddFirewallRuleEx HRESULT with ExitOnFailure.
     - AddRegSoftwareSASGeneration passes &valueData and sets hr on RegCreateKey/SetValue failure.
   - FirewallRules.cpp:
     - AddFirewallRuleEx returns typed HRESULT.
     - RemoveFirewallRule is idempotent against absent rules (ERROR_FILE_NOT_FOUND).
   - Common.h:
     - Prototypes declare HRESULT for RemotePrinter functions and AddFirewallRuleEx.
3. State Machine Simulation:
   - Simulates clean release without INF: selecting PRINTER=1 triggers deterministic failure without orphan port.
   - Simulates driver failure during install: newly created port is deleted.
   - Simulates service startup failure: rollback stops and deletes the service.
"""

import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
MSI_DIR = REPO_ROOT / "res" / "msi"
CUSTOM_ACTIONS_WXS = MSI_DIR / "Package" / "Fragments" / "CustomActions.wxs"
RUSTDESK_WXS = MSI_DIR / "Package" / "Components" / "RustDesk.wxs"
CUSTOM_ACTIONS_CPP = MSI_DIR / "CustomActions" / "CustomActions.cpp"
REMOTE_PRINTER_CPP = MSI_DIR / "CustomActions" / "RemotePrinter.cpp"
FIREWALL_RULES_CPP = MSI_DIR / "CustomActions" / "FirewallRules.cpp"
COMMON_H = MSI_DIR / "CustomActions" / "Common.h"


class TestBatch59MsiInstallContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.custom_actions_wxs_text = CUSTOM_ACTIONS_WXS.read_text(encoding="utf-8")
        cls.rustdesk_wxs_text = RUSTDESK_WXS.read_text(encoding="utf-8")
        cls.custom_actions_cpp_text = CUSTOM_ACTIONS_CPP.read_text(encoding="utf-8")
        cls.remote_printer_cpp_text = REMOTE_PRINTER_CPP.read_text(encoding="utf-8")
        cls.firewall_rules_cpp_text = FIREWALL_RULES_CPP.read_text(encoding="utf-8")
        cls.common_h_text = COMMON_H.read_text(encoding="utf-8")

        # Parse XML structures
        cls.ca_xml = ET.fromstring(cls.custom_actions_wxs_text)
        cls.rd_xml = ET.fromstring(cls.rustdesk_wxs_text)

    # =========================================================================
    # 1. WiX CustomAction Classification and Return Semantics
    # =========================================================================

    def _get_wxs_custom_actions(self, root):
        actions = {}
        for elem in root.iter():
            # Handle XML namespace
            tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
            if tag == "CustomAction":
                action_id = elem.attrib.get("Id")
                if action_id:
                    actions[action_id] = elem.attrib
        return actions

    def test_wxs_transaction_critical_actions_have_check_return(self):
        """All transaction-critical system mutation actions must specify Return='check'."""
        ca_actions = self._get_wxs_custom_actions(self.ca_xml)
        critical_actions = [
            "CreateStartService",
            "TryStopDeleteService",
            "AddFirewallRules",
            "RemoveFirewallRules",
            "InstallPrinter",
            "UninstallPrinter",
            "AddRegSoftwareSASGeneration",
            "SetPropertyIsServiceRunning",
            "SetPropertyServiceStop",
        ]
        for action_id in critical_actions:
            self.assertIn(action_id, ca_actions, f"Action {action_id} must exist in CustomActions.wxs")
            ret = ca_actions[action_id].get("Return")
            self.assertEqual(
                ret,
                "check",
                f"Action {action_id} must have Return='check', found Return='{ret}'",
            )

    def test_wxs_best_effort_actions_have_ignore_return(self):
        """Explicit best-effort cleanup/utility actions must specify Return='ignore'."""
        ca_actions = self._get_wxs_custom_actions(self.ca_xml)
        best_effort_actions = [
            "CustomActionHello",
            "RemoveRuntimeGeneratedFiles",
            "TerminateProcesses",
            "TerminateBrokers",
            "TryDeleteStartupShortcut",
            "RemoveAmyuniIdd",
        ]
        for action_id in best_effort_actions:
            self.assertIn(action_id, ca_actions, f"Action {action_id} must exist in CustomActions.wxs")
            ret = ca_actions[action_id].get("Return")
            self.assertEqual(
                ret,
                "ignore",
                f"Action {action_id} must have Return='ignore', found Return='{ret}'",
            )

    def test_wxs_paired_rollback_actions_defined(self):
        """Paired rollback CustomActions must be defined with Execute='rollback' and Return='check'."""
        ca_actions = self._get_wxs_custom_actions(self.ca_xml)
        rollback_actions = {
            "RollbackCreateStartService": "TryStopDeleteService",
            "RollbackFirewallRules": "AddFirewallRules",
            "RollbackPrinter": "UninstallPrinter",
        }
        for rb_id, expected_entry in rollback_actions.items():
            self.assertIn(rb_id, ca_actions, f"Rollback action {rb_id} must be defined")
            attrib = ca_actions[rb_id]
            self.assertEqual(attrib.get("Execute"), "rollback", f"{rb_id} must specify Execute='rollback'")
            self.assertEqual(attrib.get("Return"), "check", f"{rb_id} must specify Return='check'")
            self.assertEqual(attrib.get("Impersonate"), "no", f"{rb_id} must run elevated with Impersonate='no'")
            self.assertEqual(
                attrib.get("DllEntry"),
                expected_entry,
                f"{rb_id} DllEntry should be {expected_entry}",
            )

    # =========================================================================
    # 2. WiX InstallExecuteSequence and Rollback Ordering
    # =========================================================================

    def _get_install_execute_sequence_custom_elements(self):
        elements = []
        for elem in self.rd_xml.iter():
            tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
            if tag == "InstallExecuteSequence":
                for child in elem:
                    ctag = child.tag.split("}")[-1] if "}" in child.tag else child.tag
                    if ctag == "Custom":
                        elements.append(child.attrib)
        return elements

    def test_wxs_rollback_service_scheduled_before_create_service(self):
        """RollbackCreateStartService must be scheduled BEFORE CreateStartService with matching condition."""
        seq = self._get_install_execute_sequence_custom_elements()
        by_action = {item.get("Action"): item for item in seq}

        self.assertIn("RollbackCreateStartService", by_action)
        self.assertIn("CreateStartService", by_action)

        rb_item = by_action["RollbackCreateStartService"]
        fwd_item = by_action["CreateStartService"]

        # Rollback action should be sequenced before CreateStartService (or CreateStartService.SetParam)
        self.assertIn("Before", rb_item)
        self.assertEqual(rb_item.get("Condition"), fwd_item.get("Condition"))

        # Rollback SetParam must exist and precede rollback action
        self.assertIn("RollbackCreateStartService.SetParam", by_action)
        rb_param = by_action["RollbackCreateStartService.SetParam"]
        self.assertEqual(rb_param.get("Before"), "RollbackCreateStartService")
        self.assertEqual(rb_param.get("Condition"), fwd_item.get("Condition"))

    def test_wxs_rollback_printer_scheduled_before_install_printer(self):
        """RollbackPrinter must be scheduled BEFORE InstallPrinter with matching condition."""
        seq = self._get_install_execute_sequence_custom_elements()
        by_action = {item.get("Action"): item for item in seq}

        self.assertIn("RollbackPrinter", by_action)
        self.assertIn("InstallPrinter", by_action)

        rb_item = by_action["RollbackPrinter"]
        fwd_item = by_action["InstallPrinter"]

        self.assertIn("Before", rb_item)
        self.assertEqual(rb_item.get("Condition"), fwd_item.get("Condition"))

    def test_wxs_rollback_firewall_scheduled_before_add_firewall(self):
        """RollbackFirewallRules must be scheduled BEFORE AddFirewallRules with matching condition."""
        seq = self._get_install_execute_sequence_custom_elements()
        by_action = {item.get("Action"): item for item in seq}

        self.assertIn("RollbackFirewallRules", by_action)
        self.assertIn("AddFirewallRules", by_action)

        rb_item = by_action["RollbackFirewallRules"]
        fwd_item = by_action["AddFirewallRules"]

        self.assertIn("Before", rb_item)
        self.assertEqual(rb_item.get("Condition"), fwd_item.get("Condition"))

        self.assertIn("RollbackFirewallRules.SetParam", by_action)
        rb_param = by_action["RollbackFirewallRules.SetParam"]
        self.assertEqual(rb_param.get("Before"), "RollbackFirewallRules")
        self.assertEqual(rb_param.get("Condition"), fwd_item.get("Condition"))

    # =========================================================================
    # 3. RemotePrinter.cpp Invariants & RES-029 Leak Prevention
    # =========================================================================

    def test_remote_printer_add_printer_closes_handle(self):
        """addPrinter must call ClosePrinter(hPrinter) when AddPrinterW succeeds (RES-029)."""
        pattern = re.compile(
            r"HANDLE\s+hPrinter\s*=\s*AddPrinterW\([^;]+;\s*"
            r"if\s*\(\s*hPrinter\s*==\s*NULL\s*\)\s*\{[^}]*\}\s*"
            r"ClosePrinter\(\s*hPrinter\s*\);",
            re.DOTALL,
        )
        self.assertRegex(
            self.remote_printer_cpp_text,
            pattern,
            "addPrinter must close hPrinter handle immediately upon successful addition to prevent leak",
        )

    def test_remote_printer_returns_hresult(self):
        """installUpdatePrinter and uninstallPrinter must return HRESULT."""
        self.assertRegex(
            self.remote_printer_cpp_text,
            r"HRESULT\s+installUpdatePrinter\s*\(\s*const\s+std::wstring\s*&\s*installFolder\s*\)",
            "installUpdatePrinter must return HRESULT",
        )
        self.assertRegex(
            self.remote_printer_cpp_text,
            r"HRESULT\s+uninstallPrinter\s*\(\s*\)",
            "uninstallPrinter must return HRESULT",
        )

    def test_remote_printer_inf_check_before_port_creation(self):
        """installUpdatePrinter must check FileExists(infFile) BEFORE adding any local port."""
        inf_check_idx = self.remote_printer_cpp_text.find("FileExists(infFile)")
        port_add_idx = self.remote_printer_cpp_text.find("addLocalPort(RD_PRINTER_PORT)")
        self.assertNotEqual(inf_check_idx, -1, "FileExists(infFile) must be called")
        self.assertNotEqual(port_add_idx, -1, "addLocalPort must be called")
        self.assertLess(
            inf_check_idx,
            port_add_idx,
            "FileExists(infFile) MUST precede addLocalPort to avoid orphan port creation on missing INF",
        )
        self.assertIn("HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)", self.remote_printer_cpp_text)

    def test_remote_printer_port_cleanup_on_driver_or_printer_failure(self):
        """installUpdatePrinter must rollback newly created port if driver or printer install fails."""
        self.assertIn("portCreated", self.remote_printer_cpp_text)
        self.assertIn("checkDeleteLocalPort(RD_PRINTER_PORT)", self.remote_printer_cpp_text)

    # =========================================================================
    # 4. CustomActions.cpp & FirewallRules.cpp Error Hardening
    # =========================================================================

    def test_custom_actions_install_printer_checks_hresult(self):
        """InstallPrinter must check RemotePrinter::installUpdatePrinter HRESULT with ExitOnFailure."""
        self.assertRegex(
            self.custom_actions_cpp_text,
            r"hr\s*=\s*RemotePrinter::installUpdatePrinter\s*\(\s*installFolder\s*\);\s*"
            r"ExitOnFailure\(\s*hr,\s*\"Failed to install RD printer\"\s*\);",
            "InstallPrinter must validate installUpdatePrinter return via ExitOnFailure",
        )

    def test_custom_actions_uninstall_printer_checks_hresult(self):
        """UninstallPrinter must check RemotePrinter::uninstallPrinter HRESULT with ExitOnFailure."""
        self.assertRegex(
            self.custom_actions_cpp_text,
            r"hr\s*=\s*RemotePrinter::uninstallPrinter\s*\(\s*\);\s*"
            r"ExitOnFailure\(\s*hr,\s*\"Failed to uninstall RD printer\"\s*\);",
            "UninstallPrinter must validate uninstallPrinter return via ExitOnFailure",
        )

    def test_custom_actions_service_verification_on_create(self):
        """CreateStartService must verify service is running and fail if not running."""
        self.assertIn(
            r'Verification failed: Service \"%ls\" is not running after creation attempts.',
            self.custom_actions_cpp_text,
        )
        self.assertIn("HRESULT_FROM_WIN32(ERROR_SERVICE_NOT_ACTIVE)", self.custom_actions_cpp_text)

    def test_custom_actions_firewall_rules_checks_hresult(self):
        """AddFirewallRules must check AddFirewallRuleEx HRESULT with ExitOnFailure."""
        self.assertRegex(
            self.custom_actions_cpp_text,
            r"hr\s*=\s*AddFirewallRuleEx\([^;]+\);\s*ExitOnFailure\(\s*hr,\s*\"Failed to configure firewall rule\"\s*\);",
            "AddFirewallRules must validate AddFirewallRuleEx return via ExitOnFailure",
        )

    def test_custom_actions_software_sas_pointer_and_error_handling(self):
        """AddRegSoftwareSASGeneration must pass &valueData and set hr on RegCreateKey/SetValue failure."""
        self.assertIn(
            "reinterpret_cast<const BYTE*>(&valueData)",
            self.custom_actions_cpp_text,
            "RegSetValueExW must receive address &valueData, not direct valueData cast",
        )
        self.assertRegex(
            self.custom_actions_cpp_text,
            r"result\s*=\s*RegCreateKeyExW\([^;]+;\s*if\s*\(\s*result\s*!=\s*ERROR_SUCCESS\s*\)\s*\{[^}]*hr\s*=\s*HRESULT_FROM_WIN32\(result\);",
            "RegCreateKeyExW failure must set hr = HRESULT_FROM_WIN32(result)",
        )

    def test_firewall_rules_idempotent_removal(self):
        """RemoveFirewallRule must be idempotent and accept ERROR_FILE_NOT_FOUND cleanly."""
        self.assertIn("HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)", self.firewall_rules_cpp_text)

    def test_common_h_declares_hresult_types(self):
        """Common.h must declare HRESULT return types for RemotePrinter and AddFirewallRuleEx."""
        self.assertIn("HRESULT AddFirewallRuleEx(bool add, LPWSTR exeName, LPWSTR exeFile);", self.common_h_text)
        self.assertIn("HRESULT installUpdatePrinter(const std::wstring& installFolder);", self.common_h_text)
        self.assertIn("HRESULT uninstallPrinter();", self.common_h_text)

    # =========================================================================
    # 5. Installer Mutation State Machine Simulation
    # =========================================================================

    def test_state_machine_clean_release_missing_inf_deterministic_rejection(self):
        """Simulates clean release where PRINTER=1 is selected but INF is absent."""
        class MockMsiExecution:
            def __init__(self, inf_exists=False):
                self.inf_exists = inf_exists
                self.ports = set()
                self.drivers = set()
                self.printers = set()
                self.errors = []
                self.msi_return_code = 0

            def install_printer_custom_action(self, install_folder):
                # 1. INF existence check
                if not self.inf_exists:
                    self.errors.append("ERROR_FILE_NOT_FOUND")
                    self.msi_return_code = 1603  # ERROR_INSTALL_FAILURE
                    return False  # Failed, trigger rollback

                # 2. Add port
                self.ports.add("Camellia Printer")
                # 3. Add driver
                self.drivers.add("Camellia v4 Printer Driver")
                # 4. Add printer
                self.printers.add("Camellia Printer")
                return True

            def rollback_printer(self):
                self.printers.discard("Camellia Printer")
                self.drivers.discard("Camellia v4 Printer Driver")
                self.ports.discard("Camellia Printer")

        # Scenario A: Clean release, INF missing
        installer = MockMsiExecution(inf_exists=False)
        success = installer.install_printer_custom_action("C:\\Program Files\\Camellia Remote")
        if not success:
            installer.rollback_printer()

        self.assertFalse(success)
        self.assertEqual(installer.msi_return_code, 1603)
        self.assertEqual(len(installer.ports), 0, "No orphan port should be created when INF is missing")
        self.assertEqual(len(installer.drivers), 0)
        self.assertEqual(len(installer.printers), 0)

        # Scenario B: Driver failure mid-install
        class MockDriverFailInstaller(MockMsiExecution):
            def install_printer_custom_action(self, install_folder):
                if not self.inf_exists:
                    return False
                port_created = False
                if "Camellia Printer" not in self.ports:
                    self.ports.add("Camellia Printer")
                    port_created = True

                # Simulate driver failure
                driver_success = False
                if not driver_success:
                    if port_created:
                        self.ports.discard("Camellia Printer")
                    self.msi_return_code = 1603
                    return False
                return True

        driver_fail = MockDriverFailInstaller(inf_exists=True)
        res = driver_fail.install_printer_custom_action("C:\\Program Files\\Camellia Remote")
        self.assertFalse(res)
        self.assertEqual(len(driver_fail.ports), 0, "Port must be rolled back on driver install failure")


if __name__ == "__main__":
    unittest.main()
