use crate::{
    ipc::{self, new_listener, Connection, Data, DataPortableService, IPC_TOKEN_LEN},
    platform::{
        set_path_permission, set_path_permission_for_portable_service_shmem_dir,
        set_path_permission_for_portable_service_shmem_file,
        validate_path_for_portable_service_shmem_dir,
    },
};
use camellia_remote_protocol::{
    allow_err,
    anyhow::anyhow,
    bail, libc, log,
    message_proto::{KeyEvent, MouseEvent},
    protobuf::Message,
    tokio::{self, sync::mpsc},
    ResultType,
};
use core::slice;
#[cfg(feature = "vram")]
use scrap::AdapterDevice;
use scrap::{Capturer, Frame, TraitCapturer, TraitPixelBuffer};
use shared_memory::*;
use std::{
    mem::size_of,
    ops::{Deref, DerefMut},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use winapi::{
    shared::minwindef::{BOOL, FALSE, TRUE},
    um::winuser::{self, CURSORINFO, PCURSORINFO},
};
use windows::Win32::Storage::FileSystem::{FILE_GENERIC_EXECUTE, FILE_GENERIC_READ};

use super::portable_service_sync::{
    CaptureParameters, CaptureParametersSnapshot, PortableInputQueue, SharedCaptureParameters,
    SharedSlotCounter, PORTABLE_IPC_QUEUE_CAPACITY,
};
use super::video_qos;

const FRAME_ALIGN: usize = 64;
const RUNTIME_SHMEM_MAGIC: [u8; 8] = *b"CMRPSHM\0";
const RUNTIME_SHMEM_ABI_VERSION: u32 = 2;

const fn align_addr(value: usize, align: usize) -> usize {
    (value + align - 1) / align * align
}

const ADDR_IPC_TOKEN: usize = 0;
const ADDR_RUNTIME_HEADER: usize = align_addr(
    ADDR_IPC_TOKEN + IPC_TOKEN_LEN,
    std::mem::align_of::<RuntimeShmemHeader>(),
);
const ADDR_CURSOR_PARA: usize = align_addr(
    ADDR_RUNTIME_HEADER + size_of::<RuntimeShmemHeader>(),
    std::mem::align_of::<CURSORINFO>(),
);
const ADDR_CURSOR_COUNTER: usize = align_addr(
    ADDR_CURSOR_PARA + size_of::<CURSORINFO>(),
    std::mem::align_of::<SharedSlotCounter>(),
);
const ADDR_CAPTURER_PARA: usize = align_addr(
    ADDR_CURSOR_COUNTER + size_of::<SharedSlotCounter>(),
    std::mem::align_of::<SharedCaptureParameters>(),
);
const ADDR_CAPTURE_FRAME_INFO: usize = align_addr(
    ADDR_CAPTURER_PARA + size_of::<SharedCaptureParameters>(),
    std::mem::align_of::<FrameInfo>(),
);
const ADDR_CAPTURE_WOULDBLOCK: usize = align_addr(
    ADDR_CAPTURE_FRAME_INFO + size_of::<FrameInfo>(),
    std::mem::align_of::<std::sync::atomic::AtomicI32>(),
);
const ADDR_CAPTURE_FRAME_COUNTER: usize = align_addr(
    ADDR_CAPTURE_WOULDBLOCK + size_of::<std::sync::atomic::AtomicI32>(),
    std::mem::align_of::<SharedSlotCounter>(),
);
const ADDR_CAPTURE_FRAME: usize = align_addr(
    ADDR_CAPTURE_FRAME_COUNTER + size_of::<SharedSlotCounter>(),
    FRAME_ALIGN,
);
const MIN_RUNTIME_SHMEM_LEN: usize = ADDR_CAPTURE_FRAME + FRAME_ALIGN;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RuntimeShmemHeader {
    magic: [u8; 8],
    abi_version: u32,
    header_len: u32,
    shmem_len: u64,
    frame_addr: u64,
}

const _: () = {
    assert!(size_of::<RuntimeShmemHeader>() == 32);
    assert!(ADDR_RUNTIME_HEADER % std::mem::align_of::<RuntimeShmemHeader>() == 0);
    assert!(ADDR_CURSOR_COUNTER % std::mem::align_of::<SharedSlotCounter>() == 0);
    assert!(ADDR_CAPTURER_PARA % std::mem::align_of::<SharedCaptureParameters>() == 0);
    assert!(ADDR_CAPTURE_FRAME_COUNTER % std::mem::align_of::<SharedSlotCounter>() == 0);
    assert!(ADDR_CAPTURE_FRAME % FRAME_ALIGN == 0);
};

const IPC_SUFFIX: &str = "_portable_service";
pub const SHMEM_NAME: &str = "_portable_service";
pub const SHMEM_ARG_PREFIX: &str = "--portable-service-shmem-name=";
const SHMEM_PARENT_DIR: &str = "portable_service_shmem";
const SHMEM_NAME_MAX_LEN: usize = 64;
const MAX_NACK: usize = 3;
const PORTABLE_SERVICE_STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_DXGI_FAIL_TIME: usize = 5;

#[inline]
fn is_valid_portable_service_shmem_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= SHMEM_NAME_MAX_LEN
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

#[inline]
pub fn portable_service_shmem_arg(name: &str) -> String {
    format!("{SHMEM_ARG_PREFIX}{name}")
}

#[inline]
fn is_valid_portable_service_ipc_token(token: &str) -> bool {
    token.len() == IPC_TOKEN_LEN
        && token
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

#[inline]
fn read_ipc_token_from_shmem(shmem: &SharedMemory) -> Option<String> {
    if shmem.len() < ADDR_IPC_TOKEN + IPC_TOKEN_LEN {
        log::error!(
            "Portable service shared memory too small: len={}, need>={}",
            shmem.len(),
            ADDR_IPC_TOKEN + IPC_TOKEN_LEN
        );
        return None;
    }
    unsafe {
        let ptr = shmem.as_ptr().add(ADDR_IPC_TOKEN);
        let bytes = slice::from_raw_parts(ptr, IPC_TOKEN_LEN);
        let end = bytes
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(IPC_TOKEN_LEN);
        if end == 0 {
            return None;
        }
        let token = std::str::from_utf8(&bytes[..end]).ok()?.to_owned();
        if is_valid_portable_service_ipc_token(&token) {
            Some(token)
        } else {
            None
        }
    }
}

#[inline]
fn initialize_runtime_shmem_layout(shmem: &SharedMemory) -> ResultType<()> {
    if shmem.len() < MIN_RUNTIME_SHMEM_LEN {
        bail!(
            "Portable service shared memory too small for runtime layout: len={}, need>={}",
            shmem.len(),
            MIN_RUNTIME_SHMEM_LEN
        );
    }
    let header = RuntimeShmemHeader {
        magic: RUNTIME_SHMEM_MAGIC,
        abi_version: RUNTIME_SHMEM_ABI_VERSION,
        header_len: size_of::<RuntimeShmemHeader>() as u32,
        shmem_len: u64::try_from(shmem.len())?,
        frame_addr: ADDR_CAPTURE_FRAME as u64,
    };
    let bytes = unsafe {
        slice::from_raw_parts(
            (&header as *const RuntimeShmemHeader).cast::<u8>(),
            size_of::<RuntimeShmemHeader>(),
        )
    };
    shmem.write(ADDR_RUNTIME_HEADER, bytes);
    Ok(())
}

#[inline]
fn validate_runtime_shmem_layout(shmem: &SharedMemory) -> ResultType<()> {
    if shmem.len() < MIN_RUNTIME_SHMEM_LEN {
        bail!(
            "Portable service shared memory too small for runtime layout: len={}, need>={}",
            shmem.len(),
            MIN_RUNTIME_SHMEM_LEN
        );
    }
    let header = unsafe {
        std::ptr::read_unaligned(
            shmem
                .as_ptr()
                .add(ADDR_RUNTIME_HEADER)
                .cast::<RuntimeShmemHeader>(),
        )
    };
    if header.magic != RUNTIME_SHMEM_MAGIC
        || header.abi_version != RUNTIME_SHMEM_ABI_VERSION
        || header.header_len as usize != size_of::<RuntimeShmemHeader>()
        || header.shmem_len != shmem.len() as u64
        || header.frame_addr != ADDR_CAPTURE_FRAME as u64
    {
        bail!(
            "Portable service shared-memory ABI mismatch: version={}, header_len={}, shmem_len={}, frame_addr={}",
            header.abi_version,
            header.header_len,
            header.shmem_len,
            header.frame_addr
        );
    }
    Ok(())
}

#[inline]
fn is_valid_capture_frame_length(shmem_len: usize, frame_len: usize) -> bool {
    let frame_capacity = shmem_len.saturating_sub(ADDR_CAPTURE_FRAME);
    frame_len > 0 && frame_len <= frame_capacity
}

#[inline]
fn shared_memory_flink_path_by_name(name: &str) -> ResultType<PathBuf> {
    let mut dir = crate::platform::user_accessible_folder()?;
    dir = dir.join(
        camellia_remote_protocol::config::APP_NAME
            .read()
            .unwrap()
            .clone(),
    );
    dir = dir.join(SHMEM_PARENT_DIR);
    Ok(dir.join(format!("shared_memory{}", name)))
}

#[inline]
fn remove_shared_memory_flink_once(name: &str, log_on_error: bool, log_context: &str) -> bool {
    let flink = match shared_memory_flink_path_by_name(name) {
        Ok(path) => path,
        Err(err) => {
            if log_on_error {
                log::warn!(
                    "{} failed to resolve portable service shared-memory flink path for '{}': {}",
                    log_context,
                    name,
                    err
                );
            }
            return false;
        }
    };
    match std::fs::remove_file(&flink) {
        Ok(()) => {
            log::info!(
                "{} removed portable service shared-memory flink artifact: {:?}",
                log_context,
                flink
            );
            true
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => true,
        Err(err) => {
            if log_on_error {
                log::warn!(
                    "{} failed to remove portable service shared-memory flink artifact {:?}: {}",
                    log_context,
                    flink,
                    err
                );
            }
            false
        }
    }
}

#[inline]
fn write_ipc_token_to_shmem(shmem: &SharedMemory, token: &str) -> ResultType<()> {
    if !is_valid_portable_service_ipc_token(token) {
        bail!("Invalid portable service ipc token");
    }
    shmem.write(ADDR_IPC_TOKEN, token.as_bytes());
    Ok(())
}

#[inline]
fn clear_ipc_token_in_shmem(shmem: &SharedMemory) {
    shmem.write(ADDR_IPC_TOKEN, &[0u8; IPC_TOKEN_LEN]);
}

#[inline]
fn portable_service_arg_value_candidate_from_arg<'a>(
    arg: &'a str,
    prefix: &str,
) -> Option<&'a str> {
    let mut value = arg.strip_prefix(prefix)?;
    value = value.trim_start();
    value = value
        .strip_prefix('"')
        .or_else(|| value.strip_prefix('\''))
        .unwrap_or(value);
    value = value.split_whitespace().next().unwrap_or_default();
    value = value.trim_matches(|c| c == '"' || c == '\'');
    Some(value)
}

#[inline]
pub fn portable_service_shmem_name_from_args() -> Option<String> {
    for arg in std::env::args() {
        if let Some(value) = portable_service_arg_value_candidate_from_arg(&arg, SHMEM_ARG_PREFIX) {
            if is_valid_portable_service_shmem_name(value) {
                return Some(value.to_owned());
            }
            log::error!(
                "Invalid portable service shared memory name argument: '{}'",
                value
            );
            return None;
        }
    }
    None
}

#[inline]
pub fn has_portable_service_shmem_arg() -> bool {
    std::env::args().any(|arg| arg.starts_with(SHMEM_ARG_PREFIX))
}

pub struct SharedMemory {
    inner: Shmem,
}

// SAFETY: `Shmem` owns a process-local mapping handle. Moving the handle does not move or
// invalidate the mapping. All concurrently mutable regions are accessed through the atomic
// protocols in `portable_service_sync`; raw payload copies happen only while one side owns the
// corresponding single-producer/single-consumer slot.
unsafe impl Send for SharedMemory {}
// SAFETY: see the `Send` invariant above. Callers may share the mapping, but must use disjoint
// immutable regions or the capture-parameter/slot protocols for every concurrent mutation.
unsafe impl Sync for SharedMemory {}

impl Deref for SharedMemory {
    type Target = Shmem;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl DerefMut for SharedMemory {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.inner
    }
}

impl SharedMemory {
    pub fn create(name: &str, size: usize) -> ResultType<Self> {
        let flink = Self::flink(name.to_string())?;
        let shmem = match ShmemConf::new()
            .size(size)
            .flink(&flink)
            .force_create_flink()
            .create()
        {
            Ok(m) => m,
            Err(ShmemError::LinkExists) => {
                bail!(
                    "Unable to force create shmem flink {}, which should not happen.",
                    flink
                )
            }
            Err(e) => {
                bail!("Unable to create shmem flink {} : {}", flink, e);
            }
        };
        log::info!("Create shared memory, size: {}, flink: {}", size, flink);
        if let Err(err) = set_path_permission_for_portable_service_shmem_file(Path::new(&flink)) {
            // Release shmem handle first so best-effort flink cleanup has a chance to succeed.
            drop(shmem);
            match std::fs::remove_file(&flink) {
                Ok(()) => {
                    log::info!(
                        "Create cleanup removed portable service shared-memory flink artifact: {}",
                        flink
                    );
                }
                Err(remove_err) if remove_err.kind() == std::io::ErrorKind::NotFound => {}
                Err(remove_err) => {
                    log::warn!(
                        "Create cleanup failed to remove portable service shared-memory flink artifact {}: {}",
                        flink,
                        remove_err
                    );
                }
            }
            return Err(err);
        }
        Ok(SharedMemory { inner: shmem })
    }

    pub fn open_existing(name: &str) -> ResultType<Self> {
        let flink = Self::flink(name.to_string())?;
        let shmem = match ShmemConf::new().flink(&flink).allow_raw(true).open() {
            Ok(m) => m,
            Err(e) => {
                bail!("Unable to open existing shmem flink {} : {}", flink, e);
            }
        };
        log::info!("open existing shared memory, flink: {:?}", flink);
        Ok(SharedMemory { inner: shmem })
    }

    pub fn write(&self, addr: usize, data: &[u8]) {
        unsafe {
            debug_assert!(addr + data.len() <= self.inner.len());
            let ptr = self.inner.as_ptr().add(addr);
            let shared_mem_slice = slice::from_raw_parts_mut(ptr, data.len());
            shared_mem_slice.copy_from_slice(data);
        }
    }

    fn flink(name: String) -> ResultType<String> {
        let mut dir = crate::platform::user_accessible_folder()?;
        dir = dir.join(
            camellia_remote_protocol::config::APP_NAME
                .read()
                .unwrap()
                .clone(),
        );
        dir = dir.join(SHMEM_PARENT_DIR);
        let parent_created = !dir.exists();
        if parent_created {
            std::fs::create_dir_all(&dir)?;
        }
        if parent_created || crate::platform::is_root() {
            // Harden parent ACL on first provisioning and periodically on SYSTEM path.
            set_path_permission_for_portable_service_shmem_dir(&dir)?;
        } else {
            // Existing parents still need type/reparse validation. Non-SYSTEM callers may lack
            // WRITE_DAC on a valid parent, so avoid rebuilding the ACL here.
            validate_path_for_portable_service_shmem_dir(&dir)?;
        }
        Ok(dir
            .join(format!("shared_memory{}", name))
            .to_string_lossy()
            .to_string())
    }
}

mod utils {
    use core::slice;
    use std::{
        mem::{align_of, size_of},
        sync::atomic::{AtomicI32, Ordering},
    };

    use super::{
        CaptureParameters, CaptureParametersSnapshot, FrameInfo, SharedCaptureParameters,
        SharedMemory, SharedSlotCounter, ADDR_CAPTURER_PARA, ADDR_CAPTURE_FRAME_INFO,
        ADDR_CAPTURE_WOULDBLOCK,
    };

    #[inline]
    pub fn counter(shmem: &SharedMemory, addr: usize) -> &SharedSlotCounter {
        debug_assert_eq!(addr % align_of::<SharedSlotCounter>(), 0);
        debug_assert!(addr + size_of::<SharedSlotCounter>() <= shmem.len());
        unsafe { &*shmem.as_ptr().add(addr).cast::<SharedSlotCounter>() }
    }

    #[inline]
    fn capture_parameters(shmem: &SharedMemory) -> &SharedCaptureParameters {
        debug_assert_eq!(
            ADDR_CAPTURER_PARA % align_of::<SharedCaptureParameters>(),
            0
        );
        debug_assert!(ADDR_CAPTURER_PARA + size_of::<SharedCaptureParameters>() <= shmem.len());
        unsafe {
            &*shmem
                .as_ptr()
                .add(ADDR_CAPTURER_PARA)
                .cast::<SharedCaptureParameters>()
        }
    }

    #[inline]
    pub fn read_para(shmem: &SharedMemory) -> Option<CaptureParametersSnapshot> {
        capture_parameters(shmem).read()
    }

    #[inline]
    pub fn set_para(shmem: &SharedMemory, para: CaptureParameters) {
        capture_parameters(shmem).write(para);
    }

    #[inline]
    pub fn set_wouldblock(shmem: &SharedMemory, value: i32) {
        debug_assert_eq!(ADDR_CAPTURE_WOULDBLOCK % align_of::<AtomicI32>(), 0);
        debug_assert!(ADDR_CAPTURE_WOULDBLOCK + size_of::<AtomicI32>() <= shmem.len());
        unsafe { AtomicI32::from_ptr(shmem.as_ptr().add(ADDR_CAPTURE_WOULDBLOCK).cast::<i32>()) }
            .store(value, Ordering::Release);
    }

    #[inline]
    pub fn wouldblock(shmem: &SharedMemory) -> i32 {
        debug_assert_eq!(ADDR_CAPTURE_WOULDBLOCK % align_of::<AtomicI32>(), 0);
        debug_assert!(ADDR_CAPTURE_WOULDBLOCK + size_of::<AtomicI32>() <= shmem.len());
        unsafe { AtomicI32::from_ptr(shmem.as_ptr().add(ADDR_CAPTURE_WOULDBLOCK).cast::<i32>()) }
            .load(Ordering::Acquire)
    }

    #[inline]
    pub fn align(v: usize, align: usize) -> usize {
        (v + align - 1) / align * align
    }

    #[inline]
    pub fn set_frame_info(shmem: &SharedMemory, info: FrameInfo) {
        let ptr = &info as *const FrameInfo as *const u8;
        let data;
        unsafe {
            data = slice::from_raw_parts(ptr, size_of::<FrameInfo>());
        }
        shmem.write(ADDR_CAPTURE_FRAME_INFO, data);
    }

    #[inline]
    pub fn read_frame_info(shmem: &SharedMemory) -> FrameInfo {
        unsafe {
            std::ptr::read_unaligned(
                shmem
                    .as_ptr()
                    .add(ADDR_CAPTURE_FRAME_INFO)
                    .cast::<FrameInfo>(),
            )
        }
    }
}

// functions called in separate SYSTEM user process.
pub mod server {
    use camellia_remote_protocol::message_proto::PointerDeviceEvent;

    use crate::display_service;

    use super::*;

    lazy_static::lazy_static! {
        static ref EXIT: Arc<Mutex<bool>> = Default::default();
        static ref FORCE_EXIT_ARMED: AtomicBool = AtomicBool::new(false);
    }

    pub fn run_portable_service() {
        let shmem_name = match portable_service_shmem_name_from_args() {
            Some(name) => name,
            None => {
                if has_portable_service_shmem_arg() {
                    log::error!(
                        "Invalid portable service shared memory argument, aborting startup"
                    );
                } else {
                    log::error!(
                        "Missing portable service shared memory argument, aborting startup"
                    );
                }
                return;
            }
        };
        let shmem = match SharedMemory::open_existing(&shmem_name) {
            Ok(shmem) => Arc::new(shmem),
            Err(e) => {
                log::error!("Failed to open existing shared memory: {:?}", e);
                return;
            }
        };
        if let Err(e) = validate_runtime_shmem_layout(shmem.as_ref()) {
            log::error!("{}", e);
            return;
        }
        let ipc_token = match read_ipc_token_from_shmem(shmem.as_ref()) {
            Some(token) => token,
            None => {
                log::error!(
                    "Missing portable service ipc token in shared memory, aborting startup"
                );
                return;
            }
        };
        let shmem1 = shmem.clone();
        let shmem2 = shmem.clone();
        let mut threads = vec![];
        threads.push(std::thread::spawn(|| {
            run_get_cursor_info(shmem1);
        }));
        threads.push(std::thread::spawn(|| {
            run_capture(shmem2);
        }));
        threads.push(std::thread::spawn(move || {
            run_ipc_client(ipc_token);
        }));
        // Detached shutdown watchdog:
        // - gives graceful shutdown/cleanup a short window
        // - force-exits the process if workers are still stuck
        std::thread::spawn(|| {
            run_exit_check();
        });
        let record_pos_handle = crate::input_service::try_start_record_cursor_pos();
        // Arm forced-exit watchdog only for worker join phase.
        // Once join phase completes, cleanup should not be interrupted by forced exit.
        FORCE_EXIT_ARMED.store(true, Ordering::SeqCst);
        for th in threads.drain(..) {
            th.join().ok();
            log::info!("thread joined");
        }
        FORCE_EXIT_ARMED.store(false, Ordering::SeqCst);

        crate::input_service::try_stop_record_cursor_pos();
        if let Some(handle) = record_pos_handle {
            match handle.join() {
                Ok(_) => log::info!("record_pos_handle joined"),
                Err(e) => log::error!("record_pos_handle join error {:?}", &e),
            }
        }
        drop(shmem);
        remove_shared_memory_flink_with_retry(&shmem_name);
    }

    fn run_exit_check() {
        const FORCED_EXIT_DELAY: Duration = Duration::from_secs(3);
        loop {
            if EXIT.lock().unwrap().clone() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        // Fallback only: normal shutdown path should complete and process should exit naturally.
        // This forced exit is a last resort when worker threads are stuck and graceful teardown
        // does not finish in time.
        std::thread::sleep(FORCED_EXIT_DELAY);
        if FORCE_EXIT_ARMED.load(Ordering::SeqCst) {
            log::warn!(
                "Portable service shutdown watchdog fallback triggered: forcing process exit after {:?}",
                FORCED_EXIT_DELAY
            );
            std::process::exit(0);
        }
    }

    fn remove_shared_memory_flink_with_retry(name: &str) {
        const MAX_RETRY: usize = 20;
        const RETRY_INTERVAL: Duration = Duration::from_millis(200);
        for attempt in 0..MAX_RETRY {
            let is_last_attempt = attempt + 1 == MAX_RETRY;
            if remove_shared_memory_flink_once(name, is_last_attempt, "SYSTEM cleanup") {
                return;
            }
            if !is_last_attempt {
                std::thread::sleep(RETRY_INTERVAL);
            }
        }
        log::warn!(
            "SYSTEM cleanup failed to remove portable service shared-memory flink artifact '{}' after retry",
            name
        );
    }

    fn run_get_cursor_info(shmem: Arc<SharedMemory>) {
        loop {
            if EXIT.lock().unwrap().clone() {
                break;
            }
            let counter = utils::counter(&shmem, ADDR_CURSOR_COUNTER);
            if counter.can_publish() {
                let mut cursor: CURSORINFO = unsafe { std::mem::zeroed() };
                cursor.cbSize = size_of::<CURSORINFO>() as _;
                let result = unsafe { winuser::GetCursorInfo(&mut cursor) };
                if result == TRUE {
                    let bytes = unsafe {
                        slice::from_raw_parts(
                            (&cursor as *const CURSORINFO).cast::<u8>(),
                            size_of::<CURSORINFO>(),
                        )
                    };
                    shmem.write(ADDR_CURSOR_PARA, bytes);
                    if !counter.publish() {
                        log::error!("Portable service cursor slot lost producer ownership");
                        *EXIT.lock().unwrap() = true;
                        return;
                    }
                }
            }
            // more frequent in case of `Error of mouse_cursor service`
            std::thread::sleep(Duration::from_millis(15));
        }
    }

    fn run_capture(shmem: Arc<SharedMemory>) {
        let mut c = None;
        let mut last_current_display = usize::MAX;
        let mut last_timeout_ms: i32 = 33;
        let mut spf = Duration::from_millis(last_timeout_ms as _);
        let mut dxgi_failed_times = 0;
        let mut display_width = 0;
        let mut display_height = 0;
        let mut para_generation = 0;
        let mut para = None;
        let mut capture_epoch = 0;
        let mut recreate_pending = false;
        loop {
            if EXIT.lock().unwrap().clone() {
                break;
            }
            if let Some(snapshot) = utils::read_para(&shmem) {
                if snapshot.generation != para_generation {
                    para_generation = snapshot.generation;
                    recreate_pending =
                        capture_epoch != 0 && capture_epoch != snapshot.value.capture_epoch;
                    capture_epoch = snapshot.value.capture_epoch;
                    para = Some(snapshot.value);
                }
            }
            let Some(para) = para else {
                std::thread::sleep(Duration::from_millis(1));
                continue;
            };
            let current_display = para.current_display as usize;
            if c.is_none() {
                let Ok(mut displays) = display_service::try_get_displays() else {
                    log::error!("Failed to get displays");
                    *EXIT.lock().unwrap() = true;
                    return;
                };
                if displays.len() <= current_display {
                    log::error!("Invalid display index:{}", current_display);
                    *EXIT.lock().unwrap() = true;
                    return;
                }
                let display = displays.remove(current_display);
                display_width = display.width();
                display_height = display.height();
                match Capturer::new(display) {
                    Ok(mut v) => {
                        last_current_display = current_display;
                        recreate_pending = false;
                        if dxgi_failed_times > MAX_DXGI_FAIL_TIME {
                            dxgi_failed_times = 0;
                            v.set_gdi();
                        }
                        c = Some(v);
                    }
                    Err(e) => {
                        log::error!("Failed to create gdi capturer: {:?}", e);
                        std::thread::sleep(std::time::Duration::from_secs(1));
                        continue;
                    }
                }
            } else {
                if recreate_pending || current_display != last_current_display {
                    log::info!(
                        "create capturer, display: {} -> {}",
                        last_current_display,
                        current_display,
                    );
                    recreate_pending = false;
                    c = None;
                    continue;
                }
                if para.timeout_ms != last_timeout_ms
                    && para.timeout_ms >= 1000 / video_qos::MAX_FPS as i32
                    && para.timeout_ms <= 1000 / video_qos::MIN_FPS as i32
                {
                    last_timeout_ms = para.timeout_ms;
                    spf = Duration::from_millis(para.timeout_ms as _);
                }
            }
            let frame_counter = utils::counter(&shmem, ADDR_CAPTURE_FRAME_COUNTER);
            if !frame_counter.can_publish() {
                std::thread::sleep(std::time::Duration::from_millis(1));
                continue;
            }
            match c.as_mut().map(|f| f.frame(spf)) {
                Some(Ok(f)) => match f {
                    Frame::PixelBuffer(f) => {
                        let frame_capacity = shmem.len().saturating_sub(ADDR_CAPTURE_FRAME);
                        if f.data().len() > frame_capacity {
                            log::error!(
                                "Portable service capture frame exceeds shared memory capacity: frame_len={}, capacity={}, shmem_len={}",
                                f.data().len(),
                                frame_capacity,
                                shmem.len()
                            );
                            *EXIT.lock().unwrap() = true;
                            return;
                        }
                        utils::set_frame_info(
                            &shmem,
                            FrameInfo {
                                length: f.data().len() as u64,
                                width: display_width as u64,
                                height: display_height as u64,
                            },
                        );
                        shmem.write(ADDR_CAPTURE_FRAME, f.data());
                        utils::set_wouldblock(&shmem, TRUE);
                        if !frame_counter.publish() {
                            log::error!("Portable service frame slot lost producer ownership");
                            *EXIT.lock().unwrap() = true;
                            return;
                        }
                        dxgi_failed_times = 0;
                    }
                    Frame::Texture(_) => {
                        // should not happen
                    }
                },
                Some(Err(e)) => {
                    if crate::platform::windows::desktop_changed() {
                        crate::platform::try_change_desktop();
                        c = None;
                        std::thread::sleep(spf);
                        continue;
                    }
                    if e.kind() != std::io::ErrorKind::WouldBlock {
                        // DXGI_ERROR_INVALID_CALL after each success on Microsoft GPU driver
                        // log::error!("capture frame failed: {:?}", e);
                        if c.as_ref().map(|c| c.is_gdi()) == Some(false) {
                            // nog gdi
                            dxgi_failed_times += 1;
                        }
                        if dxgi_failed_times > MAX_DXGI_FAIL_TIME {
                            c = None;
                            utils::set_wouldblock(&shmem, FALSE);
                            std::thread::sleep(spf);
                        }
                    } else {
                        utils::set_wouldblock(&shmem, TRUE);
                    }
                }
                _ => {
                    println!("unreachable!");
                }
            }
        }
    }

    #[tokio::main(flavor = "current_thread")]
    async fn run_ipc_client(ipc_token: String) {
        use DataPortableService::*;

        let postfix = IPC_SUFFIX;

        match ipc::connect(1000, postfix).await {
            Ok(mut stream) => {
                if let Err(err) =
                    ipc::portable_service_ipc_handshake_as_client(&mut stream, &ipc_token).await
                {
                    log::error!("portable service ipc handshake failed: {}", err);
                    *EXIT.lock().unwrap() = true;
                    return;
                }
                let mut timer =
                    crate::rustdesk_interval(tokio::time::interval(Duration::from_secs(1)));
                let mut nack = 0;
                loop {
                    if *EXIT.lock().unwrap() {
                        log::info!("Portable service EXIT signaled, closing ipc client loop");
                        stream
                            .send(&Data::DataPortableService(WillClose))
                            .await
                            .ok();
                        break;
                    }

                    tokio::select! {
                        res = stream.next() => {
                            match res {
                                Err(err) => {
                                    log::error!(
                                        "ipc{} connection closed: {}",
                                        postfix,
                                        err
                                    );
                                    break;
                                }
                                Ok(Some(Data::DataPortableService(data))) => match data {
                                    Ping => {
                                        allow_err!(
                                            stream
                                                .send(&Data::DataPortableService(Pong))
                                                .await
                                        );
                                    }
                                    Pong => {
                                        nack = 0;
                                    }
                                    ConnCount(Some(n)) => {
                                        if n == 0 {
                                            log::info!("Connection count equals 0, exit");
                                            stream.send(&Data::DataPortableService(WillClose)).await.ok();
                                            break;
                                        }
                                    }
                                    Mouse((v, conn, username, argb, simulate, show_cursor)) => {
                                        if let Ok(evt) = MouseEvent::parse_from_bytes(&v) {
                                            crate::input_service::handle_mouse_(&evt, conn, username, argb, simulate, show_cursor);
                                        }
                                    }
                                    Pointer((v, conn)) => {
                                        if let Ok(evt) = PointerDeviceEvent::parse_from_bytes(&v) {
                                            crate::input_service::handle_pointer_(&evt, conn);
                                        }
                                    }
                                    Key(v) => {
                                        if let Ok(evt) = KeyEvent::parse_from_bytes(&v) {
                                            crate::input_service::handle_key_(&evt);
                                        }
                                    }
                                    _ => {}
                                },
                                _ => {}
                            }
                        }
                        _ = timer.tick() => {
                            nack+=1;
                            if nack > MAX_NACK {
                                log::info!("max ping nack, exit");
                                break;
                            }
                            stream.send(&Data::DataPortableService(Ping)).await.ok();
                            stream.send(&Data::DataPortableService(ConnCount(None))).await.ok();
                        }
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to connect portable service ipc: {:?}", e);
            }
        }

        *EXIT.lock().unwrap() = true;
    }
}

// functions called in main process.
pub mod client {
    use super::*;
    use crate::display_service;
    use camellia_remote_protocol::{anyhow::Context, message_proto::PointerDeviceEvent};
    use scrap::PixelBuffer;

    lazy_static::lazy_static! {
        static ref RUNNING: Arc<Mutex<bool>> = Default::default();
        static ref STARTING: Arc<Mutex<bool>> = Default::default();
        static ref STARTING_TOKEN: AtomicU64 = AtomicU64::new(0);
        static ref CAPTURE_EPOCH: AtomicU32 = AtomicU32::new(0);
        static ref SHMEM: Arc<Mutex<Option<SharedMemory>>> = Default::default();
        static ref SHMEM_RUNTIME_NAME: Arc<Mutex<Option<String>>> = Default::default();
        static ref IPC_RUNTIME_TOKEN: Arc<Mutex<Option<String>>> = Default::default();
        static ref SENDER: Arc<PortableInputQueue> = client::start_ipc_server();
        static ref QUICK_SUPPORT: Arc<Mutex<bool>> = Default::default();
    }

    pub enum StartPara {
        Direct,
        Logon(String, String),
    }

    fn has_running_portable_service_process() -> bool {
        let app_exe = format!("{}.exe", crate::get_app_name().to_lowercase());
        !crate::platform::get_pids_of_process_with_first_arg(&app_exe, "--portable-service")
            .is_empty()
    }

    #[inline]
    fn next_portable_service_shmem_name() -> String {
        format!(
            "{}_{}_{:08x}",
            crate::portable_service::SHMEM_NAME,
            std::process::id(),
            camellia_remote_protocol::rand::random::<u32>()
        )
    }

    #[inline]
    fn set_runtime_ipc_token(token: String) {
        *IPC_RUNTIME_TOKEN.lock().unwrap() = Some(token);
    }

    #[inline]
    fn schedule_remove_runtime_shmem_flink_retry(name: String) {
        std::thread::spawn(move || {
            const MAX_RETRY: usize = 20;
            const RETRY_INTERVAL: Duration = Duration::from_millis(200);
            for _ in 0..MAX_RETRY {
                std::thread::sleep(RETRY_INTERVAL);
                if remove_shared_memory_flink_once(&name, false, "Client cleanup") {
                    return;
                }
            }
            log::warn!(
                "Failed to remove portable service shared-memory flink artifact '{}' after retry",
                name
            );
        });
    }

    #[inline]
    fn clear_runtime_shmem_state() {
        SENDER.cancel_and_clear();
        let mut runtime_token = IPC_RUNTIME_TOKEN.lock().unwrap();
        let mut shmem_lock = SHMEM.lock().unwrap();
        if let Some(shmem) = shmem_lock.as_mut() {
            clear_ipc_token_in_shmem(shmem);
        }
        *shmem_lock = None;
        let runtime_name = SHMEM_RUNTIME_NAME.lock().unwrap().take();
        *runtime_token = None;
        drop(runtime_token);
        drop(shmem_lock);
        if let Some(name) = runtime_name.as_deref() {
            if !remove_shared_memory_flink_once(name, true, "Client cleanup") {
                schedule_remove_runtime_shmem_flink_retry(name.to_owned());
            }
        }
    }

    #[inline]
    fn consume_runtime_ipc_token_if_match(candidate: &str) -> (bool, Option<String>) {
        let mut token = IPC_RUNTIME_TOKEN.lock().unwrap();
        if !token
            .as_deref()
            .is_some_and(|expected| ipc::constant_time_ipc_token_eq(expected, candidate))
        {
            return (false, None);
        }
        let mut shmem_lock = SHMEM.lock().unwrap();
        let matched_shmem_name = SHMEM_RUNTIME_NAME.lock().unwrap().clone();
        *token = None;
        if let Some(shmem) = shmem_lock.as_mut() {
            clear_ipc_token_in_shmem(shmem);
        }
        (true, matched_shmem_name)
    }

    #[inline]
    fn restore_runtime_ipc_token_after_failed_handshake(
        token: &str,
        expected_shmem_name: Option<&str>,
    ) {
        let mut runtime_token = IPC_RUNTIME_TOKEN.lock().unwrap();
        if let Some(current) = runtime_token.as_deref() {
            if current != token {
                log::debug!(
                    "Skip restoring portable service ipc token after handshake failure: runtime token has changed to a newer value"
                );
                return;
            }
        }
        let mut shmem_lock = SHMEM.lock().unwrap();
        let current_shmem_name = SHMEM_RUNTIME_NAME.lock().unwrap().clone();
        if current_shmem_name.as_deref() != expected_shmem_name {
            if runtime_token.as_deref() == Some(token) {
                *runtime_token = None;
            }
            log::debug!(
                "Skip restoring portable service ipc token after handshake failure: shared-memory instance has changed"
            );
            return;
        }
        let shmem_write_error = if let Some(shmem) = shmem_lock.as_mut() {
            write_ipc_token_to_shmem(shmem, token)
                .err()
                .map(|err| err.to_string())
        } else {
            Some("shared memory unavailable".to_owned())
        };
        if let Some(err) = shmem_write_error {
            if runtime_token.as_deref() == Some(token) {
                *runtime_token = None;
            }
            log::warn!(
                "Failed to restore portable service ipc token after handshake failure: {}",
                err
            );
            return;
        }
        *runtime_token = Some(token.to_owned());
    }

    #[inline]
    fn schedule_starting_timeout_reset(launch_token: u64) {
        std::thread::spawn(move || {
            std::thread::sleep(PORTABLE_SERVICE_STARTUP_TIMEOUT);
            let should_reset = {
                // Guard against stale watchdogs from previous launches:
                // only the watchdog that matches the latest STARTING_TOKEN may reset STARTING.
                let current_token = STARTING_TOKEN.load(Ordering::SeqCst);
                // Keep lock guards in explicit short scopes to make it obvious
                // there is no nested lock ordering (and to avoid Copilot false positives).
                let starting = { *STARTING.lock().unwrap() };
                let running = { *RUNNING.lock().unwrap() };
                current_token == launch_token && starting && !running
            };
            if should_reset {
                log::warn!(
                    "Portable service startup timeout before IPC ready, reset STARTING state"
                );
                *STARTING.lock().unwrap() = false;
            }
        });
    }

    // Launch flow summary:
    // 1) Prepare/reset runtime shared memory + IPC token.
    // 2) Start helper process (direct or logon) with shmem argument.
    // 3) Keep STARTING=true until IPC ping/pong marks RUNNING, or timeout watchdog resets it.
    pub(crate) fn start_portable_service(para: StartPara) -> ResultType<()> {
        log::info!("start portable service");
        let launch_token = {
            // Keep lock guards in explicit short scopes to make it obvious
            // there is no nested lock ordering (and to avoid Copilot false positives).
            let running = { *RUNNING.lock().unwrap() };
            let mut starting = STARTING.lock().unwrap();
            if *starting && !running && !has_running_portable_service_process() {
                log::warn!(
                    "Detected stale portable service STARTING state without running process, reset it"
                );
                *starting = false;
            }
            if *starting || running {
                bail!("already running");
            }
            *starting = true;
            STARTING_TOKEN.fetch_add(1, Ordering::SeqCst) + 1
        };
        let start_result = (|| -> ResultType<()> {
            clear_runtime_shmem_state();
            let mut shmem_lock = SHMEM.lock().unwrap();
            let displays = scrap::Display::all()?;
            if displays.is_empty() {
                bail!("no display available!");
            }
            let mut max_pixel = 0;
            let align = 64;
            for d in displays {
                let resolutions = crate::platform::resolutions(&d.name());
                for r in resolutions {
                    let pixel =
                        utils::align(r.width as _, align) * utils::align(r.height as _, align);
                    if max_pixel < pixel {
                        max_pixel = pixel;
                    }
                }
            }
            let shmem_size =
                utils::align(ADDR_CAPTURE_FRAME + max_pixel * 4, align).max(MIN_RUNTIME_SHMEM_LEN);
            let shmem_name = next_portable_service_shmem_name();
            if !is_valid_portable_service_shmem_name(&shmem_name) {
                bail!("Generated invalid portable service shared memory name");
            }
            let ipc_token = ipc::generate_one_time_ipc_token()?;
            // os error 112, no enough space
            *shmem_lock = Some(crate::portable_service::SharedMemory::create(
                &shmem_name,
                shmem_size,
            )?);
            *SHMEM_RUNTIME_NAME.lock().unwrap() = Some(shmem_name);
            shutdown_hooks::add_shutdown_hook(drop_portable_service_shared_memory);
            let shmem_name = SHMEM_RUNTIME_NAME
                .lock()
                .unwrap()
                .clone()
                .ok_or_else(|| anyhow!("portable service shared memory name is unavailable"))?;
            let init_token_result = if let Some(shmem) = shmem_lock.as_mut() {
                unsafe {
                    libc::memset(shmem.as_ptr() as _, 0, shmem.len() as _);
                }
                initialize_runtime_shmem_layout(shmem)
                    .and_then(|()| write_ipc_token_to_shmem(shmem, &ipc_token))
            } else {
                Ok(())
            };
            if let Err(e) = init_token_result {
                drop(shmem_lock);
                clear_runtime_shmem_state();
                bail!(
                    "Failed to initialize portable service ipc token in shared memory: {}",
                    e
                );
            };
            drop(shmem_lock);
            set_runtime_ipc_token(ipc_token.clone());
            let portable_service_arg = format!(
                "--portable-service {}",
                crate::portable_service::portable_service_shmem_arg(&shmem_name)
            );
            {
                let _sender = SENDER.clone();
            }
            match para {
                StartPara::Direct => {
                    match crate::platform::run_background(
                        &std::env::current_exe()?.to_string_lossy().to_string(),
                        &portable_service_arg,
                    ) {
                        Ok(true) => {}
                        Ok(false) => {
                            clear_runtime_shmem_state();
                            bail!("Failed to run portable service process");
                        }
                        Err(e) => {
                            clear_runtime_shmem_state();
                            bail!("Failed to run portable service process: {}", e);
                        }
                    }
                }
                StartPara::Logon(username, password) => {
                    let exe = std::env::current_exe()?.to_string_lossy().to_string();
                    #[cfg(feature = "flutter")]
                    {
                        if let Some(dir) = Path::new(&exe).parent() {
                            if let Err(err) = set_path_permission(
                                Path::new(dir),
                                FILE_GENERIC_READ.0 | FILE_GENERIC_EXECUTE.0,
                            ) {
                                clear_runtime_shmem_state();
                                bail!("Failed to set permission of {:?}: {}", dir, err);
                            }
                        }
                    }
                    if let Err(e) = crate::platform::windows::create_process_with_logon(
                        username.as_str(),
                        password.as_str(),
                        &exe,
                        &portable_service_arg,
                    ) {
                        clear_runtime_shmem_state();
                        bail!("Failed to run portable service process: {}", e);
                    }
                }
            }
            schedule_starting_timeout_reset(launch_token);
            Ok(())
        })();
        if start_result.is_err() {
            *STARTING.lock().unwrap() = false;
        }
        start_result
    }

    pub extern "C" fn drop_portable_service_shared_memory() {
        // https://stackoverflow.com/questions/35980148/why-does-an-atexit-handler-panic-when-it-accesses-stdout
        // Please make sure there is no print in the call stack
        clear_runtime_shmem_state();
    }

    pub fn set_quick_support(v: bool) {
        *QUICK_SUPPORT.lock().unwrap() = v;
    }

    pub struct CapturerPortable {
        width: usize,
        height: usize,
        current_display: u32,
        capture_epoch: u32,
        timeout_ms: i32,
        frame_data: Vec<u8>,
    }

    impl CapturerPortable {
        pub fn new(current_display: usize) -> Self
        where
            Self: Sized,
        {
            let current_display_wire = u32::try_from(current_display).unwrap_or(u32::MAX);
            let previous_capture_epoch = CAPTURE_EPOCH
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |value| {
                    Some(if value == u32::MAX { 1 } else { value + 1 })
                })
                .unwrap_or(0);
            let capture_epoch = if previous_capture_epoch == u32::MAX {
                1
            } else {
                previous_capture_epoch + 1
            };
            let mut option = SHMEM.lock().unwrap();
            if let Some(shmem) = option.as_mut() {
                utils::set_para(
                    shmem,
                    CaptureParameters {
                        capture_epoch,
                        current_display: current_display_wire,
                        timeout_ms: 33,
                    },
                );
                utils::set_wouldblock(shmem, TRUE);
            }
            let (mut width, mut height) = (0, 0);
            if let Ok(displays) = display_service::try_get_displays() {
                if let Some(display) = displays.get(current_display) {
                    width = display.width();
                    height = display.height();
                }
            }
            CapturerPortable {
                width,
                height,
                current_display: current_display_wire,
                capture_epoch,
                timeout_ms: 33,
                frame_data: Vec::new(),
            }
        }
    }

    impl TraitCapturer for CapturerPortable {
        fn frame<'a>(&'a mut self, timeout: Duration) -> std::io::Result<Frame<'a>> {
            let mut lock = SHMEM.lock().unwrap();
            let shmem = lock.as_mut().ok_or(std::io::Error::new(
                std::io::ErrorKind::Other,
                "shmem dropped".to_string(),
            ))?;
            let base = shmem.as_ptr();
            if timeout.as_millis() != self.timeout_ms as u128 {
                if let Ok(timeout_ms) = i32::try_from(timeout.as_millis()) {
                    self.timeout_ms = timeout_ms;
                    utils::set_para(
                        shmem,
                        CaptureParameters {
                            capture_epoch: self.capture_epoch,
                            current_display: self.current_display,
                            timeout_ms,
                        },
                    );
                }
            }
            let frame_counter = utils::counter(shmem, ADDR_CAPTURE_FRAME_COUNTER);
            let frame_result = if let Some(_read_guard) = frame_counter.try_acquire() {
                let frame_info = utils::read_frame_info(shmem);
                let Ok(frame_len) = usize::try_from(frame_info.length) else {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "invalid portable service frame length".to_string(),
                    ));
                };
                if !is_valid_capture_frame_length(shmem.len(), frame_len) {
                    log::error!(
                        "Portable service frame length exceeds shared memory capacity: frame_len={}, shmem_len={}, frame_addr={}",
                        frame_len,
                        shmem.len(),
                        ADDR_CAPTURE_FRAME
                    );
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "invalid portable service frame length".to_string(),
                    ));
                }
                if frame_info.width != self.width as u64 || frame_info.height != self.height as u64
                {
                    log::info!(
                        "skip frame, ({},{}) != ({},{})",
                        frame_info.width,
                        frame_info.height,
                        self.width,
                        self.height,
                    );
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::WouldBlock,
                        "wouldblock error".to_string(),
                    ));
                }
                self.frame_data.resize(frame_len, 0);
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        base.add(ADDR_CAPTURE_FRAME),
                        self.frame_data.as_mut_ptr(),
                        frame_len,
                    );
                }
                Ok(Frame::PixelBuffer(PixelBuffer::with_BGRA(
                    &self.frame_data,
                    self.width,
                    self.height,
                )))
            } else if utils::wouldblock(shmem) == TRUE {
                Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "wouldblock error".to_string(),
                ))
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    "other error".to_string(),
                ))
            };
            frame_result
        }

        // control by itself
        fn is_gdi(&self) -> bool {
            true
        }

        fn set_gdi(&mut self) -> bool {
            true
        }

        #[cfg(feature = "vram")]
        fn device(&self) -> AdapterDevice {
            AdapterDevice::default()
        }

        #[cfg(feature = "vram")]
        fn set_output_texture(&mut self, _texture: bool) {}
    }

    pub(super) fn start_ipc_server() -> Arc<PortableInputQueue> {
        let queue = Arc::new(PortableInputQueue::new(PORTABLE_IPC_QUEUE_CAPACITY));
        let queue_clone = queue.clone();
        std::thread::spawn(move || start_ipc_server_async(queue_clone));
        queue
    }

    #[tokio::main(flavor = "current_thread")]
    async fn start_ipc_server_async(queue: Arc<PortableInputQueue>) {
        use DataPortableService::*;
        let postfix = IPC_SUFFIX;
        let quick_support = QUICK_SUPPORT.lock().unwrap().clone();

        match new_listener(postfix).await {
            Ok(mut incoming) => loop {
                {
                    tokio::select! {
                        Some(result) = incoming.next() => {
                            match result {
                                Ok(stream) => {
                                    let mut stream = Connection::new(stream);
                                    if !ipc::authorize_windows_portable_service_ipc_connection(
                                        &stream, postfix,
                                    ) {
                                        continue;
                                    }
                                    let mut consumed_token: Option<String> = None;
                                    let mut consumed_token_shmem_name: Option<String> = None;
                                    let handshake_result =
                                        ipc::portable_service_ipc_handshake_as_server(
                                            &mut stream,
                                            |token| {
                                                let (matched, matched_shmem_name) =
                                                    consume_runtime_ipc_token_if_match(token);
                                                if matched {
                                                    consumed_token = Some(token.to_owned());
                                                    consumed_token_shmem_name = matched_shmem_name;
                                                    true
                                                } else {
                                                    false
                                                }
                                            },
                                        )
                                        .await;
                                    if let Err(err) = handshake_result {
                                        if let Some(token) = consumed_token.as_deref() {
                                            restore_runtime_ipc_token_after_failed_handshake(
                                                token,
                                                consumed_token_shmem_name.as_deref(),
                                            );
                                            *STARTING.lock().unwrap() = false;
                                        }
                                        log::warn!(
                                            "Rejected portable service ipc connection due to token handshake failure: postfix={}, err={}",
                                            postfix,
                                            err
                                        );
                                        continue;
                                    }
                                    log::info!("Got portable service ipc connection");
                                    let queue_clone = queue.clone();
                                    tokio::spawn(async move {
                                        let mut stream = stream;
                                        let postfix = postfix.to_owned();
                                        let mut timer = crate::rustdesk_interval(tokio::time::interval(Duration::from_secs(1)));
                                        let mut nack = 0;
                                        loop {
                                            tokio::select! {
                                                res = stream.next() => {
                                                    match res {
                                                        Err(err) => {
                                                            log::info!(
                                                                 "ipc{} connection closed: {}",
                                                                 postfix,
                                                                 err
                                                            );
                                                            break;
                                                        }
                                                        Ok(Some(Data::DataPortableService(data))) => match data {
                                                            Ping => {
                                                                stream.send(&Data::DataPortableService(Pong)).await.ok();
                                                            }
                                                            Pong => {
                                                                nack = 0;
                                                                *RUNNING.lock().unwrap() = true;
                                                                *STARTING.lock().unwrap() = false;
                                                            },
                                                            ConnCount(None) => {
                                                                if !quick_support {
                                                                    let remote_count = crate::server::AUTHED_CONNS
                                                                        .lock()
                                                                        .unwrap()
                                                                        .iter()
                                                                        .filter(|c| c.conn_type == crate::server::AuthConnType::Remote)
                                                                        .count();
                                                                    stream.send(&Data::DataPortableService(ConnCount(Some(remote_count)))).await.ok();
                                                                }
                                                            },
                                                            WillClose => {
                                                                log::info!("portable service will close");
                                                                break;
                                                            }
                                                            _=>{}
                                                        }
                                                        _=>{}
                                                    }
                                                }
                                                _ = timer.tick() => {
                                                    nack+=1;
                                                    if nack > MAX_NACK {
                                                        // In fact, this will not happen, ipc will be closed before max nack.
                                                        log::error!("max ipc nack");
                                                        break;
                                                    }
                                                    stream.send(&Data::DataPortableService(Ping)).await.ok();
                                                }
                                                Some(data) = queue_clone.recv() => {
                                                    allow_err!(stream.send(&data).await);
                                                }
                                            }
                                        }
                                        *RUNNING.lock().unwrap() = false;
                                        *STARTING.lock().unwrap() = false;
                                        queue_clone.cancel_and_clear();
                                    });
                                }
                                Err(err) => {
                                    log::error!("Couldn't get portable client: {:?}", err);
                                }
                            }
                        }
                    }
                }
            },
            Err(err) => {
                log::error!("Failed to start portable service ipc server: {}", err);
            }
        }
    }

    fn ipc_send(data: Data) -> ResultType<()> {
        SENDER.send(data)
    }

    fn get_cursor_info_(shmem: &mut SharedMemory, pci: PCURSORINFO) -> BOOL {
        unsafe {
            let shmem_addr_para = shmem.as_ptr().add(ADDR_CURSOR_PARA);
            let counter = utils::counter(shmem, ADDR_CURSOR_COUNTER);
            if let Some(_read_guard) = counter.try_acquire() {
                std::ptr::copy_nonoverlapping(shmem_addr_para, pci as _, size_of::<CURSORINFO>());
                return TRUE;
            }
            FALSE
        }
    }

    fn handle_mouse_(
        evt: &MouseEvent,
        conn: i32,
        username: String,
        argb: u32,
        simulate: bool,
        show_cursor: bool,
    ) -> ResultType<()> {
        let mut v = vec![];
        evt.write_to_vec(&mut v)?;
        ipc_send(Data::DataPortableService(DataPortableService::Mouse((
            v,
            conn,
            username,
            argb,
            simulate,
            show_cursor,
        ))))
    }

    fn handle_pointer_(evt: &PointerDeviceEvent, conn: i32) -> ResultType<()> {
        let mut v = vec![];
        evt.write_to_vec(&mut v)?;
        ipc_send(Data::DataPortableService(DataPortableService::Pointer((
            v, conn,
        ))))
    }

    fn handle_key_(evt: &KeyEvent) -> ResultType<()> {
        let mut v = vec![];
        evt.write_to_vec(&mut v)?;
        ipc_send(Data::DataPortableService(DataPortableService::Key(v)))
    }

    pub fn create_capturer(
        current_display: usize,
        display: scrap::Display,
        portable_service_running: bool,
    ) -> ResultType<Box<dyn TraitCapturer>> {
        if portable_service_running != RUNNING.lock().unwrap().clone() {
            log::info!("portable service status mismatch");
        }
        if portable_service_running && display.is_primary() {
            log::info!("Create shared memory capturer");
            return Ok(Box::new(CapturerPortable::new(current_display)));
        } else {
            log::debug!("Create capturer dxgi|gdi");
            return Ok(Box::new(
                Capturer::new(display).with_context(|| "Failed to create capturer")?,
            ));
        }
    }

    pub fn get_cursor_info(pci: PCURSORINFO) -> BOOL {
        if RUNNING.lock().unwrap().clone() {
            let mut option = SHMEM.lock().unwrap();
            option
                .as_mut()
                .map_or(FALSE, |sheme| get_cursor_info_(sheme, pci))
        } else {
            unsafe { winuser::GetCursorInfo(pci) }
        }
    }

    pub fn handle_mouse(
        evt: &MouseEvent,
        conn: i32,
        username: String,
        argb: u32,
        simulate: bool,
        show_cursor: bool,
    ) {
        if RUNNING.lock().unwrap().clone() {
            crate::input_service::update_latest_input_cursor_time(conn);
            handle_mouse_(evt, conn, username, argb, simulate, show_cursor).ok();
        } else {
            crate::input_service::handle_mouse_(evt, conn, username, argb, simulate, show_cursor);
        }
    }

    pub fn handle_pointer(evt: &PointerDeviceEvent, conn: i32) {
        if RUNNING.lock().unwrap().clone() {
            crate::input_service::update_latest_input_cursor_time(conn);
            handle_pointer_(evt, conn).ok();
        } else {
            crate::input_service::handle_pointer_(evt, conn);
        }
    }

    pub fn handle_key(evt: &KeyEvent) {
        if RUNNING.lock().unwrap().clone() {
            handle_key_(evt).ok();
        } else {
            crate::input_service::handle_key_(evt);
        }
    }

    pub fn running() -> bool {
        RUNNING.lock().unwrap().clone()
    }
}

#[repr(C)]
pub struct FrameInfo {
    length: u64,
    width: u64,
    height: u64,
}

#[cfg(test)]
mod tests {
    use super::{
        is_valid_capture_frame_length, FrameInfo, RuntimeShmemHeader, SharedCaptureParameters,
        SharedSlotCounter, ADDR_CAPTURER_PARA, ADDR_CAPTURE_FRAME, ADDR_CAPTURE_FRAME_COUNTER,
        ADDR_CAPTURE_FRAME_INFO, ADDR_CURSOR_COUNTER, ADDR_CURSOR_PARA, ADDR_RUNTIME_HEADER,
    };
    use std::mem::{align_of, size_of};

    #[test]
    fn runtime_layout_regions_are_ordered_and_atomically_aligned() {
        assert_eq!(size_of::<RuntimeShmemHeader>(), 32);
        assert_eq!(ADDR_RUNTIME_HEADER % align_of::<RuntimeShmemHeader>(), 0);
        assert!(ADDR_RUNTIME_HEADER + size_of::<RuntimeShmemHeader>() <= ADDR_CURSOR_PARA);
        assert_eq!(ADDR_CURSOR_COUNTER % align_of::<SharedSlotCounter>(), 0);
        assert_eq!(
            ADDR_CAPTURER_PARA % align_of::<SharedCaptureParameters>(),
            0
        );
        assert!(
            ADDR_CAPTURER_PARA + size_of::<SharedCaptureParameters>() <= ADDR_CAPTURE_FRAME_INFO
        );
        assert!(ADDR_CAPTURE_FRAME_INFO + size_of::<FrameInfo>() <= ADDR_CAPTURE_FRAME_COUNTER);
        assert_eq!(
            ADDR_CAPTURE_FRAME_COUNTER % align_of::<SharedSlotCounter>(),
            0
        );
        assert_eq!(ADDR_CAPTURE_FRAME % 64, 0);
    }

    #[test]
    fn test_is_valid_capture_frame_length_rejects_zero_length() {
        assert!(!is_valid_capture_frame_length(ADDR_CAPTURE_FRAME + 1024, 0));
    }

    #[test]
    fn test_is_valid_capture_frame_length_rejects_out_of_bounds_length() {
        assert!(!is_valid_capture_frame_length(ADDR_CAPTURE_FRAME + 16, 17));
    }

    #[test]
    fn test_is_valid_capture_frame_length_accepts_in_bounds_length() {
        assert!(is_valid_capture_frame_length(ADDR_CAPTURE_FRAME + 16, 16));
    }
}
