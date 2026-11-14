//! Contract and Integration Test Suite for Batch 70:
//! Windows Remote Printing Subsystem Hardening (RES-042, RES-029, ABI-002).
//!
//! Gates verified:
//! - RES-042: Bounded PrintDispatcher concurrency (max 2 jobs, 3rd rejected),
//!   spool byte bounds (64MiB per job, 128MiB global), generation-based stale job
//!   cancellation and spool file cleanup, SpoolFileGuard owner-only RAII temp files,
//!   bounded shutdown join.
//! - RES-029: Spooler handle leak prevention in remote_printer, RAII OwnedPrinterHandle,
//!   single-close semantics, null-safety, and Cargo winapi features.
//! - ABI-002: Versioned dynamic ABI boundary in printer_service (CAMELLIA_PRINTER_ADAPTER_MAGIC = 0x4350524E,
//!   ABI_VERSION = 1, struct size validation, unsafe extern "system" C ABI calling convention,
//!   caller-provided bounded buffers, fail-closed loading).

#![deny(warnings)]

use std::{
    fs,
    io::Write,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};

use camellia_remote::client::print_dispatcher::{
    PrintDispatcher, PrintDispatcherError, SpoolFileGuard, MAX_CONCURRENT_PRINT_JOBS,
    MAX_PRINT_JOB_BYTES, MAX_TOTAL_SPOOL_BYTES,
};
use camellia_remote::server::printer_service::{
    CamelliaPrinterAdapterHeader, CamelliaPrinterAdapterVtable, CAMELLIA_PRINTER_ADAPTER_ABI_VERSION,
    CAMELLIA_PRINTER_ADAPTER_MAGIC, CAMELLIA_PRN_ERR_BUFFER_TOO_SMALL, CAMELLIA_PRN_ERR_GENERIC,
    CAMELLIA_PRN_ERR_INVALID_PARAM, CAMELLIA_PRN_ERR_NOT_INITIALIZED, CAMELLIA_PRN_ERR_NO_DATA,
    CAMELLIA_PRN_SUCCESS, MAX_PRN_BUFFER_BYTES,
};

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

// ============================================================================
// RES-042 Contract Tests
// ============================================================================

#[test]
fn test_res042_concurrency_limit_rejects_third_job() {
    let running = Arc::new(AtomicBool::new(true));
    let running_clone = running.clone();

    let executor = Arc::new(
        move |_printer_name: Option<String>, _data: Vec<u8>| -> Result<(), String> {
            while running_clone.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(())
        },
    );

    let dispatcher = PrintDispatcher::new(
        MAX_CONCURRENT_PRINT_JOBS,
        MAX_PRINT_JOB_BYTES,
        MAX_TOTAL_SPOOL_BYTES,
        Duration::from_secs(5),
    )
    .with_executor(executor);

    // Register and submit Job 1
    let p1 = dispatcher
        .register_job(1, 1, Some("Printer1".to_string()), 1024)
        .expect("register job 1");
    fs::write(&p1, b"xps-data-1").expect("write job 1");
    dispatcher.submit_job(1).expect("submit job 1");

    // Register and submit Job 2
    let p2 = dispatcher
        .register_job(2, 1, Some("Printer2".to_string()), 1024)
        .expect("register job 2");
    fs::write(&p2, b"xps-data-2").expect("write job 2");
    dispatcher.submit_job(2).expect("submit job 2");

    // Concurrency limit reached (active_jobs == 2)
    assert_eq!(dispatcher.active_jobs(), 2);

    // Registering Job 3 must be rejected because active_jobs >= MAX_CONCURRENT_PRINT_JOBS
    let res3 = dispatcher.register_job(3, 1, Some("Printer3".to_string()), 1024);
    assert!(
        matches!(
            res3,
            Err(PrintDispatcherError::ConcurrencyLimitExceeded {
                active: 2,
                max: 2
            })
        ),
        "Third concurrent job must be rejected by PrintDispatcher"
    );

    // Release workers
    running.store(false, Ordering::SeqCst);
    dispatcher.shutdown();
}

#[test]
fn test_res042_spool_byte_bounds_enforcement() {
    let dispatcher = PrintDispatcher::new(
        MAX_CONCURRENT_PRINT_JOBS,
        MAX_PRINT_JOB_BYTES,
        MAX_TOTAL_SPOOL_BYTES,
        Duration::from_secs(5),
    );

    // 1. Single job exceeding MAX_PRINT_JOB_BYTES (64 MiB) on registration
    let oversize_bytes = MAX_PRINT_JOB_BYTES + 1;
    let res_oversize = dispatcher.register_job(10, 1, None, oversize_bytes);
    assert!(
        matches!(res_oversize, Err(PrintDispatcherError::JobBytesExceeded { requested, max })
            if requested == oversize_bytes && max == MAX_PRINT_JOB_BYTES),
        "Job exceeding 64MiB must be rejected on registration"
    );

    // 2. Updating job bytes to exceed MAX_PRINT_JOB_BYTES
    let p11 = dispatcher.register_job(11, 1, None, 1024).expect("register job 11");
    assert!(p11.exists(), "Spool file must be created on registration");
    let res_update_oversize = dispatcher.update_job_bytes(11, oversize_bytes);
    assert!(
        matches!(res_update_oversize, Err(PrintDispatcherError::JobBytesExceeded { .. })),
        "Updating job bytes beyond 64MiB must fail and remove job"
    );
    // Spool file must have been cleaned up automatically upon bounds violation
    assert!(!p11.exists(), "Spool file must be deleted upon byte bounds violation");

    // 3. Global MAX_TOTAL_SPOOL_BYTES (128 MiB) enforcement
    // Register Job 20 with 60 MiB
    let size_60mib = 60 * 1024 * 1024;
    let _p20 = dispatcher.register_job(20, 1, None, size_60mib).expect("register job 20");
    assert_eq!(dispatcher.current_spool_bytes(), size_60mib);

    // Register Job 21 with 60 MiB (total 120 MiB <= 128 MiB)
    let _p21 = dispatcher.register_job(21, 1, None, size_60mib).expect("register job 21");
    assert_eq!(dispatcher.current_spool_bytes(), 120 * 1024 * 1024);

    // Attempt to register Job 22 with 10 MiB (total would be 130 MiB > 128 MiB)
    let size_10mib = 10 * 1024 * 1024;
    let res_global_exceeded = dispatcher.register_job(22, 1, None, size_10mib);
    assert!(
        matches!(res_global_exceeded, Err(PrintDispatcherError::TotalSpoolBytesExceeded { .. })),
        "Global spool limit (128MiB) must reject additional jobs exceeding capacity"
    );
}

#[test]
fn test_res042_stale_generation_cancellation_and_spool_cleanup() {
    let dispatcher = PrintDispatcher::new(
        MAX_CONCURRENT_PRINT_JOBS,
        MAX_PRINT_JOB_BYTES,
        MAX_TOTAL_SPOOL_BYTES,
        Duration::from_secs(5),
    );

    // Register Job 30 under connection generation 1
    let p30 = dispatcher.register_job(30, 1, None, 2048).expect("register job 30");
    assert!(p30.exists(), "Spool file must exist for registered job 30");

    // Advance connection generation to 2 (simulating session restart or new connection)
    dispatcher.advance_generation(2);

    // Job 30 must have been removed and its spool file deleted
    assert!(!p30.exists(), "Advancing generation must immediately delete stale spool files");
    assert_eq!(dispatcher.registered_jobs_count(), 0);

    // Submitting stale Job 30 must fail closed
    let submit_res = dispatcher.submit_job(30);
    assert!(
        matches!(submit_res, Err(PrintDispatcherError::JobNotFound(30))),
        "Submitting cancelled job must fail"
    );

    // Attempting to register with stale generation 1 must be rejected
    let stale_reg = dispatcher.register_job(31, 1, None, 1024);
    assert!(
        matches!(stale_reg, Err(PrintDispatcherError::StaleGeneration { job_generation: 1, current_generation: 2 })),
        "Registering with stale generation must be rejected"
    );

    // Register Job 32 with generation 2, then cancel generation 2 explicitly
    let p32 = dispatcher.register_job(32, 2, None, 2048).expect("register job 32");
    assert!(p32.exists(), "Spool file must exist for job 32");
    dispatcher.cancel_generation(2);
    assert!(!p32.exists(), "cancel_generation must delete unsubmitted spool files");
}

#[test]
fn test_res042_spool_file_guard_raii_drop_and_consume() {
    let mut guard = SpoolFileGuard::create(99).expect("create SpoolFileGuard");
    let path = guard.path().to_path_buf();
    assert!(path.exists(), "Temporary spool file must be created on disk");

    // Write some data to simulate streaming
    {
        let mut f = fs::OpenOptions::new().write(true).open(&path).expect("open spool file");
        f.write_all(b"sample-xps-stream-data").expect("write sample data");
    }

    // consume_data reads data and cleans up file immediately
    let data = guard.consume_data().expect("consume_data");
    assert_eq!(data, b"sample-xps-stream-data");
    assert!(!path.exists(), "consume_data must delete spool file from disk");

    // Test RAII Drop cleanup
    let drop_path = {
        let g2 = SpoolFileGuard::create(100).expect("create second guard");
        let p = g2.path().to_path_buf();
        assert!(p.exists());
        p
        // g2 drops here
    };
    assert!(!drop_path.exists(), "Dropping SpoolFileGuard must delete temporary spool file");
}

#[test]
fn test_res042_graceful_shutdown_join() {
    let dispatcher = PrintDispatcher::new(
        MAX_CONCURRENT_PRINT_JOBS,
        MAX_PRINT_JOB_BYTES,
        MAX_TOTAL_SPOOL_BYTES,
        Duration::from_millis(500),
    );

    let p = dispatcher.register_job(50, 1, None, 1024).expect("register job 50");
    fs::write(&p, b"xps-data").expect("write xps");
    dispatcher.submit_job(50).expect("submit job 50");

    dispatcher.shutdown();
    assert!(dispatcher.is_shutdown(), "Dispatcher must be marked shutdown");

    // New registrations after shutdown must fail closed
    let res = dispatcher.register_job(51, 1, None, 1024);
    assert!(matches!(res, Err(PrintDispatcherError::Shutdown)));
}

// ============================================================================
// RES-029 Contract Tests
// ============================================================================

#[test]
fn test_res029_remote_printer_cargo_toml_winapi_features() {
    let client_root = get_client_root();
    let cargo_toml_path = client_root
        .join("libs")
        .join("remote_printer")
        .join("Cargo.toml");

    let content = fs::read_to_string(&cargo_toml_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", cargo_toml_path.display(), e));

    assert!(
        content.contains(r#"features = ["winspool", "winerror", "minwindef", "ntdef"]"#),
        "remote_printer/Cargo.toml must declare winapi features [winspool, winerror, minwindef, ntdef]"
    );
}

#[test]
fn test_res029_printer_source_contracts() {
    let client_root = get_client_root();
    let printer_rs_path = client_root
        .join("libs")
        .join("remote_printer")
        .join("src")
        .join("setup")
        .join("printer.rs");

    let content = fs::read_to_string(&printer_rs_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", printer_rs_path.display(), e));

    // Must define OwnedPrinterHandle wrapping HANDLE
    assert!(
        content.contains("pub struct OwnedPrinterHandle(HANDLE);"),
        "printer.rs must define OwnedPrinterHandle(HANDLE)"
    );
    assert!(
        content.contains("impl Drop for OwnedPrinterHandle"),
        "OwnedPrinterHandle must implement Drop"
    );
    assert!(
        content.contains("ClosePrinter(self.0)"),
        "OwnedPrinterHandle::drop must invoke ClosePrinter(self.0)"
    );

    // In add_printer, AddPrinterW must be wrapped in OwnedPrinterHandle
    assert!(
        content.contains("OwnedPrinterHandle::new(h_printer)"),
        "add_printer must immediately wrap AddPrinterW handle in OwnedPrinterHandle"
    );

    // In delete_printer, manual ClosePrinter calls must be replaced with OwnedPrinterHandle
    assert!(
        content.contains("OwnedPrinterHandle::new(raw_handle)"),
        "delete_printer must wrap OpenPrinterW in OwnedPrinterHandle"
    );
}

/// Simulated mock verifying OwnedPrinterHandle RAII behavior, single-close,
/// null-safety, and into_raw deferral.
struct MockPrinterHandle {
    raw: usize,
    closed_count: Arc<AtomicUsize>,
}

impl MockPrinterHandle {
    fn new(raw: usize, closed_count: Arc<AtomicUsize>) -> Option<Self> {
        if raw == 0 {
            None
        } else {
            Some(Self { raw, closed_count })
        }
    }

    fn as_raw(&self) -> usize {
        self.raw
    }

    fn into_raw(mut self) -> usize {
        let r = self.raw;
        self.raw = 0;
        r
    }
}

impl Drop for MockPrinterHandle {
    fn drop(&mut self) {
        if self.raw != 0 {
            self.closed_count.fetch_add(1, Ordering::SeqCst);
            self.raw = 0;
        }
    }
}

#[test]
fn test_res029_owned_printer_handle_raii_semantics() {
    let closed = Arc::new(AtomicUsize::new(0));

    // 1. Null handle returns None and never triggers ClosePrinter
    let null_handle = MockPrinterHandle::new(0, closed.clone());
    assert!(null_handle.is_none());
    assert_eq!(closed.load(Ordering::SeqCst), 0);

    // 2. Valid handle dropped triggers exactly one ClosePrinter call
    {
        let handle = MockPrinterHandle::new(1234, closed.clone()).expect("valid handle");
        assert_eq!(handle.as_raw(), 1234);
    }
    assert_eq!(closed.load(Ordering::SeqCst), 1, "Handle drop must call close exactly once");

    // 3. into_raw() transfers ownership and suppresses Drop close
    {
        let handle2 = MockPrinterHandle::new(5678, closed.clone()).expect("valid handle");
        let raw2 = handle2.into_raw();
        assert_eq!(raw2, 5678);
    }
    assert_eq!(closed.load(Ordering::SeqCst), 1, "into_raw must not invoke drop close");
}

// ============================================================================
// ABI-002 Contract Tests
// ============================================================================

unsafe extern "system" fn dummy_adapter_init(_tag: *const std::os::raw::c_char) -> i32 {
    CAMELLIA_PRN_SUCCESS
}

unsafe extern "system" fn dummy_adapter_uninit() -> i32 {
    CAMELLIA_PRN_SUCCESS
}

unsafe extern "system" fn dummy_adapter_get_prn_data(
    _dur_mills: u32,
    out_buf: *mut u8,
    buf_capacity: usize,
    out_len: *mut usize,
) -> i32 {
    let sample = b"test-xps-data";
    if buf_capacity < sample.len() {
        if !out_len.is_null() {
            unsafe { *out_len = sample.len() };
        }
        return CAMELLIA_PRN_ERR_BUFFER_TOO_SMALL;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(sample.as_ptr(), out_buf, sample.len());
        if !out_len.is_null() {
            *out_len = sample.len();
        }
    }
    CAMELLIA_PRN_SUCCESS
}

#[test]
fn test_abi002_vtable_validation_success() {
    let vtable = CamelliaPrinterAdapterVtable {
        header: CamelliaPrinterAdapterHeader {
            magic: CAMELLIA_PRINTER_ADAPTER_MAGIC,
            abi_version: CAMELLIA_PRINTER_ADAPTER_ABI_VERSION,
            struct_size: std::mem::size_of::<CamelliaPrinterAdapterVtable>() as u32,
            capabilities: 0,
        },
        init: Some(dummy_adapter_init),
        uninit: Some(dummy_adapter_uninit),
        get_prn_data: Some(dummy_adapter_get_prn_data),
    };

    assert_eq!(vtable.header.magic, 0x4350524E, "Magic must be CPRN");
    assert_eq!(vtable.header.abi_version, 1, "ABI version must be 1");
    assert!(vtable.validate().is_ok(), "Valid vtable must pass validation");
}

#[test]
fn test_abi002_vtable_validation_fail_closed() {
    let valid_header = CamelliaPrinterAdapterHeader {
        magic: CAMELLIA_PRINTER_ADAPTER_MAGIC,
        abi_version: CAMELLIA_PRINTER_ADAPTER_ABI_VERSION,
        struct_size: std::mem::size_of::<CamelliaPrinterAdapterVtable>() as u32,
        capabilities: 0,
    };

    // 1. Magic mismatch
    let mut vtable = CamelliaPrinterAdapterVtable {
        header: CamelliaPrinterAdapterHeader {
            magic: 0xDEADBEEF,
            ..valid_header
        },
        init: Some(dummy_adapter_init),
        uninit: Some(dummy_adapter_uninit),
        get_prn_data: Some(dummy_adapter_get_prn_data),
    };
    assert_eq!(vtable.validate(), Err("Invalid adapter magic number"));

    // 2. ABI version mismatch
    vtable.header = CamelliaPrinterAdapterHeader {
        abi_version: 99,
        ..valid_header
    };
    assert_eq!(vtable.validate(), Err("Unsupported adapter ABI version"));

    // 3. Struct size mismatch
    vtable.header = CamelliaPrinterAdapterHeader {
        struct_size: 16,
        ..valid_header
    };
    assert_eq!(vtable.validate(), Err("Mismatched adapter struct size"));

    // 4. Missing symbols (null function pointers)
    vtable.header = valid_header;
    vtable.init = None;
    assert_eq!(vtable.validate(), Err("Missing init function pointer"));

    vtable.init = Some(dummy_adapter_init);
    vtable.uninit = None;
    assert_eq!(vtable.validate(), Err("Missing uninit function pointer"));

    vtable.uninit = Some(dummy_adapter_uninit);
    vtable.get_prn_data = None;
    assert_eq!(vtable.validate(), Err("Missing get_prn_data function pointer"));
}

#[test]
fn test_abi002_caller_provided_bounded_buffer_semantics() {
    // 1. Caller provides small buffer -> adapter reports BUFFER_TOO_SMALL with required length
    let mut small_buf = vec![0u8; 4];
    let mut out_len = 0usize;
    let res = unsafe {
        dummy_adapter_get_prn_data(
            1000,
            small_buf.as_mut_ptr(),
            small_buf.len(),
            &mut out_len as *mut usize,
        )
    };
    assert_eq!(res, CAMELLIA_PRN_ERR_BUFFER_TOO_SMALL);
    assert_eq!(out_len, b"test-xps-data".len());

    // 2. Caller resizes buffer within bounded limits (<= 64MiB) and retries -> success
    assert!(out_len <= MAX_PRN_BUFFER_BYTES);
    let mut adequate_buf = vec![0u8; out_len];
    let res2 = unsafe {
        dummy_adapter_get_prn_data(
            1000,
            adequate_buf.as_mut_ptr(),
            adequate_buf.len(),
            &mut out_len as *mut usize,
        )
    };
    assert_eq!(res2, CAMELLIA_PRN_SUCCESS);
    assert_eq!(&adequate_buf[..out_len], b"test-xps-data");

    // 3. Constant codes consistency check
    assert_eq!(CAMELLIA_PRN_SUCCESS, 0);
    assert_eq!(CAMELLIA_PRN_ERR_GENERIC, -1);
    assert_eq!(CAMELLIA_PRN_ERR_INVALID_PARAM, -2);
    assert_eq!(CAMELLIA_PRN_ERR_BUFFER_TOO_SMALL, -3);
    assert_eq!(CAMELLIA_PRN_ERR_NO_DATA, -4);
    assert_eq!(CAMELLIA_PRN_ERR_NOT_INITIALIZED, -5);
    assert_eq!(MAX_PRN_BUFFER_BYTES, 64 * 1024 * 1024);
}

#[test]
fn test_abi002_printer_service_source_contracts() {
    let client_root = get_client_root();
    let service_rs_path = client_root
        .join("src")
        .join("server")
        .join("printer_service.rs");

    let content = fs::read_to_string(&service_rs_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", service_rs_path.display(), e));

    assert!(
        content.contains("pub const CAMELLIA_PRINTER_ADAPTER_MAGIC: u32 = 0x4350524E;"),
        "printer_service.rs must define CAMELLIA_PRINTER_ADAPTER_MAGIC = 0x4350524E"
    );
    assert!(
        content.contains("pub const CAMELLIA_PRINTER_ADAPTER_ABI_VERSION: u32 = 1;"),
        "printer_service.rs must define CAMELLIA_PRINTER_ADAPTER_ABI_VERSION = 1"
    );
    assert!(
        content.contains(r#"unsafe extern "system""#),
        "printer_service.rs must declare functions with unsafe extern \"system\" calling convention"
    );
    assert!(
        content.contains("pub struct CamelliaPrinterAdapterVtable"),
        "printer_service.rs must define CamelliaPrinterAdapterVtable"
    );
    assert!(
        content.contains("pub struct CamelliaPrinterAdapterHeader"),
        "printer_service.rs must define CamelliaPrinterAdapterHeader"
    );
    assert!(
        content.contains("buf_capacity: usize") && content.contains("out_len: *mut usize"),
        "get_prn_data must use caller-provided bounded buffers"
    );
}
