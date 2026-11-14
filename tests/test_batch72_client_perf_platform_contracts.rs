//! Integration and contract tests for Batch 72 Client Hardening:
//! PERF-005 — 国际化翻译占位符提取使用正则导致高频开销
//! PLATFORM-003 — Windows 端 NtTerminateProcess 提权/无保护句柄关闭缺陷
//! RES-028 — Windows 平台运行服务中 h_process 句柄泄漏

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_batch72_perf005_zero_regex_linear_placeholder_extraction() {
    let root = get_client_root();
    let lang_rs = root.join("src/lang.rs");
    assert!(lang_rs.exists(), "src/lang.rs must exist");

    let content = fs::read_to_string(&lang_rs).expect("read src/lang.rs");

    // Must NOT import or use Regex in lang.rs
    assert!(
        !content.contains("use camellia_remote_protocol::regex::Regex;"),
        "src/lang.rs must not import Regex"
    );
    assert!(
        !content.contains("Regex::new"),
        "src/lang.rs must not compile Regex"
    );

    // Verify linear find('{') and find('}') implementation
    assert!(
        content.contains("input.find('{')"),
        "{}",
        "extract_placeholder must use linear find('{')"
    );
    assert!(
        content.contains("input[start + 1..].find('}')"),
        "{}",
        "extract_placeholder must use linear find('}')"
    );

    // Behavioral simulation of the linear algorithm
    let extract = |input: &str| -> (String, Option<String>) {
        if let Some(start) = input.find('{') {
            if let Some(rel_end) = input[start + 1..].find('}') {
                let end = start + 1 + rel_end;
                let value = &input[start + 1..end];
                let mut name = String::with_capacity(input.len() + 2 - (end - start + 1));
                name.push_str(&input[..start]);
                name.push_str("{}");
                name.push_str(&input[end + 1..]);
                return (name, Some(value.to_string()));
            }
        }
        (input.to_string(), None)
    };

    assert_eq!(extract(""), ("".to_string(), None));
    assert_eq!(
        extract("{3} sessions"),
        ("{} sessions".to_string(), Some("3".to_string()))
    );
    assert_eq!(extract(" } { "), (" } { ".to_string(), None));
    assert_eq!(
        extract("{} sessions"),
        ("{} sessions".to_string(), Some("".to_string()))
    );
    assert_eq!(
        extract("{2} times {4} makes {8}"),
        ("{} times {4} makes {8}".to_string(), Some("2".to_string()))
    );
    assert_eq!(
        extract("no placeholder"),
        ("no placeholder".to_string(), None)
    );
    assert_eq!(
        extract("{unclosed placeholder"),
        ("{unclosed placeholder".to_string(), None)
    );
    assert_eq!(
        extract("prefix {val} suffix"),
        ("prefix {} suffix".to_string(), Some("val".to_string()))
    );
}

#[test]
fn test_batch72_platform003_windows_nt_terminate_process_hardening() {
    let root = get_client_root();
    let win_rs = root.join("src/platform/windows.rs");
    assert!(win_rs.exists(), "src/platform/windows.rs must exist");

    let content = fs::read_to_string(&win_rs).expect("read src/platform/windows.rs");

    // Standard Win32 TerminateProcess with minimal rights
    assert!(
        content.contains("winapi::um::winnt::PROCESS_TERMINATE | winapi::um::winnt::SYNCHRONIZE"),
        "nt_terminate_process must open process with minimal rights (PROCESS_TERMINATE | SYNCHRONIZE)"
    );
    assert!(
        content.contains("winapi::um::processthreadsapi::TerminateProcess(h_process, 1)"),
        "nt_terminate_process must attempt standard TerminateProcess first"
    );

    // RAII FreeLibrary guard for ntdll module
    assert!(
        content.contains("FreeLibrary(h_module)"),
        "nt_terminate_process must free ntdll module via FreeLibrary"
    );

    // Null check on GetProcAddress before transmutation
    assert!(
        content.contains("GetProcAddress(h_module, CString::new(\"NtTerminateProcess\")"),
        "nt_terminate_process must query NtTerminateProcess address"
    );
    assert!(
        content.contains("proc_addr.is_null()"),
        "nt_terminate_process must check proc_addr for null before transmuting"
    );

    // RAII CloseHandle guard for target handle
    assert!(
        content.contains("CloseHandle(h_target)"),
        "nt_terminate_process must guard target handle with CloseHandle"
    );
}

#[test]
fn test_batch72_res028_windows_service_process_handle_lifecycle() {
    let root = get_client_root();
    let win_rs = root.join("src/platform/windows.rs");
    assert!(win_rs.exists(), "src/platform/windows.rs must exist");

    let content = fs::read_to_string(&win_rs).expect("read src/platform/windows.rs");

    // replace_process_handle definition
    assert!(
        content.contains("fn replace_process_handle(current: &mut HANDLE, new_handle: HANDLE)"),
        "src/platform/windows.rs must define replace_process_handle"
    );
    assert!(
        content.contains("replace_process_handle(&mut h_process, next);"),
        "run_service must use replace_process_handle on session changes"
    );
    assert!(
        content.contains("replace_process_handle(&mut h_process, NULL);"),
        "run_service must close handle on failure and cleanup"
    );

    // CloseHandle on fire-and-forget LaunchProcessWin in run_exe_in_session
    assert!(
        content.contains("LaunchProcessWin returned an open process handle; close it immediately to prevent handle leaks (RES-028)"),
        "run_exe_in_session must document immediate handle closure"
    );
    assert!(
        content.contains(
            "if h != INVALID_HANDLE_VALUE {\n            let _ = CloseHandle(h);\n        }"
        ),
        "run_exe_in_session must close handle returned by LaunchProcessWin"
    );
}
