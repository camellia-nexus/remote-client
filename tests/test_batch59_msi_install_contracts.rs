//! Integration and contract tests for Batch 59:
//! INSTALL-001 — MSI system mutation CustomActions error hardening,
//! typed HRESULT returns, paired rollback CustomActions, and orphan port prevention.

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_install001_wxs_action_classification_and_return_semantics() {
    let client_root = get_client_root();
    let ca_wxs_path = client_root
        .join("res")
        .join("msi")
        .join("Package")
        .join("Fragments")
        .join("CustomActions.wxs");

    let content = fs::read_to_string(&ca_wxs_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", ca_wxs_path.display(), e));

    // 1. Transaction-Critical actions must have Return="check"
    let critical_actions = [
        "CreateStartService",
        "TryStopDeleteService",
        "AddFirewallRules",
        "RemoveFirewallRules",
        "InstallPrinter",
        "UninstallPrinter",
        "AddRegSoftwareSASGeneration",
        "SetPropertyIsServiceRunning",
        "SetPropertyServiceStop",
    ];

    for action in &critical_actions {
        let pattern = format!(r#"Id="{action}""#);
        assert!(
            content.contains(&pattern),
            "CustomActions.wxs must contain action {action}"
        );
        // Find line containing the action
        let line = content
            .lines()
            .find(|l| l.contains(&pattern))
            .unwrap_or_else(|| panic!("Cannot locate line for {action}"));
        assert!(
            line.contains(r#"Return="check""#),
            "Critical action {action} must have Return=\"check\", line: {line}"
        );
    }

    // 2. Explicit best-effort actions must have Return="ignore"
    let best_effort_actions = [
        "CustomActionHello",
        "RemoveRuntimeGeneratedFiles",
        "TerminateProcesses",
        "TerminateBrokers",
        "TryDeleteStartupShortcut",
        "RemoveAmyuniIdd",
    ];

    for action in &best_effort_actions {
        let pattern = format!(r#"Id="{action}""#);
        assert!(
            content.contains(&pattern),
            "CustomActions.wxs must contain action {action}"
        );
        let line = content
            .lines()
            .find(|l| l.contains(&pattern))
            .unwrap_or_else(|| panic!("Cannot locate line for {action}"));
        assert!(
            line.contains(r#"Return="ignore""#),
            "Best-effort action {action} must have Return=\"ignore\", line: {line}"
        );
    }

    // 3. Paired rollback actions must be declared
    let rollback_actions = [
        ("RollbackCreateStartService", "TryStopDeleteService"),
        ("RollbackFirewallRules", "AddFirewallRules"),
        ("RollbackPrinter", "UninstallPrinter"),
    ];

    for (rb_id, entry) in &rollback_actions {
        let pattern = format!(r#"Id="{rb_id}""#);
        assert!(
            content.contains(&pattern),
            "CustomActions.wxs must define rollback action {rb_id}"
        );
        let line = content
            .lines()
            .find(|l| l.contains(&pattern))
            .unwrap_or_else(|| panic!("Cannot locate line for {rb_id}"));
        assert!(
            line.contains(r#"Execute="rollback""#),
            "Rollback action {rb_id} must have Execute=\"rollback\", line: {line}"
        );
        assert!(
            line.contains(r#"Return="check""#),
            "Rollback action {rb_id} must have Return=\"check\", line: {line}"
        );
        assert!(
            line.contains(r#"Impersonate="no""#),
            "Rollback action {rb_id} must run elevated with Impersonate=\"no\", line: {line}"
        );
        assert!(
            line.contains(&format!(r#"DllEntry="{entry}""#)),
            "Rollback action {rb_id} must bind to DllEntry=\"{entry}\", line: {line}"
        );
    }
}

#[test]
fn test_install001_wxs_sequencing_and_rollback_pairing() {
    let client_root = get_client_root();
    let rd_wxs_path = client_root
        .join("res")
        .join("msi")
        .join("Package")
        .join("Components")
        .join("RustDesk.wxs");

    let content = fs::read_to_string(&rd_wxs_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", rd_wxs_path.display(), e));

    // Verify SetParam for rollback actions
    assert!(
        content.contains(r#"Id="RollbackCreateStartService.SetParam""#),
        "RustDesk.wxs must define RollbackCreateStartService.SetParam"
    );
    assert!(
        content.contains(r#"Id="RollbackFirewallRules.SetParam""#),
        "RustDesk.wxs must define RollbackFirewallRules.SetParam"
    );

    // Verify InstallExecuteSequence scheduling
    assert!(
        content.contains(
            r#"<Custom Action="RollbackCreateStartService.SetParam" Before="RollbackCreateStartService""#
        ),
        "RollbackCreateStartService.SetParam must precede RollbackCreateStartService"
    );
    assert!(
        content.contains(
            r#"<Custom Action="RollbackCreateStartService" Before="CreateStartService.SetParam""#
        ),
        "RollbackCreateStartService must precede CreateStartService"
    );

    assert!(
        content.contains(r#"<Custom Action="RollbackPrinter" Before="InstallPrinter.SetParam""#),
        "RollbackPrinter must precede InstallPrinter"
    );

    assert!(
        content.contains(
            r#"<Custom Action="RollbackFirewallRules.SetParam" Before="RollbackFirewallRules""#
        ),
        "RollbackFirewallRules.SetParam must precede RollbackFirewallRules"
    );
    assert!(
        content.contains(
            r#"<Custom Action="RollbackFirewallRules" Before="AddFirewallRules.SetParam""#
        ),
        "RollbackFirewallRules must precede AddFirewallRules"
    );
}

#[test]
fn test_install001_cpp_source_hardening_invariants() {
    let client_root = get_client_root();
    let ca_dir = client_root.join("res").join("msi").join("CustomActions");

    let rp_content =
        fs::read_to_string(ca_dir.join("RemotePrinter.cpp")).expect("read RemotePrinter.cpp");
    let ca_content =
        fs::read_to_string(ca_dir.join("CustomActions.cpp")).expect("read CustomActions.cpp");
    let fw_content =
        fs::read_to_string(ca_dir.join("FirewallRules.cpp")).expect("read FirewallRules.cpp");
    let ch_content = fs::read_to_string(ca_dir.join("Common.h")).expect("read Common.h");

    // RES-029: addPrinter must close hPrinter handle immediately
    assert!(
        rp_content.contains("ClosePrinter(hPrinter);"),
        "addPrinter must call ClosePrinter(hPrinter) to resolve RES-029 handle leak"
    );

    // RemotePrinter functions return HRESULT
    assert!(
        rp_content.contains("HRESULT installUpdatePrinter(const std::wstring &installFolder)"),
        "installUpdatePrinter must return HRESULT"
    );
    assert!(
        rp_content.contains("HRESULT uninstallPrinter()"),
        "uninstallPrinter must return HRESULT"
    );
    assert!(
        ch_content.contains("HRESULT installUpdatePrinter(const std::wstring& installFolder);"),
        "Common.h must declare installUpdatePrinter returning HRESULT"
    );
    assert!(
        ch_content.contains("HRESULT uninstallPrinter();"),
        "Common.h must declare uninstallPrinter returning HRESULT"
    );

    // FileExists checked BEFORE adding port
    let inf_check = rp_content
        .find("FileExists(infFile)")
        .expect("INF existence check must be present");
    let port_add = rp_content
        .find("addLocalPort(RD_PRINTER_PORT)")
        .expect("addLocalPort must be present");
    assert!(
        inf_check < port_add,
        "FileExists(infFile) must occur before addLocalPort to prevent orphan port creation"
    );
    assert!(
        rp_content.contains("HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)"),
        "Missing INF must return ERROR_FILE_NOT_FOUND"
    );

    // Port rollback on driver failure
    assert!(
        rp_content.contains("checkDeleteLocalPort(RD_PRINTER_PORT)"),
        "RemotePrinter must clean up port on driver or printer failure"
    );

    // CustomActions.cpp error handling
    assert!(
        ca_content.contains("hr = RemotePrinter::installUpdatePrinter(installFolder);"),
        "InstallPrinter must capture installUpdatePrinter HRESULT"
    );
    assert!(
        ca_content.contains(r#"ExitOnFailure(hr, "Failed to install RD printer");"#),
        "InstallPrinter must ExitOnFailure"
    );
    assert!(
        ca_content.contains("hr = RemotePrinter::uninstallPrinter();"),
        "UninstallPrinter must capture uninstallPrinter HRESULT"
    );
    assert!(
        ca_content.contains(r#"ExitOnFailure(hr, "Failed to uninstall RD printer");"#),
        "UninstallPrinter must ExitOnFailure"
    );

    // Service verification
    assert!(
        ca_content.contains("HRESULT_FROM_WIN32(ERROR_SERVICE_NOT_ACTIVE)"),
        "CreateStartService must fail if service is not running"
    );

    // Firewall check
    assert!(
        ca_content.contains("hr = AddFirewallRuleEx("),
        "AddFirewallRules must capture AddFirewallRuleEx HRESULT"
    );
    assert!(
        ca_content.contains(r#"ExitOnFailure(hr, "Failed to configure firewall rule");"#),
        "AddFirewallRules must ExitOnFailure"
    );
    assert!(
        ch_content.contains("HRESULT AddFirewallRuleEx(bool add, LPWSTR exeName, LPWSTR exeFile);"),
        "Common.h must declare AddFirewallRuleEx returning HRESULT"
    );

    // SoftwareSASGeneration pointer fix
    assert!(
        ca_content.contains("reinterpret_cast<const BYTE*>(&valueData)"),
        "AddRegSoftwareSASGeneration must pass &valueData"
    );
    assert!(
        !ca_content.contains("reinterpret_cast<const BYTE*>(valueData)"),
        "AddRegSoftwareSASGeneration must not cast valueData directly (fixes 998 ERROR_NOACCESS)"
    );

    // FirewallRules idempotent remove
    assert!(
        fw_content.contains("HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)"),
        "RemoveFirewallRule must accept ERROR_FILE_NOT_FOUND as idempotent success"
    );
}

type RollbackAction = Box<dyn Fn(&mut MsiTransactionSimulator)>;

/// Simulated MSI transaction engine testing rollback behavior and state consistency.
#[derive(Default)]
struct MsiTransactionSimulator {
    ports: Vec<String>,
    drivers: Vec<String>,
    printers: Vec<String>,
    services: Vec<String>,
    firewall_rules: Vec<String>,
    rollback_stack: Vec<RollbackAction>,
}

impl MsiTransactionSimulator {
    fn new() -> Self {
        Self::default()
    }

    fn execute_rollback(&mut self) {
        while let Some(rollback_action) = self.rollback_stack.pop() {
            rollback_action(self);
        }
    }

    fn create_start_service(&mut self, name: &str, should_fail: bool) -> Result<(), u32> {
        let name_owned = name.to_string();
        // Push paired rollback action before deferred execution
        self.rollback_stack
            .push(Box::new(move |sim: &mut MsiTransactionSimulator| {
                sim.services.retain(|s| s != &name_owned);
            }));

        if should_fail {
            return Err(1058); // ERROR_SERVICE_DISABLED / NOT_ACTIVE
        }

        self.services.push(name.to_string());
        Ok(())
    }

    fn add_firewall_rule(&mut self, exe: &str, should_fail: bool) -> Result<(), u32> {
        let exe_owned = exe.to_string();
        self.rollback_stack
            .push(Box::new(move |sim: &mut MsiTransactionSimulator| {
                sim.firewall_rules.retain(|r| r != &exe_owned);
            }));

        if should_fail {
            return Err(0x80070005); // E_ACCESSDENIED
        }

        self.firewall_rules.push(exe.to_string());
        Ok(())
    }

    fn install_printer(
        &mut self,
        inf_exists: bool,
        driver_fail: bool,
        printer_fail: bool,
    ) -> Result<(), u32> {
        // Push paired rollback
        self.rollback_stack
            .push(Box::new(|sim: &mut MsiTransactionSimulator| {
                sim.printers.retain(|p| p != "Camellia Printer");
                sim.drivers.retain(|d| d != "Camellia v4 Printer Driver");
                sim.ports.retain(|p| p != "Camellia Printer");
            }));

        // 1. INF existence check MUST precede port creation
        if !inf_exists {
            return Err(2); // ERROR_FILE_NOT_FOUND
        }

        let mut port_created = false;
        if !self.ports.contains(&"Camellia Printer".to_string()) {
            self.ports.push("Camellia Printer".to_string());
            port_created = true;
        }

        if driver_fail {
            if port_created {
                self.ports.retain(|p| p != "Camellia Printer");
            }
            return Err(0x8007000D); // ERROR_INVALID_DATA
        }
        self.drivers.push("Camellia v4 Printer Driver".to_string());

        if printer_fail {
            self.drivers.retain(|d| d != "Camellia v4 Printer Driver");
            if port_created {
                self.ports.retain(|p| p != "Camellia Printer");
            }
            return Err(1797); // ERROR_UNKNOWN_PRINTER_DRIVER
        }
        self.printers.push("Camellia Printer".to_string());

        Ok(())
    }
}

#[test]
fn test_install001_msi_transaction_state_machine_model() {
    // Scenario 1: Clean release without INF triggers deterministic rejection without orphan port
    let mut sim = MsiTransactionSimulator::new();
    let res = sim.install_printer(false, false, false);
    assert_eq!(res, Err(2));
    if res.is_err() {
        sim.execute_rollback();
    }
    assert!(sim.ports.is_empty(), "No orphan port on missing INF");
    assert!(sim.drivers.is_empty());
    assert!(sim.printers.is_empty());

    // Scenario 2: Driver installation fails -> port cleaned up immediately
    let mut sim2 = MsiTransactionSimulator::new();
    let res2 = sim2.install_printer(true, true, false);
    assert!(res2.is_err());
    if res2.is_err() {
        sim2.execute_rollback();
    }
    assert!(
        sim2.ports.is_empty(),
        "Port must not be orphaned on driver failure"
    );
    assert!(sim2.drivers.is_empty());

    // Scenario 3: Printer add fails -> driver and port cleaned up
    let mut sim3 = MsiTransactionSimulator::new();
    let res3 = sim3.install_printer(true, false, true);
    assert!(res3.is_err());
    if res3.is_err() {
        sim3.execute_rollback();
    }
    assert!(sim3.ports.is_empty());
    assert!(sim3.drivers.is_empty());
    assert!(sim3.printers.is_empty());

    // Scenario 4: Successful printer install, then service creation fails -> entire rollback
    let mut sim4 = MsiTransactionSimulator::new();
    assert_eq!(sim4.add_firewall_rule("camellia-remote.exe", false), Ok(()));
    assert_eq!(sim4.install_printer(true, false, false), Ok(()));
    let svc_res = sim4.create_start_service("Camellia Remote", true);
    assert!(svc_res.is_err());
    // MSI triggers reverse rollback
    sim4.execute_rollback();

    assert!(sim4.services.is_empty(), "Service must be rolled back");
    assert!(sim4.printers.is_empty(), "Printer must be rolled back");
    assert!(sim4.drivers.is_empty(), "Driver must be rolled back");
    assert!(sim4.ports.is_empty(), "Port must be rolled back");
    assert!(
        sim4.firewall_rules.is_empty(),
        "Firewall rule must be rolled back"
    );
}
