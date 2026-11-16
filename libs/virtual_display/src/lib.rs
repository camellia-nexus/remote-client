use camellia_remote_protocol::{anyhow, bail, log, ResultType};
use dlopen::symbor::Library;
use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
};

const LIB_NAME_VIRTUAL_DISPLAY: &str = "dylib_virtual_display";

// ABI-001: Versioned C-ABI handshake constants
pub const VIRTUAL_DISPLAY_ABI_MAGIC: u32 = 0x56495254; // 'V', 'I', 'R', 'T'
pub const VIRTUAL_DISPLAY_ABI_VERSION: u32 = 1;

pub type DWORD = ::std::os::raw::c_ulong;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _MonitorMode {
    pub width: DWORD,
    pub height: DWORD,
    pub sync: DWORD,
}
pub type MonitorMode = _MonitorMode;
pub type PMonitorMode = *mut MonitorMode;

// C-ABI function types for robust, versioned cross-library FFI (ABI-001)
pub type VirtualDisplayAbiMagic = unsafe extern "C" fn() -> u32;
pub type VirtualDisplayAbiVersion = unsafe extern "C" fn() -> u32;
pub type VirtualDisplayGetDriverInstallPath = unsafe extern "C" fn(*mut u8, usize) -> i32;
pub type VirtualDisplayDownloadDriver = unsafe extern "C" fn() -> i32;
pub type VirtualDisplayCreateDevice = unsafe extern "C" fn() -> i32;
pub type VirtualDisplayIsDeviceCreated = unsafe extern "C" fn() -> i32;
pub type VirtualDisplayCloseDevice = unsafe extern "C" fn() -> i32;
pub type VirtualDisplayInstallUpdateDriver = unsafe extern "C" fn(*mut i32) -> i32;
pub type VirtualDisplayUninstallDriver = unsafe extern "C" fn(*mut i32) -> i32;
pub type VirtualDisplayPlugInMonitor = unsafe extern "C" fn(u32, u32, u32) -> i32;
pub type VirtualDisplayPlugOutMonitor = unsafe extern "C" fn(u32) -> i32;
pub type VirtualDisplayUpdateMonitorModes = unsafe extern "C" fn(u32, u32, PMonitorMode) -> i32;
pub type VirtualDisplayGetLastError = unsafe extern "C" fn(*mut u8, usize) -> i32;

// Legacy symbol types for backwards compatibility
pub type GetDriverInstallPath = fn() -> &'static str;
pub type IsDeviceCreated = fn() -> bool;
pub type CloseDevice = fn();
pub type DownLoadDriver = fn() -> ResultType<()>;
pub type CreateDevice = fn() -> ResultType<()>;
pub type InstallUpdateDriver = fn(&mut bool) -> ResultType<()>;
pub type UninstallDriver = fn(&mut bool) -> ResultType<()>;
pub type PlugInMonitor = fn(u32, u32, u32) -> ResultType<()>;
pub type PlugOutMonitor = fn(u32) -> ResultType<()>;
pub type UpdateMonitorModes = fn(u32, u32, PMonitorMode) -> ResultType<()>;

struct LibWrapper {
    _lib: Option<Library>,
    is_versioned_c_abi: bool,

    // Versioned C-ABI symbols
    _c_abi_magic: Option<VirtualDisplayAbiMagic>,
    _c_abi_version: Option<VirtualDisplayAbiVersion>,
    c_get_install_path: Option<VirtualDisplayGetDriverInstallPath>,
    c_download_driver: Option<VirtualDisplayDownloadDriver>,
    c_create_device: Option<VirtualDisplayCreateDevice>,
    c_is_device_created: Option<VirtualDisplayIsDeviceCreated>,
    c_close_device: Option<VirtualDisplayCloseDevice>,
    c_install_update_driver: Option<VirtualDisplayInstallUpdateDriver>,
    c_uninstall_driver: Option<VirtualDisplayUninstallDriver>,
    c_plug_in_monitor: Option<VirtualDisplayPlugInMonitor>,
    c_plug_out_monitor: Option<VirtualDisplayPlugOutMonitor>,
    c_update_monitor_modes: Option<VirtualDisplayUpdateMonitorModes>,
    c_get_last_error: Option<VirtualDisplayGetLastError>,

    // Fallback legacy symbols
    get_driver_install_path: Option<GetDriverInstallPath>,
    is_device_created: Option<IsDeviceCreated>,
    close_device: Option<CloseDevice>,
    download_driver: Option<DownLoadDriver>,
    create_device: Option<CreateDevice>,
    install_update_driver: Option<InstallUpdateDriver>,
    uninstall_driver: Option<UninstallDriver>,
    plug_in_monitor: Option<PlugInMonitor>,
    plug_out_monitor: Option<PlugOutMonitor>,
    update_monitor_modes: Option<UpdateMonitorModes>,
}

impl LibWrapper {
    fn new() -> Self {
        let lib = match Library::open(get_lib_name()) {
            Ok(lib) => Some(lib),
            Err(e) => {
                log::warn!("Failed to load library {}, {}", LIB_NAME_VIRTUAL_DISPLAY, e);
                None
            }
        };

        let Some(lib) = lib else {
            return Self::empty();
        };
        // Check for versioned C-ABI handshake first
        let magic_fn = unsafe {
            lib.symbol::<VirtualDisplayAbiMagic>("virtual_display_abi_magic")
                .ok()
                .map(|m| *m)
        };
        let ver_fn = unsafe {
            lib.symbol::<VirtualDisplayAbiVersion>("virtual_display_abi_version")
                .ok()
                .map(|m| *m)
        };

        if let (Some(m_fn), Some(v_fn)) = (magic_fn, ver_fn) {
            let magic = unsafe { m_fn() };
            let version = unsafe { v_fn() };
            if magic != VIRTUAL_DISPLAY_ABI_MAGIC || version != VIRTUAL_DISPLAY_ABI_VERSION {
                log::error!(
                        "Incompatible virtual display library ABI: magic={:#x} (expected {:#x}), version={} (expected {})",
                        magic,
                        VIRTUAL_DISPLAY_ABI_MAGIC,
                        version,
                        VIRTUAL_DISPLAY_ABI_VERSION
                    );
                return Self::empty();
            }

            // Load versioned C-ABI symbols
            let c_get_install_path = unsafe {
                lib.symbol::<VirtualDisplayGetDriverInstallPath>(
                    "virtual_display_get_driver_install_path",
                )
                .ok()
                .map(|m| *m)
            };
            let c_download_driver = unsafe {
                lib.symbol::<VirtualDisplayDownloadDriver>("virtual_display_download_driver")
                    .ok()
                    .map(|m| *m)
            };
            let c_create_device = unsafe {
                lib.symbol::<VirtualDisplayCreateDevice>("virtual_display_create_device")
                    .ok()
                    .map(|m| *m)
            };
            let c_is_device_created = unsafe {
                lib.symbol::<VirtualDisplayIsDeviceCreated>("virtual_display_is_device_created")
                    .ok()
                    .map(|m| *m)
            };
            let c_close_device = unsafe {
                lib.symbol::<VirtualDisplayCloseDevice>("virtual_display_close_device")
                    .ok()
                    .map(|m| *m)
            };
            let c_install_update_driver = unsafe {
                lib.symbol::<VirtualDisplayInstallUpdateDriver>(
                    "virtual_display_install_update_driver",
                )
                .ok()
                .map(|m| *m)
            };
            let c_uninstall_driver = unsafe {
                lib.symbol::<VirtualDisplayUninstallDriver>("virtual_display_uninstall_driver")
                    .ok()
                    .map(|m| *m)
            };
            let c_plug_in_monitor = unsafe {
                lib.symbol::<VirtualDisplayPlugInMonitor>("virtual_display_plug_in_monitor")
                    .ok()
                    .map(|m| *m)
            };
            let c_plug_out_monitor = unsafe {
                lib.symbol::<VirtualDisplayPlugOutMonitor>("virtual_display_plug_out_monitor")
                    .ok()
                    .map(|m| *m)
            };
            let c_update_monitor_modes = unsafe {
                lib.symbol::<VirtualDisplayUpdateMonitorModes>(
                    "virtual_display_update_monitor_modes",
                )
                .ok()
                .map(|m| *m)
            };
            let c_get_last_error = unsafe {
                lib.symbol::<VirtualDisplayGetLastError>("virtual_display_get_last_error")
                    .ok()
                    .map(|m| *m)
            };

            return Self {
                _lib: Some(lib),
                is_versioned_c_abi: true,
                _c_abi_magic: magic_fn,
                _c_abi_version: ver_fn,
                c_get_install_path,
                c_download_driver,
                c_create_device,
                c_is_device_created,
                c_close_device,
                c_install_update_driver,
                c_uninstall_driver,
                c_plug_in_monitor,
                c_plug_out_monitor,
                c_update_monitor_modes,
                c_get_last_error,
                get_driver_install_path: None,
                is_device_created: None,
                close_device: None,
                download_driver: None,
                create_device: None,
                install_update_driver: None,
                uninstall_driver: None,
                plug_in_monitor: None,
                plug_out_monitor: None,
                update_monitor_modes: None,
            };
        }

        // Fallback: legacy symbols
        let get_driver_install_path = unsafe {
            lib.symbol::<GetDriverInstallPath>("get_driver_install_path")
                .ok()
                .map(|m| *m)
        };
        let is_device_created = unsafe {
            lib.symbol::<IsDeviceCreated>("is_device_created")
                .ok()
                .map(|m| *m)
        };
        let close_device = unsafe { lib.symbol::<CloseDevice>("close_device").ok().map(|m| *m) };
        let download_driver = unsafe {
            lib.symbol::<DownLoadDriver>("download_driver")
                .ok()
                .map(|m| *m)
        };
        let create_device = unsafe { lib.symbol::<CreateDevice>("create_device").ok().map(|m| *m) };
        let install_update_driver = unsafe {
            lib.symbol::<InstallUpdateDriver>("install_update_driver")
                .ok()
                .map(|m| *m)
        };
        let uninstall_driver = unsafe {
            lib.symbol::<UninstallDriver>("uninstall_driver")
                .ok()
                .map(|m| *m)
        };
        let plug_in_monitor = unsafe {
            lib.symbol::<PlugInMonitor>("plug_in_monitor")
                .ok()
                .map(|m| *m)
        };
        let plug_out_monitor = unsafe {
            lib.symbol::<PlugOutMonitor>("plug_out_monitor")
                .ok()
                .map(|m| *m)
        };
        let update_monitor_modes = unsafe {
            lib.symbol::<UpdateMonitorModes>("update_monitor_modes")
                .ok()
                .map(|m| *m)
        };

        Self {
            _lib: Some(lib),
            is_versioned_c_abi: false,
            _c_abi_magic: None,
            _c_abi_version: None,
            c_get_install_path: None,
            c_download_driver: None,
            c_create_device: None,
            c_is_device_created: None,
            c_close_device: None,
            c_install_update_driver: None,
            c_uninstall_driver: None,
            c_plug_in_monitor: None,
            c_plug_out_monitor: None,
            c_update_monitor_modes: None,
            c_get_last_error: None,
            get_driver_install_path,
            is_device_created,
            close_device,
            download_driver,
            create_device,
            install_update_driver,
            uninstall_driver,
            plug_in_monitor,
            plug_out_monitor,
            update_monitor_modes,
        }
    }

    fn empty() -> Self {
        Self {
            _lib: None,
            is_versioned_c_abi: false,
            _c_abi_magic: None,
            _c_abi_version: None,
            c_get_install_path: None,
            c_download_driver: None,
            c_create_device: None,
            c_is_device_created: None,
            c_close_device: None,
            c_install_update_driver: None,
            c_uninstall_driver: None,
            c_plug_in_monitor: None,
            c_plug_out_monitor: None,
            c_update_monitor_modes: None,
            c_get_last_error: None,
            get_driver_install_path: None,
            is_device_created: None,
            close_device: None,
            download_driver: None,
            create_device: None,
            install_update_driver: None,
            uninstall_driver: None,
            plug_in_monitor: None,
            plug_out_monitor: None,
            update_monitor_modes: None,
        }
    }

    fn get_error_message(&self) -> String {
        if let Some(f) = self.c_get_last_error {
            let mut buf = [0u8; 512];
            let len = unsafe { f(buf.as_mut_ptr(), buf.len()) };
            if len > 0 {
                let sl = &buf[..len as usize];
                return String::from_utf8_lossy(sl).into_owned();
            }
        }
        "Unknown virtual display error".to_string()
    }
}

impl Default for LibWrapper {
    fn default() -> Self {
        Self::new()
    }
}

lazy_static::lazy_static! {
    static ref LIB_WRAPPER: Arc<Mutex<LibWrapper>> = Default::default();
    static ref MONITOR_INDICES: Mutex<HashSet<u32>> = Mutex::new(HashSet::new());
}

#[cfg(target_os = "windows")]
fn get_lib_name() -> String {
    format!("{}.dll", LIB_NAME_VIRTUAL_DISPLAY)
}

#[cfg(target_os = "linux")]
fn get_lib_name() -> String {
    format!("lib{}.so", LIB_NAME_VIRTUAL_DISPLAY)
}

#[cfg(target_os = "macos")]
fn get_lib_name() -> String {
    format!("lib{}.dylib", LIB_NAME_VIRTUAL_DISPLAY)
}

#[cfg(windows)]
pub fn get_driver_install_path() -> Option<String> {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_get_install_path {
            let mut buf = [0u8; 512];
            let len = unsafe { f(buf.as_mut_ptr(), buf.len()) };
            if len > 0 {
                return Some(String::from_utf8_lossy(&buf[..len as usize]).into_owned());
            }
        }
    }
    wrapper.get_driver_install_path.map(|f| f().to_string())
}

pub fn is_device_created() -> bool {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_is_device_created {
            return unsafe { f() != 0 };
        }
    }
    wrapper.is_device_created.map(|f| f()).unwrap_or(false)
}

pub fn close_device() {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_close_device {
            let _ = unsafe { f() };
            return;
        }
    }
    let _r = wrapper.close_device.map(|f| f());
}

pub fn download_driver() -> ResultType<()> {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_download_driver {
            let ret = unsafe { f() };
            if ret != 0 {
                bail!("download_driver failed: {}", wrapper.get_error_message());
            }
            return Ok(());
        }
    }
    wrapper
        .download_driver
        .ok_or(anyhow::Error::msg("download_driver method not found"))?()
}

pub fn create_device() -> ResultType<()> {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_create_device {
            let ret = unsafe { f() };
            if ret != 0 {
                bail!("create_device failed: {}", wrapper.get_error_message());
            }
            return Ok(());
        }
    }
    wrapper
        .create_device
        .ok_or(anyhow::Error::msg("create_device method not found"))?()
}

pub fn install_update_driver(reboot_required: &mut bool) -> ResultType<()> {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_install_update_driver {
            let mut reboot_int = 0i32;
            let ret = unsafe { f(&mut reboot_int) };
            if ret != 0 {
                bail!(
                    "install_update_driver failed: {}",
                    wrapper.get_error_message()
                );
            }
            *reboot_required = reboot_int != 0;
            return Ok(());
        }
    }
    wrapper
        .install_update_driver
        .ok_or(anyhow::Error::msg("install_update_driver method not found"))?(reboot_required)
}

pub fn uninstall_driver(reboot_required: &mut bool) -> ResultType<()> {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_uninstall_driver {
            let mut reboot_int = 0i32;
            let ret = unsafe { f(&mut reboot_int) };
            if ret != 0 {
                bail!("uninstall_driver failed: {}", wrapper.get_error_message());
            }
            *reboot_required = reboot_int != 0;
            return Ok(());
        }
    }
    wrapper
        .uninstall_driver
        .ok_or(anyhow::Error::msg("uninstall_driver method not found"))?(reboot_required)
}

#[cfg(windows)]
pub fn plug_in_monitor(monitor_index: u32) -> ResultType<()> {
    let mut lock = MONITOR_INDICES.lock().unwrap();
    if lock.contains(&monitor_index) {
        return Ok(());
    }
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_plug_in_monitor {
            let ret = unsafe { f(monitor_index, 0, 20) };
            if ret != 0 {
                bail!("plug_in_monitor failed: {}", wrapper.get_error_message());
            }
            lock.insert(monitor_index);
            return Ok(());
        }
    }
    let f = wrapper
        .plug_in_monitor
        .ok_or(anyhow::Error::msg("plug_in_monitor method not found"))?;
    f(monitor_index, 0, 20)?;
    lock.insert(monitor_index);
    Ok(())
}

#[cfg(windows)]
pub fn plug_out_monitor(monitor_index: u32) -> ResultType<()> {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_plug_out_monitor {
            let ret = unsafe { f(monitor_index) };
            if ret != 0 {
                bail!("plug_out_monitor failed: {}", wrapper.get_error_message());
            }
            MONITOR_INDICES.lock().unwrap().remove(&monitor_index);
            return Ok(());
        }
    }
    let f = wrapper
        .plug_out_monitor
        .ok_or(anyhow::Error::msg("plug_out_monitor method not found"))?;
    f(monitor_index)?;
    MONITOR_INDICES.lock().unwrap().remove(&monitor_index);
    Ok(())
}

#[cfg(windows)]
pub fn update_monitor_modes(monitor_index: u32, modes: &[MonitorMode]) -> ResultType<()> {
    let wrapper = LIB_WRAPPER.lock().unwrap();
    if wrapper.is_versioned_c_abi {
        if let Some(f) = wrapper.c_update_monitor_modes {
            let ret = unsafe { f(monitor_index, modes.len() as _, modes.as_ptr() as _) };
            if ret != 0 {
                bail!(
                    "update_monitor_modes failed: {}",
                    wrapper.get_error_message()
                );
            }
            return Ok(());
        }
    }
    let f = wrapper
        .update_monitor_modes
        .ok_or(anyhow::Error::msg("update_monitor_modes method not found"))?;
    f(monitor_index, modes.len() as _, modes.as_ptr() as _)
}
