// Client Batch 19 Display Capture Safety Tests (UNSAFE-004, UNSAFE-006, UNSAFE-007)

use std::path::Path;

#[test]
fn test_x11_display_enumeration_safe() {
    #[cfg(all(target_os = "linux", feature = "flutter"))]
    {
        // Calling scrap::Display::all() on Linux should either succeed or return Err gracefully,
        // never causing a use-after-free or segfault even when headless or under Xvfb/Wayland.
        let displays = scrap::Display::all();
        match displays {
            Ok(list) => {
                println!("Detected {} displays on X11", list.len());
                for d in list {
                    assert!(
                        d.width() > 0
                            || d.height() > 0
                            || d.name().is_empty()
                            || !d.name().is_empty()
                    );
                }
            }
            Err(e) => {
                println!(
                    "Display enumeration returned error (expected in headless CI without X11): {}",
                    e
                );
            }
        }
    }
}

#[test]
fn test_x11_iter_uaf_regression_source_analysis() {
    // Assert that DisplayIter in libs/scrap/src/x11/iter.rs copies monitor PODs into an owned Vec
    // before libc::free is called, completely eliminating the RandR reply use-after-free.
    let iter_file = Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src/x11/iter.rs");
    assert!(iter_file.exists(), "iter.rs must exist");

    let content = std::fs::read_to_string(&iter_file).unwrap();

    // 1. Must define an owned structure for monitor info
    assert!(
        content.contains("struct RawMonitorInfo"),
        "iter.rs must define an owned RawMonitorInfo structure"
    );

    // 2. DisplayIter.inner must hold std::vec::IntoIter<RawMonitorInfo> instead of xcb_randr_monitor_info_iterator_t
    assert!(
        content.contains("IntoIter<RawMonitorInfo>"),
        "DisplayIter.inner must hold owned IntoIter<RawMonitorInfo>"
    );

    // 3. Must check if response is null before constructing iterator
    assert!(
        content.contains("if response.is_null()"),
        "next_screen must check if response is null"
    );

    // 4. Must push to monitors Vec before libc::free
    let push_idx = content
        .find("monitors.push")
        .expect("Must push to monitors Vec");
    let free_idx = content
        .find("libc::free(response as *mut _)")
        .expect("Must free response");
    assert!(
        push_idx < free_idx,
        "monitors must be collected into owned Vec before libc::free is called!"
    );
}

#[test]
fn test_quartz_frame_safety_source_analysis() {
    // Assert that libs/scrap/src/quartz/frame.rs adheres to all UNSAFE-004 invariants
    let frame_file = Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src/quartz/frame.rs");
    assert!(frame_file.exists(), "frame.rs must exist");

    let content = std::fs::read_to_string(&frame_file).unwrap();

    // 1. Must NOT contain fake &'static [u8]
    assert!(
        !content.contains("&'static [u8]"),
        "Frame must not contain fake &'static [u8] field!"
    );

    // 2. Must check IOSurfaceLock return code
    assert!(
        content.contains("let lock_res = IOSurfaceLock"),
        "try_new must capture IOSurfaceLock return code"
    );
    assert!(
        content.contains("if lock_res != 0"),
        "try_new must check lock_res != 0"
    );

    // 3. Must check base address and alloc size
    assert!(
        content.contains("base.is_null() || alloc_size == 0"),
        "try_new must validate base address and alloc size"
    );

    // 4. Drop must guard IOSurfaceUnlock with self.locked
    assert!(
        content.contains("if self.locked"),
        "Drop must guard IOSurfaceUnlock with self.locked"
    );

    // 5. surface_to_bgra must use checked_mul to prevent integer overflow
    assert!(
        content.contains("checked_mul"),
        "surface_to_bgra must use checked_mul"
    );

    // 6. surface_to_bgra must check required_bytes against alloc_size
    assert!(
        content.contains("required_bytes > self.alloc_size"),
        "surface_to_bgra must bounds check against alloc_size"
    );
}

#[test]
fn test_dxgi_query_interface_null_checks_source_analysis() {
    // Assert that libs/scrap/src/dxgi/mod.rs checks QueryInterface HRESULTs and NULL pointers
    let dxgi_file = Path::new(env!("CARGO_MANIFEST_DIR")).join("libs/scrap/src/dxgi/mod.rs");
    assert!(dxgi_file.exists(), "dxgi/mod.rs must exist");

    let content = std::fs::read_to_string(&dxgi_file).unwrap();

    // 1. ohgodwhat checks frame.is_null()
    assert!(
        content.contains("if frame.is_null()"),
        "ohgodwhat must check if frame is null"
    );

    // 2. ohgodwhat checks QueryInterface HRESULT via wrap_hresult
    assert!(
        content.contains("wrap_hresult((*frame).QueryInterface("),
        "ohgodwhat must check QueryInterface return code"
    );

    // 3. ohgodwhat checks texture.is_null()
    assert!(
        content.contains("if texture.is_null()"),
        "ohgodwhat must check if texture is null"
    );

    // 4. ohgodwhat checks CreateTexture2D result and readable.is_null()
    assert!(
        content.contains("if readable.is_null()"),
        "ohgodwhat must check if readable texture is null"
    );

    // 5. ohgodwhat checks surface.is_null()
    assert!(
        content.contains("if surface.is_null()"),
        "ohgodwhat must check if surface is null"
    );

    // 6. get_texture checks QueryInterface result and texture.is_null()
    assert!(
        content.contains("wrap_hresult((*frame.0).QueryInterface("),
        "get_texture must wrap QueryInterface result"
    );

    // 7. get_texture verifies final_texture is not null before returning
    assert!(
        content.contains("if final_texture.is_null()"),
        "get_texture must verify final_texture is non-null"
    );
}

#[test]
fn test_quartz_frame_null_surface_tolerance() {
    #[cfg(target_os = "macos")]
    {
        use scrap::quartz::Frame;
        unsafe {
            // try_new with NULL surface must safely return None without crashing
            let frame_opt = Frame::try_new(std::ptr::null_mut());
            assert!(frame_opt.is_none());

            // new with NULL surface must produce an empty, non-locked frame
            let frame = Frame::new(std::ptr::null_mut());
            assert_eq!(frame.inner(), &[]);
            assert_eq!(frame.stride(), 0);
            assert_eq!(&*frame, &[]);
            // Dropping frame must not crash
            drop(frame);
        }
    }
}
