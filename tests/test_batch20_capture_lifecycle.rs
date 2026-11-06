// Client Batch 20 Display Capture Lifecycle & Hardening Tests (PRIV-007, PLATFORM-005, RES-030, RES-031)

use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

// =========================================================================
// 1. PRIV-007: Linux X11 SHM Minimal Permissions (0o600) & Immediate RMID
// =========================================================================

#[test]
#[cfg(target_os = "linux")]
fn test_x11_shm_permission_and_rmid_lifecycle() {
    use camellia_remote_protocol::libc;
    use std::ptr;

    unsafe {
        let size = 4096usize;
        // Verify creation with minimal secure 0o600 permissions
        let shmid = libc::shmget(libc::IPC_PRIVATE, size, libc::IPC_CREAT | 0o600);
        assert!(
            shmid >= 0,
            "shmget with 0o600 failed: {}",
            std::io::Error::last_os_error()
        );

        // Attach segment
        let addr = libc::shmat(shmid, ptr::null(), libc::SHM_RDONLY);
        assert_ne!(
            addr as isize,
            -1,
            "shmat failed: {}",
            std::io::Error::last_os_error()
        );

        // Verify segment permissions via shmctl(IPC_STAT)
        let mut ds: libc::shmid_ds = std::mem::zeroed();
        let stat_res = libc::shmctl(shmid, libc::IPC_STAT, &mut ds);
        assert_eq!(stat_res, 0, "shmctl IPC_STAT failed");
        assert_eq!(
            ds.shm_perm.mode & 0o777,
            0o600,
            "Shared memory segment mode must be 0o600, not world-accessible"
        );
        assert_eq!(ds.shm_nattch, 1, "shm_nattch must be 1 while attached");

        // Call IPC_RMID immediately while still attached (PRIV-007 specification requirement)
        let rmid_res = libc::shmctl(shmid, libc::IPC_RMID, ptr::null_mut());
        assert_eq!(rmid_res, 0, "Immediate shmctl IPC_RMID must succeed");

        // Detach segment: kernel should now auto-reclaim the segment since attach count becomes 0
        let dt_res = libc::shmdt(addr);
        assert_eq!(dt_res, 0, "shmdt failed");

        // Verify segment is destroyed: subsequent shmat with shmid must fail
        let post_attach = libc::shmat(shmid, ptr::null(), libc::SHM_RDONLY);
        assert_eq!(
            post_attach as isize, -1,
            "shmat must fail on destroyed segment after last detach"
        );
    }
}

#[test]
#[cfg(target_os = "linux")]
fn test_x11_shm_segment_guard_error_raii_cleanup() {
    use camellia_remote_protocol::libc;
    use std::ptr;

    struct TestShmGuard {
        shmid: i32,
        buffer: *mut u8,
        active: bool,
    }

    impl Drop for TestShmGuard {
        fn drop(&mut self) {
            if self.active {
                unsafe {
                    if !self.buffer.is_null() && self.buffer as isize != -1 {
                        libc::shmdt(self.buffer as *mut _);
                    }
                    if self.shmid != -1 {
                        libc::shmctl(self.shmid, libc::IPC_RMID, ptr::null_mut());
                    }
                }
            }
        }
    }

    unsafe {
        let size = 4096usize;
        let shmid = libc::shmget(libc::IPC_PRIVATE, size, libc::IPC_CREAT | 0o600);
        assert!(shmid >= 0);

        let buffer = libc::shmat(shmid, ptr::null(), libc::SHM_RDONLY) as *mut u8;
        assert_ne!(buffer as isize, -1);

        {
            let guard = TestShmGuard {
                shmid,
                buffer,
                active: true,
            };
            // Simulate an early return / error during initialization while guard is active
            drop(guard);
        }

        // Verify that after guard dropped on error, the segment was detached and marked IPC_RMID
        let mut ds: libc::shmid_ds = std::mem::zeroed();
        let stat_res = libc::shmctl(shmid, libc::IPC_STAT, &mut ds);
        // Either IPC_STAT fails with EINVAL (segment fully reclaimed) or nattch is 0 and mode reflects destruction
        if stat_res == 0 {
            assert_eq!(
                ds.shm_nattch, 0,
                "Attach count must be 0 after guard dropped"
            );
        }
        let post_attach = libc::shmat(shmid, ptr::null(), libc::SHM_RDONLY);
        assert_eq!(
            post_attach as isize, -1,
            "shmat must fail on destroyed segment after guard error cleanup"
        );
    }
}

#[test]
fn test_x11_capturer_shm_permission_and_checked_attach_source_analysis() {
    let capturer_file =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src/x11/capturer.rs");
    assert!(capturer_file.exists(), "x11/capturer.rs must exist");

    let content = std::fs::read_to_string(&capturer_file).unwrap();

    // PRIV-007: Must use 0o600 permissions
    assert!(
        content.contains("libc::IPC_CREAT | 0o600"),
        "capturer.rs must create shared memory with 0o600 permissions"
    );
    assert!(
        !content.contains("0o777"),
        "capturer.rs must not contain insecure 0o777 permissions"
    );

    // PRIV-007: Immediate IPC_RMID after attach
    let attach_checked_idx = content
        .find("xcb_shm_attach_checked")
        .expect("Must use xcb_shm_attach_checked");
    let immediate_rmid_idx = content
        .find("libc::shmctl(shmid, libc::IPC_RMID, ptr::null_mut())")
        .expect("Must call IPC_RMID immediately after attach");
    assert!(
        attach_checked_idx < immediate_rmid_idx,
        "IPC_RMID must be called after xcb_shm_attach_checked verification"
    );

    // PRIV-007: RAII guard ensuring shmdt and shmctl on error branches
    assert!(
        content.contains("struct ShmSegmentGuard"),
        "capturer.rs must use ShmSegmentGuard for error-branch RAII cleanup"
    );
    assert!(
        content.contains("impl Drop for ShmSegmentGuard"),
        "ShmSegmentGuard must implement Drop"
    );

    // PLATFORM-005: xcb_request_check must verify error cookie
    assert!(
        content.contains("xcb_request_check(server, cookie)"),
        "Capturer::new must check error cookie with xcb_request_check"
    );

    // PLATFORM-005: get_image returns io::Result<()> and checks response / errors
    assert!(
        content.contains("fn get_image(&self) -> io::Result<()>"),
        "get_image must return io::Result<()>"
    );
    assert!(
        content.contains("if !err.is_null()"),
        "get_image must check if X11 error is non-null"
    );
    assert!(
        content.contains("if response.is_null()"),
        "get_image must check if response is null"
    );
    assert!(
        content.contains("self.get_image()?;"),
        "frame() must bubble get_image error with ?"
    );

    // PLATFORM-005 / PRIV-007: Drop must flush xcb connection after detach
    assert!(
        content.contains("xcb_flush(server);"),
        "Capturer::drop must call xcb_flush after xcb_shm_detach"
    );
}

#[test]
fn test_x11_ffi_checked_symbols_declared() {
    let ffi_file = Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src/x11/ffi.rs");
    assert!(ffi_file.exists(), "x11/ffi.rs must exist");

    let content = std::fs::read_to_string(&ffi_file).unwrap();

    // PLATFORM-005: xcb_shm_attach_checked and xcb_request_check must be declared
    assert!(
        content.contains("pub fn xcb_shm_attach_checked"),
        "ffi.rs must declare xcb_shm_attach_checked"
    );
    assert!(
        content.contains("pub fn xcb_request_check"),
        "ffi.rs must declare xcb_request_check"
    );
    assert!(
        content.contains("pub fn xcb_flush"),
        "ffi.rs must declare xcb_flush"
    );
}

// =========================================================================
// 2. RES-030: macOS Quartz Capturer Lifecycle & Resource Leak Elimination
// =========================================================================

#[test]
fn test_quartz_capturer_lifecycle_source_analysis() {
    let capturer_file =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src/quartz/capturer.rs");
    assert!(capturer_file.exists(), "quartz/capturer.rs must exist");

    let content = std::fs::read_to_string(&capturer_file).unwrap();

    // 1. Must NOT contain the old infinite sleep loop in Drop
    assert!(
        !content.contains("std::thread::sleep"),
        "quartz/capturer.rs Drop must not use infinite std::thread::sleep loop"
    );

    // 2. Must use Condvar with a timeout deadline (up to 1500ms)
    assert!(
        content.contains("Condvar"),
        "quartz/capturer.rs must use Condvar for stopped notification"
    );
    assert!(
        content.contains("Duration::from_millis(1500)"),
        "quartz/capturer.rs must specify 1500ms timeout deadline"
    );
    assert!(
        content.contains("wait_timeout"),
        "quartz/capturer.rs must use cvar.wait_timeout"
    );

    // 3. Must log warning on timeout
    assert!(
        content.contains("Timed out waiting for CGDisplayStream to stop"),
        "quartz/capturer.rs must log warning on stop timeout"
    );

    // 4. In Capturer::new, queue must be checked for null
    assert!(
        content.contains("if queue.is_null()"),
        "Capturer::new must check if queue is null"
    );

    // 5. stream must be checked for null and release queue on error
    assert!(
        content.contains("if stream.is_null()"),
        "Capturer::new must check if stream is null"
    );

    // 6. CGDisplayStreamStart error must release both stream and queue
    assert!(
        content.contains("CFRelease(stream);"),
        "Capturer::new must call CFRelease(stream) on error"
    );
    assert!(
        content.contains("dispatch_release(queue);"),
        "Capturer::new must call dispatch_release(queue) on error"
    );

    // 7. Branding: com.camellia-remote.scrap
    assert!(
        content.contains("com.camellia-remote.scrap"),
        "Queue label must reflect Camellia Remote branding"
    );

    // 8. config_dict must be checked for null in Capturer::new
    assert!(
        content.contains("if config_dict.is_null()"),
        "Capturer::new must check if config_dict is null and release queue"
    );
}

#[test]
fn test_quartz_config_build_null_safety_and_raii() {
    let config_file = Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src/quartz/config.rs");
    assert!(config_file.exists(), "quartz/config.rs must exist");

    let content = std::fs::read_to_string(&config_file).unwrap();

    // RES-030: Config::build must check if CFNumberCreate returned NULL to prevent CFRelease(NULL) crash
    assert!(
        content.contains("if throttle.is_null() || queue_length.is_null()"),
        "Config::build must guard against null CF numbers"
    );
    assert!(
        content.contains("if !throttle.is_null()"),
        "Config::build must only release non-null throttle"
    );
    assert!(
        content.contains("if !queue_length.is_null()"),
        "Config::build must only release non-null queue_length"
    );
}

#[test]
fn test_quartz_condvar_timeout_state_machine() {
    // Validate that the Condvar timeout and notification logic functions correctly
    let stopped = Arc::new((Mutex::new(false), Condvar::new()));

    // Test 1: Immediate notification stops waiting without delay
    {
        let stopped_clone = stopped.clone();
        let handle = std::thread::spawn(move || {
            let (lock, cvar) = &*stopped_clone;
            std::thread::sleep(Duration::from_millis(10));
            let mut guard = lock.lock().unwrap();
            *guard = true;
            cvar.notify_all();
        });

        let (lock, cvar) = &*stopped;
        let mut guard = lock.lock().unwrap();
        let start = Instant::now();
        let deadline = Duration::from_millis(1500);

        while !*guard {
            let elapsed = start.elapsed();
            if elapsed >= deadline {
                break;
            }
            let timeout = deadline - elapsed;
            let (new_guard, result) = cvar.wait_timeout(guard, timeout).unwrap();
            guard = new_guard;
            if result.timed_out() && !*guard {
                break;
            }
        }

        assert!(*guard, "Stopped flag must be set by worker");
        assert!(
            start.elapsed() < Duration::from_millis(500),
            "Should stop quickly upon signal"
        );
        handle.join().unwrap();
    }

    // Test 2: Timeout triggers bounded exit when notification is never sent
    {
        let unnotified = Arc::new((Mutex::new(false), Condvar::new()));
        let (lock, cvar) = &*unnotified;
        let mut guard = lock.lock().unwrap();
        let start = Instant::now();
        let deadline = Duration::from_millis(50); // Bounded short deadline for test speed

        let mut timed_out = false;
        while !*guard {
            let elapsed = start.elapsed();
            if elapsed >= deadline {
                timed_out = true;
                break;
            }
            let timeout = deadline - elapsed;
            let (new_guard, result) = cvar.wait_timeout(guard, timeout).unwrap();
            guard = new_guard;
            if result.timed_out() && !*guard {
                timed_out = true;
                break;
            }
        }

        assert!(
            timed_out,
            "Must cleanly time out when stop is never signaled"
        );
        assert!(!*guard);
    }

    // Test 3: Mutex poisoning resilience (Drop must not panic when mutex is poisoned)
    {
        let poisoned = Arc::new((Mutex::new(false), Condvar::new()));
        let poisoned_clone = poisoned.clone();
        let _ = std::thread::spawn(move || {
            let (lock, _) = &*poisoned_clone;
            let _g = lock.lock().unwrap();
            panic!("Intentional panic to poison mutex");
        })
        .join();

        let (lock, cvar) = &*poisoned;
        // Lock is poisoned, unwrap_or_else must recover gracefully
        let mut guard = lock.lock().unwrap_or_else(|e| e.into_inner());
        assert!(!*guard);
        let deadline = Duration::from_millis(20);
        let timeout = deadline;
        let (new_guard, result) = cvar
            .wait_timeout(guard, timeout)
            .unwrap_or_else(|e| e.into_inner());
        guard = new_guard;
        assert!(result.timed_out());
        assert!(!*guard);
    }
}

// =========================================================================
// 3. RES-031: Windows DXGI Duplication Frame Acquisition & Mapping State
// =========================================================================

#[test]
fn test_dxgi_reverse_unmap_and_state_tracking_source_analysis() {
    let dxgi_file = Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src/dxgi/mod.rs");
    assert!(dxgi_file.exists(), "dxgi/mod.rs must exist");

    let content = std::fs::read_to_string(&dxgi_file).unwrap();

    // 1. Must declare tracking fields in Capturer
    assert!(
        content.contains("frame_acquired: bool"),
        "Capturer must have frame_acquired: bool"
    );
    assert!(
        content.contains("surface_mapped: bool"),
        "Capturer must have surface_mapped: bool"
    );
    assert!(
        content.contains("desktop_mapped: bool"),
        "Capturer must have desktop_mapped: bool"
    );

    // 2. unmap() must reverse destruction order: UnMap BEFORE ReleaseFrame
    let unmap_fn = content
        .find("fn unmap(&mut self)")
        .expect("Must have fn unmap(&mut self)");
    let unmap_end = content[unmap_fn..]
        .find("pub fn device")
        .map(|i| unmap_fn + i)
        .unwrap_or(content.len());
    let unmap_body = &content[unmap_fn..unmap_end];

    let unmap_desktop_idx = unmap_body
        .find("UnMapDesktopSurface")
        .expect("unmap must call UnMapDesktopSurface");
    let unmap_surface_idx = unmap_body
        .find("Unmap()")
        .expect("unmap must call surface.Unmap");
    let release_frame_idx = unmap_body
        .find("ReleaseFrame()")
        .expect("unmap must call ReleaseFrame");

    assert!(
        unmap_desktop_idx < release_frame_idx,
        "UnMapDesktopSurface must be called BEFORE ReleaseFrame"
    );
    assert!(
        unmap_surface_idx < release_frame_idx,
        "surface.Unmap must be called BEFORE ReleaseFrame"
    );

    // 3. unmap() must guard with state booleans
    assert!(
        unmap_body.contains("if self.desktop_mapped"),
        "unmap must guard UnMapDesktopSurface with desktop_mapped"
    );
    assert!(
        unmap_body.contains("if self.surface_mapped"),
        "unmap must guard Unmap with surface_mapped"
    );
    assert!(
        unmap_body.contains("if self.frame_acquired"),
        "unmap must guard ReleaseFrame with frame_acquired"
    );

    // 4. load_frame unmaps on early WouldBlock / errors
    assert!(
        content.contains("self.frame_acquired = true;"),
        "load_frame and get_texture must track frame_acquired = true"
    );

    // 5. set_gdi and cancel_gdi must clean up outstanding mappings
    assert!(
        content.contains("pub fn set_gdi(&mut self) -> bool {\n        self.unmap();"),
        "set_gdi must call unmap()"
    );
    assert!(
        content.contains("pub fn cancel_gdi(&mut self) {\n        self.unmap();"),
        "cancel_gdi must call unmap()"
    );

    // 6. State query methods must exist
    assert!(
        content.contains("pub fn is_frame_acquired(&self) -> bool"),
        "Capturer must provide is_frame_acquired accessor"
    );
    assert!(
        content.contains("pub fn is_surface_mapped(&self) -> bool"),
        "Capturer must provide is_surface_mapped accessor"
    );
    assert!(
        content.contains("pub fn is_desktop_mapped(&self) -> bool"),
        "Capturer must provide is_desktop_mapped accessor"
    );

    // 7. unmap() must reset surface and texture ComPtrs to avoid dangling references
    assert!(
        unmap_body.contains("self.surface = ComPtr(ptr::null_mut());"),
        "unmap must reset surface ComPtr"
    );
    assert!(
        unmap_body.contains("self.texture = ComPtr(ptr::null_mut());"),
        "unmap must reset texture ComPtr"
    );
}

#[test]
fn test_dxgi_duplication_state_machine_simulation() {
    // In-memory state machine test verifying the exact reverse destruction order invariant
    #[derive(Default)]
    struct MockDuplicationCapturer {
        frame_acquired: bool,
        surface_mapped: bool,
        desktop_mapped: bool,
        action_log: Vec<&'static str>,
    }

    impl MockDuplicationCapturer {
        fn acquire_frame(
            &mut self,
            is_fastlane: bool,
            would_block: bool,
        ) -> Result<(), &'static str> {
            self.unmap();

            self.frame_acquired = true;
            self.action_log.push("AcquireNextFrame");

            if would_block {
                self.unmap();
                return Err("WouldBlock");
            }

            if is_fastlane {
                self.desktop_mapped = true;
                self.action_log.push("MapDesktopSurface");
            } else {
                self.surface_mapped = true;
                self.action_log.push("MapSurface");
            }

            Ok(())
        }

        fn unmap(&mut self) {
            // Reverse destruction order: UnMap surface/desktop FIRST, ReleaseFrame SECOND.
            if self.desktop_mapped {
                self.action_log.push("UnMapDesktopSurface");
                self.desktop_mapped = false;
            }
            if self.surface_mapped {
                self.action_log.push("UnmapSurface");
                self.surface_mapped = false;
            }
            if self.frame_acquired {
                self.action_log.push("ReleaseFrame");
                self.frame_acquired = false;
            }
        }
    }

    // Sequence 1: Fastlane Acquire -> Normal Unmap
    {
        let mut capturer = MockDuplicationCapturer::default();
        capturer.acquire_frame(true, false).unwrap();
        assert!(capturer.frame_acquired);
        assert!(capturer.desktop_mapped);

        capturer.unmap();
        assert_eq!(
            capturer.action_log,
            vec![
                "AcquireNextFrame",
                "MapDesktopSurface",
                "UnMapDesktopSurface",
                "ReleaseFrame"
            ]
        );
        assert!(!capturer.frame_acquired);
        assert!(!capturer.desktop_mapped);

        // Calling unmap again is a no-op
        capturer.unmap();
        assert_eq!(capturer.action_log.len(), 4);
    }

    // Sequence 2: Staging Surface Acquire -> Normal Unmap
    {
        let mut capturer = MockDuplicationCapturer::default();
        capturer.acquire_frame(false, false).unwrap();
        assert!(capturer.frame_acquired);
        assert!(capturer.surface_mapped);

        capturer.unmap();
        assert_eq!(
            capturer.action_log,
            vec![
                "AcquireNextFrame",
                "MapSurface",
                "UnmapSurface",
                "ReleaseFrame"
            ]
        );
        assert!(!capturer.frame_acquired);
        assert!(!capturer.surface_mapped);
    }

    // Sequence 3: Acquire followed by WouldBlock cleans up acquired frame immediately
    {
        let mut capturer = MockDuplicationCapturer::default();
        let res = capturer.acquire_frame(true, true);
        assert!(res.is_err());
        assert!(!capturer.frame_acquired);
        assert!(!capturer.desktop_mapped);
        assert_eq!(
            capturer.action_log,
            vec!["AcquireNextFrame", "ReleaseFrame"]
        );
    }
}
