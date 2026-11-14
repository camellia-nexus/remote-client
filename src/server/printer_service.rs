//! Windows Remote Printer Driver Adapter Dynamic ABI Boundary (ABI-002).
//!
//! Enforces:
//! - Magic number validation: `CAMELLIA_PRINTER_ADAPTER_MAGIC = 0x4350524E` ("CPRN")
//! - ABI version validation: `CAMELLIA_PRINTER_ADAPTER_ABI_VERSION = 1`
//! - Struct size validation
//! - C calling convention: `unsafe extern "system"`
//! - Host caller-provided bounded buffers up to `MAX_PRN_BUFFER_BYTES = 64 * 1024 * 1024`
//! - Fail-closed initialization and dynamic loading

use super::service::{EmptyExtraFieldService, GenericService, Service};
use camellia_remote_protocol::{bail, log, ResultType};
use dlopen::symbor::Library;
use std::{
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

pub const NAME: &'static str = "remote-printer";

const LIB_NAME_PRINTER_DRIVER_ADAPTER: &str = "printer_driver_adapter";

// "CPRN"
pub const CAMELLIA_PRINTER_ADAPTER_MAGIC: u32 = 0x4350524E;
pub const CAMELLIA_PRINTER_ADAPTER_ABI_VERSION: u32 = 1;

pub const CAMELLIA_PRN_SUCCESS: i32 = 0;
pub const CAMELLIA_PRN_ERR_GENERIC: i32 = -1;
pub const CAMELLIA_PRN_ERR_INVALID_PARAM: i32 = -2;
pub const CAMELLIA_PRN_ERR_BUFFER_TOO_SMALL: i32 = -3;
pub const CAMELLIA_PRN_ERR_NO_DATA: i32 = -4;
pub const CAMELLIA_PRN_ERR_NOT_INITIALIZED: i32 = -5;

pub const MAX_PRN_BUFFER_BYTES: usize = 64 * 1024 * 1024; // 64 MiB
pub const INITIAL_PRN_BUFFER_BYTES: usize = 64 * 1024; // 64 KiB

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CamelliaPrinterAdapterHeader {
    pub magic: u32,
    pub abi_version: u32,
    pub struct_size: u32,
    pub capabilities: u32,
}

impl Default for CamelliaPrinterAdapterHeader {
    fn default() -> Self {
        Self {
            magic: CAMELLIA_PRINTER_ADAPTER_MAGIC,
            abi_version: CAMELLIA_PRINTER_ADAPTER_ABI_VERSION,
            struct_size: std::mem::size_of::<CamelliaPrinterAdapterVtable>() as u32,
            capabilities: 0,
        }
    }
}

pub type AdapterInitFn = unsafe extern "system" fn(tag_name: *const std::os::raw::c_char) -> i32;
pub type AdapterUninitFn = unsafe extern "system" fn() -> i32;
pub type AdapterGetPrnDataFn = unsafe extern "system" fn(
    dur_mills: u32,
    out_buf: *mut u8,
    buf_capacity: usize,
    out_len: *mut usize,
) -> i32;

#[repr(C)]
pub struct CamelliaPrinterAdapterVtable {
    pub header: CamelliaPrinterAdapterHeader,
    pub init: Option<AdapterInitFn>,
    pub uninit: Option<AdapterUninitFn>,
    pub get_prn_data: Option<AdapterGetPrnDataFn>,
}

impl CamelliaPrinterAdapterVtable {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.header.magic != CAMELLIA_PRINTER_ADAPTER_MAGIC {
            return Err("Invalid adapter magic number");
        }
        if self.header.abi_version != CAMELLIA_PRINTER_ADAPTER_ABI_VERSION {
            return Err("Unsupported adapter ABI version");
        }
        if self.header.struct_size != std::mem::size_of::<CamelliaPrinterAdapterVtable>() as u32 {
            return Err("Mismatched adapter struct size");
        }
        if self.init.is_none() {
            return Err("Missing init function pointer");
        }
        if self.uninit.is_none() {
            return Err("Missing uninit function pointer");
        }
        if self.get_prn_data.is_none() {
            return Err("Missing get_prn_data function pointer");
        }
        Ok(())
    }
}

pub type GetPrinterAdapterVtableFn =
    unsafe extern "system" fn(vtable: *mut CamelliaPrinterAdapterVtable) -> i32;

pub struct LibWrapper {
    _lib: Option<Library>,
    vtable: Option<CamelliaPrinterAdapterVtable>,
}

impl LibWrapper {
    pub fn new() -> Self {
        let lib_name = match get_lib_name() {
            Ok(name) => name,
            Err(e) => {
                log::warn!("Failed to get printer adapter lib name: {}", e);
                return Self {
                    _lib: None,
                    vtable: None,
                };
            }
        };
        let lib = match Library::open(&lib_name) {
            Ok(lib) => lib,
            Err(e) => {
                log::warn!("Failed to load printer adapter library {}: {}", &lib_name, e);
                return Self {
                    _lib: None,
                    vtable: None,
                };
            }
        };

        let mut vtable = CamelliaPrinterAdapterVtable {
            header: CamelliaPrinterAdapterHeader::default(),
            init: None,
            uninit: None,
            get_prn_data: None,
        };

        let loaded = unsafe {
            if let Ok(sym) =
                lib.symbol::<GetPrinterAdapterVtableFn>("camellia_get_printer_adapter_vtable")
            {
                sym(&mut vtable) == CAMELLIA_PRN_SUCCESS
            } else if let Ok(sym) =
                lib.symbol::<GetPrinterAdapterVtableFn>("get_printer_adapter_vtable")
            {
                sym(&mut vtable) == CAMELLIA_PRN_SUCCESS
            } else {
                let init = lib.symbol::<AdapterInitFn>("init").ok().map(|s| *s);
                let uninit = lib.symbol::<AdapterUninitFn>("uninit").ok().map(|s| *s);
                let get_prn_data = lib
                    .symbol::<AdapterGetPrnDataFn>("get_prn_data")
                    .ok()
                    .map(|s| *s);
                vtable.init = init;
                vtable.uninit = uninit;
                vtable.get_prn_data = get_prn_data;
                true
            }
        };

        if !loaded {
            log::warn!("Printer adapter vtable loader returned failure");
            return Self {
                _lib: None,
                vtable: None,
            };
        }

        if let Err(e) = vtable.validate() {
            log::warn!("Printer adapter vtable validation failed: {}", e);
            return Self {
                _lib: None,
                vtable: None,
            };
        }

        Self {
            _lib: Some(lib),
            vtable: Some(vtable),
        }
    }

    pub fn vtable(&self) -> Option<&CamelliaPrinterAdapterVtable> {
        self.vtable.as_ref()
    }
}

impl Default for LibWrapper {
    fn default() -> Self {
        Self::new()
    }
}

lazy_static::lazy_static! {
    static ref LIB_WRAPPER: Arc<Mutex<LibWrapper>> = Default::default();
}

fn get_lib_name() -> ResultType<String> {
    let exe_file = std::env::current_exe()?;
    if let Some(cur_dir) = exe_file.parent() {
        let dll_name = format!("{}.dll", LIB_NAME_PRINTER_DRIVER_ADAPTER);
        let full_path = cur_dir.join(dll_name);
        if !full_path.exists() {
            bail!("{} not found", full_path.to_string_lossy().as_ref());
        } else {
            Ok(full_path.to_string_lossy().into_owned())
        }
    } else {
        bail!(
            "Invalid exe parent for {}",
            exe_file.to_string_lossy().as_ref()
        );
    }
}

pub fn init(app_name: &str) -> ResultType<()> {
    let lib_wrapper = LIB_WRAPPER.lock().unwrap();
    let Some(vtable) = lib_wrapper.vtable.as_ref() else {
        bail!("Printer adapter not loaded or invalid ABI");
    };
    let Some(fn_init) = vtable.init else {
        bail!("Missing init function in vtable");
    };

    let tag_name = std::ffi::CString::new(app_name)?;
    let ret = unsafe { fn_init(tag_name.as_ptr()) };
    if ret != CAMELLIA_PRN_SUCCESS {
        bail!("Failed to init printer driver, code: {}", ret);
    }
    Ok(())
}

pub fn uninit() {
    let lib_wrapper = LIB_WRAPPER.lock().unwrap();
    if let Some(vtable) = lib_wrapper.vtable.as_ref() {
        if let Some(fn_uninit) = vtable.uninit {
            unsafe {
                let _ = fn_uninit();
            }
        }
    }
}

pub fn get_prn_data(dur_mills: u32) -> ResultType<Vec<u8>> {
    let lib_wrapper = LIB_WRAPPER.lock().unwrap();
    let Some(vtable) = lib_wrapper.vtable.as_ref() else {
        bail!("Printer adapter not loaded or invalid ABI");
    };
    let Some(fn_get_prn_data) = vtable.get_prn_data else {
        bail!("Missing get_prn_data function in vtable");
    };

    let mut buf = vec![0u8; INITIAL_PRN_BUFFER_BYTES];
    let mut out_len = 0usize;
    let mut ret = unsafe {
        fn_get_prn_data(
            dur_mills,
            buf.as_mut_ptr(),
            buf.len(),
            &mut out_len as *mut usize,
        )
    };

    if ret == CAMELLIA_PRN_ERR_BUFFER_TOO_SMALL {
        if out_len > MAX_PRN_BUFFER_BYTES {
            bail!(
                "Printer adapter requested buffer {} exceeds maximum allowed {}",
                out_len,
                MAX_PRN_BUFFER_BYTES
            );
        }
        buf.resize(out_len, 0);
        ret = unsafe {
            fn_get_prn_data(
                dur_mills,
                buf.as_mut_ptr(),
                buf.len(),
                &mut out_len as *mut usize,
            )
        };
    }

    if ret == CAMELLIA_PRN_ERR_NO_DATA {
        return Ok(Vec::new());
    }

    if ret != CAMELLIA_PRN_SUCCESS {
        bail!("Printer adapter get_prn_data error code: {}", ret);
    }

    if out_len == 0 {
        return Ok(Vec::new());
    }

    if out_len > buf.len() {
        bail!(
            "Printer adapter out_len {} exceeds buffer size {}",
            out_len,
            buf.len()
        );
    }

    buf.truncate(out_len);
    Ok(buf)
}

pub fn new(name: String) -> GenericService {
    let svc = EmptyExtraFieldService::new(name, false);
    GenericService::run(&svc.clone(), run);
    svc.sp
}

fn run(sp: EmptyExtraFieldService) -> ResultType<()> {
    while sp.ok() {
        let bytes = get_prn_data(1000)?;
        if !bytes.is_empty() {
            log::info!("Got prn data, data len: {}", bytes.len());
            #[cfg(all(target_os = "windows", feature = "flutter"))]
            crate::server::on_printer_data(bytes);
            #[cfg(not(all(target_os = "windows", feature = "flutter")))]
            let _ = bytes;
        }
        thread::sleep(Duration::from_millis(300));
    }
    Ok(())
}
