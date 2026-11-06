use std::ptr;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use block::{Block, ConcreteBlock};
use camellia_remote_protocol::libc::c_void;
use camellia_remote_protocol::log;

use super::config::Config;
use super::display::Display;
use super::ffi::*;
use super::frame::Frame;

pub struct Capturer {
    stream: CGDisplayStreamRef,
    queue: DispatchQueue,

    width: usize,
    height: usize,
    format: PixelFormat,
    display: Display,
    stopped: Arc<(Mutex<bool>, Condvar)>,
}

impl Capturer {
    pub fn new<F: Fn(Frame) + 'static>(
        display: Display,
        width: usize,
        height: usize,
        format: PixelFormat,
        config: Config,
        handler: F,
    ) -> Result<Capturer, CGError> {
        let stopped = Arc::new((Mutex::new(false), Condvar::new()));
        let cloned_stopped = stopped.clone();
        let handler: FrameAvailableHandler = ConcreteBlock::new(move |status, _, surface, _| {
            use self::CGDisplayStreamFrameStatus::*;
            if status == Stopped {
                let (lock, cvar) = &*cloned_stopped;
                let mut guard = lock.lock().unwrap_or_else(|e| e.into_inner());
                *guard = true;
                cvar.notify_all();
                return;
            }
            if status == FrameComplete {
                if let Some(frame) = unsafe { Frame::try_new(surface) } {
                    handler(frame);
                }
            }
        })
        .copy();

        let queue = unsafe {
            dispatch_queue_create(
                b"com.camellia-remote.scrap\0".as_ptr() as *const i8,
                ptr::null_mut(),
            )
        };
        if queue.is_null() {
            log::error!("Failed to create dispatch queue for Quartz display stream");
            return Err(CGError::CannotComplete);
        }

        let config_dict = config.build();
        if config_dict.is_null() {
            log::error!("Failed to create CFDictionary for Quartz display stream config");
            unsafe {
                dispatch_release(queue);
            }
            return Err(CGError::CannotComplete);
        }

        let stream = unsafe {
            let stream = CGDisplayStreamCreateWithDispatchQueue(
                display.id(),
                width,
                height,
                format,
                config_dict,
                queue,
                &*handler as *const Block<_, _> as *const c_void,
            );
            CFRelease(config_dict);
            stream
        };

        if stream.is_null() {
            log::error!("Failed to create CGDisplayStream");
            unsafe {
                dispatch_release(queue);
            }
            return Err(CGError::CannotComplete);
        }

        match unsafe { CGDisplayStreamStart(stream) } {
            CGError::Success => Ok(Capturer {
                stream,
                queue,
                width,
                height,
                format,
                display,
                stopped,
            }),
            err => {
                log::error!("CGDisplayStreamStart failed with error: {:?}", err);
                unsafe {
                    CFRelease(stream);
                    dispatch_release(queue);
                }
                Err(err)
            }
        }
    }

    pub fn width(&self) -> usize {
        self.width
    }
    pub fn height(&self) -> usize {
        self.height
    }
    pub fn format(&self) -> PixelFormat {
        self.format
    }
    pub fn display(&self) -> Display {
        self.display
    }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        unsafe {
            let res = CGDisplayStreamStop(self.stream);
            if res != CGError::Success {
                log::warn!("CGDisplayStreamStop returned error: {:?}", res);
            }
            let (lock, cvar) = &*self.stopped;
            let mut stopped = lock.lock().unwrap_or_else(|e| e.into_inner());
            let deadline = Duration::from_millis(1500);
            let start = Instant::now();
            while !*stopped {
                let elapsed = start.elapsed();
                if elapsed >= deadline {
                    log::warn!(
                        "Timed out waiting for CGDisplayStream to stop after {}ms; proceeding with cleanup",
                        deadline.as_millis()
                    );
                    break;
                }
                let timeout = deadline - elapsed;
                let (new_stopped, result) = cvar
                    .wait_timeout(stopped, timeout)
                    .unwrap_or_else(|e| e.into_inner());
                stopped = new_stopped;
                if result.timed_out() && !*stopped {
                    log::warn!(
                        "Timed out waiting for CGDisplayStream to stop; proceeding with cleanup"
                    );
                    break;
                }
            }
            if !self.stream.is_null() {
                CFRelease(self.stream);
            }
            if !self.queue.is_null() {
                dispatch_release(self.queue);
            }
        }
    }
}
