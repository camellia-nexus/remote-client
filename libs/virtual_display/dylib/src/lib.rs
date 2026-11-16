#[cfg(windows)]
pub mod win10;
#[cfg(windows)]
use camellia_remote_protocol::bail;
use camellia_remote_protocol::{lazy_static, ResultType};
#[cfg(windows)]
use std::path::PathBuf;
use std::sync::Mutex;

// ABI-001: Versioned C-ABI constants and handshakes
pub const VIRTUAL_DISPLAY_ABI_MAGIC: u32 = 0x56495254; // 'V', 'I', 'R', 'T'
pub const VIRTUAL_DISPLAY_ABI_VERSION: u32 = 1;

#[no_mangle]
pub extern "C" fn virtual_display_abi_magic() -> u32 {
    VIRTUAL_DISPLAY_ABI_MAGIC
}

#[no_mangle]
pub extern "C" fn virtual_display_abi_version() -> u32 {
    VIRTUAL_DISPLAY_ABI_VERSION
}

lazy_static::lazy_static! {
    static ref LAST_ERROR: Mutex<String> = Mutex::new(String::new());
}

fn set_last_error(msg: impl Into<String>) {
    if let Ok(mut lock) = LAST_ERROR.lock() {
        *lock = msg.into();
    }
}

#[no_mangle]
pub extern "C" fn virtual_display_get_last_error(buf: *mut u8, buf_len: usize) -> i32 {
    if buf.is_null() || buf_len == 0 {
        return -1;
    }
    let msg = match LAST_ERROR.lock() {
        Ok(guard) => guard.clone(),
        Err(poisoned) => poisoned.into_inner().clone(),
    };
    let bytes = msg.as_bytes();
    let to_copy = bytes.len().min(buf_len.saturating_sub(1));
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, to_copy);
        *buf.add(to_copy) = 0;
    }
    to_copy as i32
}

#[cfg(windows)]
lazy_static::lazy_static! {
    // If device is uninstalled though "Device Manager" Window.
    // Camellia is unable to handle device any more...
    static ref H_SW_DEVICE: Mutex<u64> = Mutex::new(0);
}

#[no_mangle]
#[cfg(windows)]
pub extern "C" fn get_driver_install_path() -> &'static str {
    win10::DRIVER_INSTALL_PATH
}

#[no_mangle]
pub extern "C" fn virtual_display_get_driver_install_path(buf: *mut u8, buf_len: usize) -> i32 {
    if buf.is_null() || buf_len == 0 {
        return -1;
    }
    #[cfg(windows)]
    let path = win10::DRIVER_INSTALL_PATH;
    #[cfg(not(windows))]
    let path = "";

    let bytes = path.as_bytes();
    let to_copy = bytes.len().min(buf_len.saturating_sub(1));
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, to_copy);
        *buf.add(to_copy) = 0;
    }
    to_copy as i32
}

#[no_mangle]
pub extern "C" fn virtual_display_download_driver() -> i32 {
    0
}

#[no_mangle]
pub fn download_driver() -> ResultType<()> {
    #[cfg(windows)]
    let _download_url = win10::DRIVER_DOWNLOAD_URL;
    #[cfg(target_os = "linux")]
    let _download_url = "";

    // process download and report progress

    Ok(())
}

#[cfg(windows)]
fn get_driver_install_abs_path() -> ResultType<PathBuf> {
    let install_path = win10::DRIVER_INSTALL_PATH;
    let exe_file = std::env::current_exe()?;
    let abs_path = match exe_file.parent() {
        Some(cur_dir) => cur_dir.join(install_path),
        None => bail!(
            "Invalid exe parent for {}",
            exe_file.to_string_lossy().as_ref()
        ),
    };
    if !abs_path.exists() {
        bail!("{} not exists", install_path)
    }
    Ok(abs_path)
}

#[no_mangle]
pub extern "C" fn virtual_display_install_update_driver(reboot_required: *mut i32) -> i32 {
    let mut reboot = false;
    match install_update_driver(&mut reboot) {
        Ok(()) => {
            if !reboot_required.is_null() {
                unsafe {
                    *reboot_required = if reboot { 1 } else { 0 };
                }
            }
            0
        }
        Err(e) => {
            set_last_error(e.to_string());
            -1
        }
    }
}

#[no_mangle]
pub fn install_update_driver(_reboot_required: &mut bool) -> ResultType<()> {
    #[cfg(windows)]
    unsafe {
        {
            // Device must be created before install driver.
            // https://github.com/fufesou/CamelliaIddDriver/issues/1
            if let Err(e) = create_device() {
                bail!("{}", e);
            }

            let abs_path = get_driver_install_abs_path()?;
            let full_install_path: Vec<u16> = abs_path
                .to_string_lossy()
                .as_ref()
                .encode_utf16()
                .chain(Some(0).into_iter())
                .collect();

            let mut reboot_required_tmp = win10::idd::FALSE;
            if win10::idd::InstallUpdate(full_install_path.as_ptr() as _, &mut reboot_required_tmp)
                == win10::idd::FALSE
            {
                bail!("{}", win10::get_last_msg()?);
            }
            *_reboot_required = reboot_required_tmp == win10::idd::TRUE;
        }
    }

    Ok(())
}

#[no_mangle]
pub extern "C" fn virtual_display_uninstall_driver(reboot_required: *mut i32) -> i32 {
    let mut reboot = false;
    match uninstall_driver(&mut reboot) {
        Ok(()) => {
            if !reboot_required.is_null() {
                unsafe {
                    *reboot_required = if reboot { 1 } else { 0 };
                }
            }
            0
        }
        Err(e) => {
            set_last_error(e.to_string());
            -1
        }
    }
}

#[no_mangle]
pub fn uninstall_driver(_reboot_required: &mut bool) -> ResultType<()> {
    #[cfg(windows)]
    unsafe {
        {
            let abs_path = get_driver_install_abs_path()?;
            let full_install_path: Vec<u16> = abs_path
                .to_string_lossy()
                .as_ref()
                .encode_utf16()
                .chain(Some(0).into_iter())
                .collect();

            let mut reboot_required_tmp = win10::idd::FALSE;
            if win10::idd::Uninstall(full_install_path.as_ptr() as _, &mut reboot_required_tmp)
                == win10::idd::FALSE
            {
                bail!("{}", win10::get_last_msg()?);
            }
            *_reboot_required = reboot_required_tmp == win10::idd::TRUE;
        }
    }

    Ok(())
}

#[no_mangle]
pub extern "C" fn virtual_display_is_device_created() -> i32 {
    if is_device_created() {
        1
    } else {
        0
    }
}

#[no_mangle]
pub fn is_device_created() -> bool {
    #[cfg(windows)]
    return *H_SW_DEVICE.lock().unwrap() != 0;
    #[cfg(not(windows))]
    return false;
}

#[no_mangle]
pub extern "C" fn virtual_display_create_device() -> i32 {
    match create_device() {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(e.to_string());
            -1
        }
    }
}

#[no_mangle]
pub fn create_device() -> ResultType<()> {
    if is_device_created() {
        return Ok(());
    }
    #[cfg(windows)]
    unsafe {
        let mut lock_device = H_SW_DEVICE.lock().unwrap();
        let mut h_sw_device = *lock_device as win10::idd::HSWDEVICE;
        if win10::idd::DeviceCreate(&mut h_sw_device) == win10::idd::FALSE {
            bail!("{}", win10::get_last_msg()?);
        } else {
            *lock_device = h_sw_device as u64;
        }
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn virtual_display_close_device() -> i32 {
    close_device();
    0
}

#[no_mangle]
pub fn close_device() {
    #[cfg(windows)]
    unsafe {
        win10::idd::DeviceClose(*H_SW_DEVICE.lock().unwrap() as win10::idd::HSWDEVICE);
        *H_SW_DEVICE.lock().unwrap() = 0;
    }
}

#[no_mangle]
pub extern "C" fn virtual_display_plug_in_monitor(
    monitor_index: u32,
    edid: u32,
    retries: u32,
) -> i32 {
    match plug_in_monitor(monitor_index, edid, retries) {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(e.to_string());
            -1
        }
    }
}

#[no_mangle]
pub fn plug_in_monitor(_monitor_index: u32, _edid: u32, _retries: u32) -> ResultType<()> {
    #[cfg(windows)]
    unsafe {
        if win10::idd::MonitorPlugIn(_monitor_index as _, _edid as _, _retries as _)
            == win10::idd::FALSE
        {
            bail!("{}", win10::get_last_msg()?);
        }
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn virtual_display_plug_out_monitor(monitor_index: u32) -> i32 {
    match plug_out_monitor(monitor_index) {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(e.to_string());
            -1
        }
    }
}

#[no_mangle]
pub fn plug_out_monitor(_monitor_index: u32) -> ResultType<()> {
    #[cfg(windows)]
    unsafe {
        if win10::idd::MonitorPlugOut(_monitor_index) == win10::idd::FALSE {
            bail!("{}", win10::get_last_msg()?);
        }
    }
    Ok(())
}

#[cfg(windows)]
type PMonitorMode = win10::idd::PMonitorMode;
#[cfg(not(windows))]
type PMonitorMode = *mut std::ffi::c_void;

#[no_mangle]
pub extern "C" fn virtual_display_update_monitor_modes(
    monitor_index: u32,
    mode_count: u32,
    modes: PMonitorMode,
) -> i32 {
    match update_monitor_modes(monitor_index, mode_count, modes) {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(e.to_string());
            -1
        }
    }
}

#[no_mangle]
pub fn update_monitor_modes(
    _monitor_index: u32,
    _mode_count: u32,
    _modes: PMonitorMode,
) -> ResultType<()> {
    #[cfg(windows)]
    unsafe {
        if win10::idd::FALSE
            == win10::idd::MonitorModesUpdate(_monitor_index as _, _mode_count as _, _modes)
        {
            bail!("{}", win10::get_last_msg()?);
        }
    }
    Ok(())
}
