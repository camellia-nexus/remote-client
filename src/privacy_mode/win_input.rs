use camellia_remote_protocol::{bail, lazy_static, log, ResultType};
use std::{
    io::Error,
    sync::{
        mpsc::{channel, Sender},
        Mutex,
    },
    thread::JoinHandle,
    time::Duration,
};
use winapi::{
    ctypes::c_int,
    shared::{
        minwindef::{DWORD, FALSE, HMODULE, LOBYTE, LPARAM, LRESULT, UINT, WPARAM},
        ntdef::NULL,
        windef::{HHOOK, POINT},
    },
    um::{
        libloaderapi::{
            GetModuleHandleExA, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        },
        processthreadsapi::GetCurrentThreadId,
        winuser::*,
    },
};

const WM_USER_EXIT_HOOK: u32 = WM_USER + 1;

struct HookWorker {
    thread_id: DWORD,
    join_handle: Option<JoinHandle<ResultType<()>>>,
}

enum HookState {
    Uninstalled,
    Active(HookWorker),
}

lazy_static::lazy_static! {
    static ref HOOK_STATE: Mutex<HookState> = Mutex::new(HookState::Uninstalled);
}

pub fn is_hooked() -> bool {
    let state = HOOK_STATE.lock().unwrap();
    matches!(*state, HookState::Active(_))
}

fn bounded_join_thread(handle: JoinHandle<ResultType<()>>, timeout: Duration) {
    let (join_tx, join_rx) = channel();
    std::thread::spawn(move || {
        let res = handle.join();
        let _ = join_tx.send(res);
    });
    match join_rx.recv_timeout(timeout) {
        Ok(Ok(_)) => {
            log::debug!("Hook worker thread cleanly joined.");
        }
        Ok(Err(panic_err)) => {
            log::error!("Hook worker thread panicked: {:?}", panic_err);
        }
        Err(_) => {
            log::warn!(
                "Timed out waiting for hook worker thread to join ({:?} deadline exceeded)",
                timeout
            );
        }
    }
}

fn init_hooks(ready_tx: &Sender<ResultType<DWORD>>) -> ResultType<(DWORD, (HHOOK, HHOOK))> {
    unsafe {
        let thread_id = GetCurrentThreadId();

        // 1. Force Windows to instantiate message queue for this thread BEFORE signaling ready.
        // This eliminates ERROR_INVALID_THREAD_ID (1444) on subsequent PostThreadMessage calls.
        let mut peek_msg: MSG = std::mem::zeroed();
        PeekMessageA(&mut peek_msg, NULL as _, WM_USER, WM_USER, PM_NOREMOVE);

        // 2. Resolve modules
        let mut hm_keyboard = 0 as HMODULE;
        if 0 == GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            DefWindowProcA as _,
            &mut hm_keyboard as _,
        ) {
            bail!(
                "Failed to GetModuleHandleExA for keyboard: {}",
                Error::last_os_error()
            );
        }

        let mut hm_mouse = 0 as HMODULE;
        if 0 == GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            DefWindowProcA as _,
            &mut hm_mouse as _,
        ) {
            bail!(
                "Failed to GetModuleHandleExA for mouse: {}",
                Error::last_os_error()
            );
        }

        // 3. Install low-level keyboard hook
        let hook_keyboard = SetWindowsHookExA(
            WH_KEYBOARD_LL,
            Some(privacy_mode_hook_keyboard),
            hm_keyboard,
            0,
        );
        if hook_keyboard.is_null() {
            bail!(
                "SetWindowsHookExA keyboard error: {}",
                Error::last_os_error()
            );
        }

        // 4. Install low-level mouse hook
        let hook_mouse = SetWindowsHookExA(WH_MOUSE_LL, Some(privacy_mode_hook_mouse), hm_mouse, 0);
        if hook_mouse.is_null() {
            let _ = UnhookWindowsHookEx(hook_keyboard);
            bail!("SetWindowsHookExA mouse error: {}", Error::last_os_error());
        }

        // 5. Send ready handshake with thread ID.
        // If the receiving end has dropped (parent timed out or cancelled),
        // immediately unhook both hooks and abort to avoid leaving an orphaned hook worker.
        if let Err(e) = ready_tx.send(Ok(thread_id)) {
            if FALSE == UnhookWindowsHookEx(hook_keyboard) {
                log::error!(
                    "Failed UnhookWindowsHookEx keyboard during abortive handshake: {}",
                    Error::last_os_error()
                );
            }
            if FALSE == UnhookWindowsHookEx(hook_mouse) {
                log::error!(
                    "Failed UnhookWindowsHookEx mouse during abortive handshake: {}",
                    Error::last_os_error()
                );
            }
            bail!(
                "Failed to send ready handshake (parent timed out or dropped receiver): {}",
                e
            );
        }
        Ok((thread_id, (hook_keyboard, hook_mouse)))
    }
}

pub fn hook() -> ResultType<()> {
    let mut lock = HOOK_STATE.lock().unwrap();

    // If an existing hook worker is running or lingering, cleanly join and unhook it first (eliminates rapid-toggle collision!)
    if let HookState::Active(_) = &*lock {
        internal_unhook_locked(&mut lock)?;
    }

    let (ready_tx, ready_rx) = channel::<ResultType<DWORD>>();

    let join_handle = std::thread::spawn(move || {
        let (thread_id, hooks) = match init_hooks(&ready_tx) {
            Ok(res) => res,
            Err(e) => {
                let _ = ready_tx.send(Err(e));
                return Ok(());
            }
        };

        log::debug!("Input hook worker thread started: {}", thread_id);

        let mut msg = MSG {
            hwnd: NULL as _,
            message: 0 as _,
            wParam: 0 as _,
            lParam: 0 as _,
            time: 0 as _,
            pt: POINT {
                x: 0 as _,
                y: 0 as _,
            },
        };

        unsafe {
            while FALSE != GetMessageA(&mut msg, NULL as _, 0, 0) {
                if msg.message == WM_USER_EXIT_HOOK {
                    break;
                }

                TranslateMessage(&msg);
                DispatchMessageA(&msg);
            }

            if FALSE == UnhookWindowsHookEx(hooks.0) {
                log::error!(
                    "Failed UnhookWindowsHookEx keyboard, error {}",
                    Error::last_os_error()
                );
            }

            if FALSE == UnhookWindowsHookEx(hooks.1) {
                log::error!(
                    "Failed UnhookWindowsHookEx mouse, error {}",
                    Error::last_os_error()
                );
            }
        }

        log::debug!("Input hook worker thread exited: {}", thread_id);
        Ok(())
    });

    // Bounded wait for ready handshake
    let thread_id = match ready_rx.recv_timeout(Duration::from_millis(3000)) {
        Ok(Ok(tid)) => tid,
        Ok(Err(e)) => {
            bounded_join_thread(join_handle, Duration::from_millis(2000));
            bail!("Input hook initialization failed: {}", e);
        }
        Err(e) => {
            // If the handshake arrived right as timeout fired, retrieve tid to cleanly post exit message
            if let Ok(Ok(tid)) = ready_rx.try_recv() {
                unsafe {
                    PostThreadMessageA(tid, WM_USER_EXIT_HOOK, 0, 0);
                }
            }
            drop(ready_rx);
            bounded_join_thread(join_handle, Duration::from_millis(2000));
            bail!("Input hook handshake timed out: {}", e);
        }
    };

    *lock = HookState::Active(HookWorker {
        thread_id,
        join_handle: Some(join_handle),
    });

    Ok(())
}

pub fn unhook() -> ResultType<()> {
    let mut lock = HOOK_STATE.lock().unwrap();
    internal_unhook_locked(&mut lock)
}

fn internal_unhook_locked(lock: &mut HookState) -> ResultType<()> {
    let worker = match std::mem::replace(lock, HookState::Uninstalled) {
        HookState::Active(w) => w,
        HookState::Uninstalled => return Ok(()),
    };

    let cur_tid = unsafe { GetCurrentThreadId() };

    unsafe {
        if FALSE == PostThreadMessageA(worker.thread_id, WM_USER_EXIT_HOOK, 0, 0) {
            log::warn!(
                "PostThreadMessageA exit signal to thread {} failed: {}",
                worker.thread_id,
                Error::last_os_error()
            );
        }
    }

    // Deadlock Prevention: if unhook() is called from within the hook thread itself (Ctrl+P callback),
    // skip self-join!
    if worker.thread_id == cur_tid {
        log::info!(
            "Unhook called from within hook worker thread; skipping self-join to prevent deadlock."
        );
        return Ok(());
    }

    if let Some(handle) = worker.join_handle {
        bounded_join_thread(handle, Duration::from_millis(2000));
    }

    Ok(())
}

#[no_mangle]
pub extern "system" fn privacy_mode_hook_keyboard(
    code: c_int,
    w_param: WPARAM,
    l_param: LPARAM,
) -> LRESULT {
    if code < 0 {
        unsafe {
            return CallNextHookEx(NULL as _, code, w_param, l_param);
        }
    }

    let ks = l_param as PKBDLLHOOKSTRUCT;
    let w_param2 = w_param as UINT;

    unsafe {
        if (*ks).dwExtraInfo != enigo::ENIGO_INPUT_EXTRA_VALUE {
            // Check for Ctrl + P exit combination
            if w_param2 == WM_KEYDOWN || w_param2 == WM_SYSKEYDOWN {
                let ctrl_down = (GetKeyState(VK_CONTROL) as u16) & 0x8000 > 0;
                let key = LOBYTE((*ks).vkCode as _);
                if ctrl_down && (key == b'p' || key == b'P') {
                    // Ctrl + P is pressed, turn off privacy mode
                    if let Some(Err(e)) = super::turn_off_privacy(
                        super::INVALID_PRIVACY_MODE_CONN_ID,
                        Some(super::PrivacyModeState::OffByPeer),
                    ) {
                        log::error!("Failed to off_privacy via Ctrl+P shortcut: {}", e);
                    }
                    return 1;
                }
            }

            // Complete keyboard event suppression:
            // Block all other local key events (WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP)
            return 1;
        }
    }
    unsafe { CallNextHookEx(NULL as _, code, w_param, l_param) }
}

#[no_mangle]
pub extern "system" fn privacy_mode_hook_mouse(
    code: c_int,
    w_param: WPARAM,
    l_param: LPARAM,
) -> LRESULT {
    if code < 0 {
        unsafe {
            return CallNextHookEx(NULL as _, code, w_param, l_param);
        }
    }

    let ms = l_param as PMOUSEHOOKSTRUCT;
    unsafe {
        if (*ms).dwExtraInfo != enigo::ENIGO_INPUT_EXTRA_VALUE {
            return 1;
        }
    }
    unsafe { CallNextHookEx(NULL as _, code, w_param, l_param) }
}
