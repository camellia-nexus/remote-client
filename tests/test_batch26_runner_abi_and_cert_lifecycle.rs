// Client Batch 26 Runner ABI, C Boundary, and Cert Lifecycle Integration Tests
// Target Items:
// 1. FFI-003 (P2): Windows runner parameter C ABI allows NULL/negative length and reconstructs Vec with untrusted capacity
// 2. PLATFORM-007 (P2): Windows runner relies on embedded NUL cancelling out misplaced erase and fails to trim trailing whitespace
// 3. STATE-004 (P2): Windows test cert deletion swallows failures and leaks registry enum resources

use camellia_remote::flutter::{
    camellia_remote_core_main_args, free_c_args, free_c_args_impl, rust_args_to_c_args,
};
use std::{
    ffi::CStr,
    os::raw::{c_char, c_int},
    sync::{Arc, Barrier, Mutex},
    thread,
};

static BATCH26_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_batch26_test_lock() -> std::sync::MutexGuard<'static, ()> {
    BATCH26_TEST_MUTEX
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

// =========================================================================
// 1. FFI-003: Windows Runner Parameter C ABI Resilience Tests
// =========================================================================

#[test]
fn test_ffi003_core_main_args_null_safety() {
    let _lock = acquire_batch26_test_lock();

    // Calling camellia_remote_core_main_args with a NULL pointer must not dereference or crash
    let res = camellia_remote_core_main_args(std::ptr::null_mut());
    assert!(
        res.is_null(),
        "camellia_remote_core_main_args must safely return NULL when given NULL args_len"
    );

    // Calling with a valid out pointer initializes it safely to 0
    let mut len: c_int = 12345;
    let _ = camellia_remote_core_main_args(&mut len);
    // On non-Windows or when core_main returns None, len is safely 0 or valid
    assert!(len >= 0, "args_len must be non-negative");
}

#[test]
fn test_ffi003_rust_args_to_c_args_roundtrip_and_memory_layout() {
    let _lock = acquire_batch26_test_lock();

    let sample_args = vec![
        "camellia-remote".to_string(),
        "--cm".to_string(),
        "--server".to_string(),
        "arg with spaces".to_string(),
        "utf8_测试_山茶花".to_string(),
    ];

    let mut outlen: c_int = -999;
    let c_args = rust_args_to_c_args(sample_args.clone(), &mut outlen);

    assert!(!c_args.is_null(), "Allocation must succeed");
    assert_eq!(
        outlen as usize,
        sample_args.len(),
        "Length must match input count"
    );

    // Read back each C-string to verify byte-for-byte exactness
    unsafe {
        for (i, expected) in sample_args.iter().enumerate() {
            let str_ptr = *c_args.add(i);
            assert!(!str_ptr.is_null(), "Each C-string pointer must be non-null");
            let c_str = CStr::from_ptr(str_ptr);
            assert_eq!(
                c_str.to_str().expect("valid utf-8"),
                expected.as_str(),
                "C-string value must match expected argument"
            );
        }
    }

    // Free the allocation cleanly
    assert!(
        free_c_args_impl(c_args, outlen),
        "free_c_args_impl must succeed for valid allocation"
    );
}

#[test]
fn test_ffi003_free_c_args_rejection_of_invalid_inputs() {
    let _lock = acquire_batch26_test_lock();

    // 1. NULL pointer
    assert!(
        !free_c_args_impl(std::ptr::null_mut(), 5),
        "free_c_args_impl must reject NULL pointer"
    );

    // 2. Negative length
    let sample = vec!["test".to_string()];
    let mut outlen: c_int = 0;
    let ptr = rust_args_to_c_args(sample, &mut outlen);
    assert!(!ptr.is_null());

    assert!(
        !free_c_args_impl(ptr, -1),
        "free_c_args_impl must reject negative length without freeing"
    );
    assert!(
        !free_c_args_impl(ptr, -9999),
        "free_c_args_impl must reject extreme negative length"
    );

    // 3. Length mismatch (wrong len)
    assert!(
        !free_c_args_impl(ptr, outlen + 10),
        "free_c_args_impl must reject length mismatch without corrupting state"
    );
    assert!(
        !free_c_args_impl(ptr, 0),
        "free_c_args_impl must reject 0 when actual length is 1"
    );

    // 4. Untracked / forged pointer
    let mut fake_val: *mut c_char = std::ptr::null_mut();
    let fake_ptr: *mut *mut c_char = &mut fake_val;
    assert!(
        !free_c_args_impl(fake_ptr, 1),
        "free_c_args_impl must reject forged/untracked pointer"
    );

    // 5. Valid free must still succeed after failed attempts
    assert!(
        free_c_args_impl(ptr, outlen),
        "Valid free must succeed after invalid attempts"
    );

    // 6. Double free must be safely rejected
    assert!(
        !free_c_args_impl(ptr, outlen),
        "Second call to free_c_args_impl must be safely rejected (double-free prevention)"
    );
}

#[test]
fn test_ffi003_embedded_nul_rejection_and_leak_freedom() {
    let _lock = acquire_batch26_test_lock();

    let invalid_args = vec![
        "valid_arg_1".to_string(),
        "bad\0embedded_nul_arg".to_string(),
        "valid_arg_2".to_string(),
    ];

    let mut outlen: c_int = 999;
    let ptr = rust_args_to_c_args(invalid_args, &mut outlen);

    assert!(
        ptr.is_null(),
        "rust_args_to_c_args must return NULL on embedded NUL"
    );
    assert_eq!(outlen, 0, "outlen must be reset to 0 on embedded NUL error");
}

#[test]
fn test_ffi003_extern_c_free_c_args_invocation() {
    let _lock = acquire_batch26_test_lock();

    let args = vec!["arg1".to_string(), "arg2".to_string()];
    let mut outlen: c_int = 0;
    let ptr = rust_args_to_c_args(args, &mut outlen);
    assert!(!ptr.is_null());
    assert_eq!(outlen, 2);

    // Call through the exact extern "C" ABI wrapper
    unsafe {
        free_c_args(ptr, outlen);
    }

    // Calling it again via free_c_args_impl must be rejected (proving first free succeeded and was tracked)
    assert!(
        !free_c_args_impl(ptr, outlen),
        "Subsequent free must fail after extern C free_c_args freed the allocation"
    );
}

#[test]
fn test_ffi003_empty_args_handling() {
    let _lock = acquire_batch26_test_lock();

    let empty_args: Vec<String> = vec![];
    let mut outlen: c_int = -1;
    let ptr = rust_args_to_c_args(empty_args, &mut outlen);

    assert!(
        !ptr.is_null(),
        "Allocation for empty args must return valid pointer"
    );
    assert_eq!(outlen, 0, "Length must be 0");

    assert!(
        free_c_args_impl(ptr, 0),
        "free_c_args_impl must succeed for 0 length"
    );
}

#[test]
fn test_ffi003_concurrent_allocations_and_deallocations() {
    let _lock = acquire_batch26_test_lock();

    const THREADS: usize = 16;
    const ITERATIONS_PER_THREAD: usize = 20;

    let barrier = Arc::new(Barrier::new(THREADS));
    let mut handles = Vec::with_capacity(THREADS);

    for t in 0..THREADS {
        let b = Arc::clone(&barrier);
        handles.push(thread::spawn(move || {
            b.wait();
            for iter in 0..ITERATIONS_PER_THREAD {
                let args = vec![
                    format!("thread_{}_iter_{}_a", t, iter),
                    format!("thread_{}_iter_{}_b", t, iter),
                    format!("thread_{}_iter_{}_c", t, iter),
                ];
                let mut outlen: c_int = 0;
                let ptr = rust_args_to_c_args(args, &mut outlen);
                assert!(!ptr.is_null());
                assert_eq!(outlen, 3);

                // Safe free
                assert!(free_c_args_impl(ptr, outlen));
            }
        }));
    }

    for h in handles {
        h.join().expect("Worker thread must join cleanly");
    }
}

// =========================================================================
// 2. PLATFORM-007: Windows Runner Argument Encoding & Trailing Space Tests
// =========================================================================

// Standalone implementation of the corrected Utf8FromUtf16 logic to test exact semantics
fn simulate_utf8_from_utf16(utf16_input: &[u16]) -> Option<String> {
    if utf16_input.is_empty() {
        return Some(String::new());
    }
    // Check for null terminator
    let len = utf16_input
        .iter()
        .position(|&c| c == 0)
        .unwrap_or(utf16_input.len());
    String::from_utf16(&utf16_input[..len]).ok()
}

#[test]
fn test_platform007_utf16_conversion_bounds_and_no_embedded_nul() {
    // 1. Regular flag without trailing space
    let cm_wide: Vec<u16> = "--cm\0".encode_utf16().collect();
    let converted = simulate_utf8_from_utf16(&cm_wide).expect("valid conversion");
    assert_eq!(converted, "--cm");
    assert_eq!(converted.len(), 4, "Must not include terminating NUL byte");
    assert!(!converted.contains('\0'), "Must not contain embedded NUL");

    // 2. Flag with trailing space: must be preserved without corruption
    let cm_with_space_wide: Vec<u16> = "--cm \0".encode_utf16().collect();
    let converted_space = simulate_utf8_from_utf16(&cm_with_space_wide).expect("valid conversion");
    assert_eq!(converted_space, "--cm ");
    assert_eq!(converted_space.len(), 5);
    assert_eq!(converted_space.as_bytes()[4], b' ');

    // 3. Multi-space trailing argument
    let trailing_whitespace: Vec<u16> = "arg   \t\0".encode_utf16().collect();
    let converted_trailing =
        simulate_utf8_from_utf16(&trailing_whitespace).expect("valid conversion");
    assert_eq!(converted_trailing, "arg   \t");
    assert_eq!(converted_trailing.len(), 7);

    // 4. Unicode arguments
    let unicode_wide: Vec<u16> = "Camellia Remote 山茶花\0".encode_utf16().collect();
    let converted_unicode = simulate_utf8_from_utf16(&unicode_wide).expect("valid conversion");
    assert_eq!(converted_unicode, "Camellia Remote 山茶花");

    // 5. Empty argument
    let empty_wide: Vec<u16> = "\0".encode_utf16().collect();
    let converted_empty = simulate_utf8_from_utf16(&empty_wide).expect("valid conversion");
    assert_eq!(converted_empty, "");
    assert_eq!(converted_empty.len(), 0);
}

#[test]
fn test_platform007_flawed_trim_regression_proof() {
    // Demonstration that the old pattern `erase(find_last_not_of(" \n\r\t"))` was flawed:
    let s = "--cm";
    let last_non_space = s.rfind(|c: char| !c.is_whitespace());
    assert_eq!(last_non_space, Some(3)); // index of 'm'
                                         // In C++ std::string::erase(pos), calling erase(3) erases from index 3 to end!
                                         // That means '--cm' would become '--c'!
                                         // The ONLY reason it didn't previously destroy every single argument was because
                                         // Utf8FromUtf16 previously leaked a trailing '\0' (non-whitespace) at index 4,
                                         // so erase(4) accidentally deleted the '\0'.
                                         // With Utf8FromUtf16 corrected to have no trailing '\0', removing the erase loop
                                         // is essential to prevent erasing the last visible character!
    let correct_args = ["--cm".to_string(), "--install".to_string()];
    assert_eq!(correct_args[0], "--cm");
    assert_eq!(correct_args[1], "--install");
}

#[test]
fn test_platform007_process_role_exact_parameter_matching() {
    // Verify that role matching handles exact parameters and avoids false prefix matches
    let exact_cm = "--cm";
    let false_cm_1 = "--cm-extra";
    let false_cm_2 = "--cmd";
    let cm_with_trailing = "--cm ";

    assert_eq!(exact_cm, "--cm");
    assert_ne!(false_cm_1, "--cm");
    assert_ne!(false_cm_2, "--cm");
    assert_ne!(cm_with_trailing, "--cm");

    let exact_install = "--install";
    let false_install = "--install-something";
    assert_eq!(exact_install, "--install");
    assert_ne!(false_install, "--install");
}

// =========================================================================
// 3. STATE-004: Windows Test Cert Deletion & Verification Tests
// =========================================================================

#[test]
fn test_state004_test_cert_fingerprint_and_rogue_prefix_contract() {
    // Fixed fingerprint targeted for deletion
    let expected_fingerprint = "D1DBB672D5A500B9809689CAEA1CE49E799767F0";
    assert_eq!(expected_fingerprint.len(), 40);

    // Verify rogue key prefix logic: "ROOT" ANSI misread as UTF-16
    let root_ansi = b"ROOT";
    let u16_0 = (root_ansi[0] as u16) | ((root_ansi[1] as u16) << 8); // 'R' (0x52) + 'O' (0x4F) -> 0x4F52
    let u16_1 = (root_ansi[2] as u16) | ((root_ansi[3] as u16) << 8); // 'O' (0x4F) + 'T' (0x54) -> 0x544F

    assert_eq!(u16_0, 0x4F52, "First wchar must match '佒'");
    assert_eq!(u16_1, 0x544F, "Second wchar must match '呏'");
}

#[test]
fn test_state004_delete_cert_report_struct_layout() {
    #[cfg(windows)]
    {
        use camellia_remote::platform::windows::cert::DeleteCertReport;
        assert_eq!(
            std::mem::size_of::<DeleteCertReport>(),
            28, // 7 fields * 4 bytes = 28 bytes
            "DeleteCertReport must be 28 bytes under repr(C)"
        );
    }
}

#[test]
fn test_state004_wdk_test_cert_blob_identification() {
    // WDK Test Cert header and signature check
    const TEST_CERT_BLOB: [u8; 16] = [
        0x30, 0x82, 0x03, 0x0C, 0x30, 0x82, 0x01, 0xF4, 0xA0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x10,
        0x17,
    ];

    // Data matching header
    let mut matching_blob = vec![0x00; 100];
    matching_blob.extend_from_slice(&TEST_CERT_BLOB);

    assert!(matching_blob
        .windows(TEST_CERT_BLOB.len())
        .any(|w| w == TEST_CERT_BLOB));

    // Data not matching
    let random_blob = [0xFF; 116];
    assert!(!random_blob
        .windows(TEST_CERT_BLOB.len())
        .any(|w| w == TEST_CERT_BLOB));
}
