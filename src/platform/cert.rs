// Client Windows Certificate Lifecycle & Verification Data Contracts
// Cross-platform typed definitions for STATE-004 verification.

#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct DeleteCertReport {
    pub success: i32,
    pub hives_scanned: i32,
    pub certs_found: i32,
    pub certs_deleted: i32,
    pub rogue_keys_found: i32,
    pub rogue_keys_deleted: i32,
    pub errors_encountered: i32,
}

#[cfg(windows)]
extern "C" {
    fn DeleteRustDeskTestCertsWithReport() -> DeleteCertReport;
    fn DeleteRustDeskTestCertsW() -> std::os::raw::c_int;
}

#[cfg(windows)]
pub fn uninstall_cert_report() -> camellia_remote_protocol::ResultType<DeleteCertReport> {
    let report = unsafe { DeleteRustDeskTestCertsWithReport() };
    if report.success == 0 || report.errors_encountered > 0 {
        camellia_remote_protocol::bail!(
            "Windows test cert uninstallation failed or encountered errors: {:?}",
            report
        );
    }
    Ok(report)
}

#[cfg(windows)]
pub fn uninstall_cert() -> camellia_remote_protocol::ResultType<()> {
    uninstall_cert_report().map(|_| ())
}
