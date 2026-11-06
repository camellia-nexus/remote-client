use super::ffi::*;
use super::Display;
use camellia_remote_protocol::libc;
use std::{io, ptr, slice};

pub struct Capturer {
    display: Display,
    shmid: i32,
    xcbid: u32,
    buffer: *const u8,

    size: usize,
    saved_raw_data: Vec<u8>, // for faster compare and copy
}

struct ShmSegmentGuard {
    shmid: i32,
    buffer: *mut u8,
    active: bool,
}

impl Drop for ShmSegmentGuard {
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

impl Capturer {
    pub fn new(display: Display) -> io::Result<Capturer> {
        // Calculate dimensions.

        let pixel_width = display.pixfmt().bytes_per_pixel();
        let rect = display.rect();
        let size = (rect.w as usize) * (rect.h as usize) * pixel_width;

        // Create a shared memory segment with minimal secure permissions (0o600).
        let shmid = unsafe { libc::shmget(libc::IPC_PRIVATE, size, libc::IPC_CREAT | 0o600) };

        if shmid == -1 {
            return Err(io::Error::last_os_error());
        }

        let mut guard = ShmSegmentGuard {
            shmid,
            buffer: ptr::null_mut(),
            active: true,
        };

        // Attach the segment to a readable address.
        let buffer = unsafe { libc::shmat(shmid, ptr::null(), libc::SHM_RDONLY) } as *mut u8;

        if buffer.is_null() || buffer as isize == -1 {
            return Err(io::Error::last_os_error());
        }
        guard.buffer = buffer;

        // Attach the segment to XCB with checked request.
        let server = display.server().raw();
        let xcbid = unsafe { xcb_generate_id(server) };
        let cookie = unsafe {
            xcb_shm_attach_checked(
                server,
                xcbid,
                shmid as u32,
                0, // False, i.e. not read-only.
            )
        };

        let err = unsafe { xcb_request_check(server, cookie) };
        if !err.is_null() {
            let error_code = unsafe { (*err).error_code };
            unsafe {
                libc::free(err as *mut _);
            }
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("xcb_shm_attach failed with X11 error code {}", error_code),
            ));
        }

        // Segment successfully attached by X server and client; mark for deletion immediately
        // so it cannot be discovered or attached by new local processes once current attach is released.
        unsafe {
            libc::shmctl(shmid, libc::IPC_RMID, ptr::null_mut());
        }

        guard.active = false;

        let c = Capturer {
            display,
            shmid,
            xcbid,
            buffer,
            size,
            saved_raw_data: Vec::new(),
        };
        Ok(c)
    }

    pub fn display(&self) -> &Display {
        &self.display
    }

    fn get_image(&self) -> io::Result<()> {
        let server = self.display.server().raw();
        if unsafe { xcb_connection_has_error(server) } != 0 {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "XCB connection has error",
            ));
        }
        let rect = self.display.rect();
        unsafe {
            let request = xcb_shm_get_image_unchecked(
                server,
                self.display.root(),
                rect.x,
                rect.y,
                rect.w,
                rect.h,
                !0,
                XCB_IMAGE_FORMAT_Z_PIXMAP,
                self.xcbid,
                0,
            );
            let mut err: *mut xcb_generic_error_t = ptr::null_mut();
            let response = xcb_shm_get_image_reply(server, request, &mut err);
            if !err.is_null() {
                let error_code = (*err).error_code;
                libc::free(err as *mut _);
                if !response.is_null() {
                    libc::free(response as *mut _);
                }
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    format!(
                        "xcb_shm_get_image failed with X11 error code {}",
                        error_code
                    ),
                ));
            }
            if response.is_null() {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "xcb_shm_get_image returned null reply",
                ));
            }
            libc::free(response as *mut _);
            Ok(())
        }
    }

    pub fn frame<'b>(&'b mut self) -> std::io::Result<&'b [u8]> {
        self.get_image()?;
        let result = unsafe { slice::from_raw_parts(self.buffer, self.size) };
        crate::would_block_if_equal(&mut self.saved_raw_data, result)?;
        Ok(result)
    }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        unsafe {
            let server = self.display.server().raw();
            // Detach segment from XCB and flush to ensure X server drops attachment immediately.
            xcb_shm_detach(server, self.xcbid);
            xcb_flush(server);
            // Detach segment from our space.
            libc::shmdt(self.buffer as *mut _);
            // Destroy the shared memory segment.
            libc::shmctl(self.shmid, libc::IPC_RMID, ptr::null_mut());
        }
    }
}
