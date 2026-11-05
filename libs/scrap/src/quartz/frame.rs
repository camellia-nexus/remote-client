use std::{ops, ptr, slice};

use super::ffi::*;

pub struct Frame {
    surface: IOSurfaceRef,
    locked: bool,
    alloc_size: usize,
    bgra: Vec<u8>,
    bgra_stride: usize,
}

impl Frame {
    pub unsafe fn try_new(surface: IOSurfaceRef) -> Option<Frame> {
        if surface.is_null() {
            return None;
        }

        CFRetain(surface);
        IOSurfaceIncrementUseCount(surface);

        let lock_res = IOSurfaceLock(surface, SURFACE_LOCK_READ_ONLY, ptr::null_mut());
        if lock_res != 0 {
            IOSurfaceDecrementUseCount(surface);
            CFRelease(surface);
            return None;
        }

        let base = IOSurfaceGetBaseAddress(surface);
        let alloc_size = IOSurfaceGetAllocSize(surface);

        if base.is_null() || alloc_size == 0 {
            IOSurfaceUnlock(surface, SURFACE_LOCK_READ_ONLY, ptr::null_mut());
            IOSurfaceDecrementUseCount(surface);
            CFRelease(surface);
            return None;
        }

        Some(Frame {
            surface,
            locked: true,
            alloc_size,
            bgra: Vec::new(),
            bgra_stride: 0,
        })
    }

    pub unsafe fn new(surface: IOSurfaceRef) -> Frame {
        Self::try_new(surface).unwrap_or_else(|| Frame {
            surface: ptr::null_mut(),
            locked: false,
            alloc_size: 0,
            bgra: Vec::new(),
            bgra_stride: 0,
        })
    }

    #[inline]
    pub fn inner(&self) -> &[u8] {
        if !self.locked || self.surface.is_null() || self.alloc_size == 0 {
            return &[];
        }
        unsafe {
            let base = IOSurfaceGetBaseAddress(self.surface);
            if base.is_null() {
                &[]
            } else {
                slice::from_raw_parts(base as *const u8, self.alloc_size)
            }
        }
    }

    pub fn stride(&self) -> usize {
        self.bgra_stride
    }

    pub fn surface_to_bgra(&mut self, h: usize) {
        if !self.locked || self.surface.is_null() || h == 0 {
            self.bgra.clear();
            self.bgra_stride = 0;
            return;
        }
        unsafe {
            let plane0 = IOSurfaceGetBaseAddressOfPlane(self.surface, 0);
            if plane0.is_null() {
                self.bgra.clear();
                self.bgra_stride = 0;
                return;
            }
            let stride = IOSurfaceGetBytesPerRowOfPlane(self.surface, 0);
            self.bgra_stride = stride;
            let required_bytes = match stride.checked_mul(h) {
                Some(b) => b,
                None => {
                    self.bgra.clear();
                    self.bgra_stride = 0;
                    return;
                }
            };

            if required_bytes > self.alloc_size {
                self.bgra.clear();
                self.bgra_stride = 0;
                return;
            }

            self.bgra.resize(required_bytes, 0);
            std::ptr::copy_nonoverlapping(
                plane0 as *const u8,
                self.bgra.as_mut_ptr(),
                required_bytes,
            );
        }
    }
}

impl ops::Deref for Frame {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        &self.bgra
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        if !self.surface.is_null() {
            unsafe {
                if self.locked {
                    IOSurfaceUnlock(self.surface, SURFACE_LOCK_READ_ONLY, ptr::null_mut());
                }
                IOSurfaceDecrementUseCount(self.surface);
                CFRelease(self.surface);
            }
        }
    }
}
