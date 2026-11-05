use std::ffi::CString;
use std::ptr;
use std::rc::Rc;

use crate::Pixfmt;
use camellia_remote_protocol::libc;

use super::ffi::*;
use super::{Display, Rect, Server};

//TODO: Do I have to free the displays?

struct RawMonitorInfo {
    primary: bool,
    rect: Rect,
    name: xcb_atom_t,
}

pub struct DisplayIter {
    outer: xcb_screen_iterator_t,
    inner: Option<(std::vec::IntoIter<RawMonitorInfo>, xcb_window_t)>,
    server: Rc<Server>,
}

impl DisplayIter {
    pub unsafe fn new(server: Rc<Server>) -> DisplayIter {
        let mut outer = xcb_setup_roots_iterator(server.setup());
        let inner = Self::next_screen(&mut outer, &server);
        DisplayIter {
            outer,
            inner,
            server,
        }
    }

    fn next_screen(
        outer: &mut xcb_screen_iterator_t,
        server: &Server,
    ) -> Option<(std::vec::IntoIter<RawMonitorInfo>, xcb_window_t)> {
        if outer.rem == 0 {
            return None;
        }

        unsafe {
            if outer.data.is_null() {
                xcb_screen_next(outer);
                return None;
            }
            let root = (*outer.data).root;

            let cookie = xcb_randr_get_monitors_unchecked(
                server.raw(),
                root,
                1, //TODO: I don't know if this should be true or false.
            );

            let response = xcb_randr_get_monitors_reply(server.raw(), cookie, ptr::null_mut());
            if response.is_null() {
                xcb_screen_next(outer);
                return None;
            }

            let mut monitors = Vec::new();
            let mut iter = xcb_randr_get_monitors_monitors_iterator(response);
            while iter.rem > 0 {
                if !iter.data.is_null() {
                    let data = &*iter.data;
                    monitors.push(RawMonitorInfo {
                        primary: data.primary != 0,
                        rect: Rect {
                            x: data.x,
                            y: data.y,
                            w: data.width,
                            h: data.height,
                        },
                        name: data.name,
                    });
                }
                xcb_randr_monitor_info_next(&mut iter);
            }

            libc::free(response as *mut _);
            xcb_screen_next(outer);

            Some((monitors.into_iter(), root))
        }
    }
}

impl Iterator for DisplayIter {
    type Item = Display;

    fn next(&mut self) -> Option<Display> {
        loop {
            if let Some((ref mut inner, root)) = self.inner {
                // If there is something in the current screen, return that.
                if let Some(monitor) = inner.next() {
                    unsafe {
                        let name = get_atom_name(self.server.raw(), monitor.name);
                        let pixfmt = get_pixfmt(self.server.raw(), root).unwrap_or(Pixfmt::BGRA);
                        let display = Display::new(
                            self.server.clone(),
                            monitor.primary,
                            monitor.rect,
                            root,
                            name,
                            pixfmt,
                        );

                        return Some(display);
                    }
                }
            } else {
                // If there is no current screen, the screen iterator is empty.
                return None;
            }

            // The current screen was empty, so try the next screen.
            self.inner = Self::next_screen(&mut self.outer, &self.server);
        }
    }
}

fn get_atom_name(conn: *mut xcb_connection_t, atom: xcb_atom_t) -> String {
    let empty = "".to_owned();
    if atom == 0 {
        return empty;
    }
    unsafe {
        let mut e: *mut xcb_generic_error_t = std::ptr::null_mut();
        let reply = xcb_get_atom_name_reply(conn, xcb_get_atom_name(conn, atom), &mut e as _);
        if reply.is_null() {
            return empty;
        }
        let length = xcb_get_atom_name_name_length(reply);
        let name = xcb_get_atom_name_name(reply);
        let mut v = vec![0u8; length as _];
        std::ptr::copy_nonoverlapping(name as _, v.as_mut_ptr(), length as _);
        libc::free(reply as *mut _);
        if let Ok(s) = CString::new(v) {
            return s.to_string_lossy().to_string();
        }
        empty
    }
}

unsafe fn get_pixfmt(conn: *mut xcb_connection_t, root: xcb_window_t) -> Option<Pixfmt> {
    let geo_cookie = xcb_get_geometry_unchecked(conn, root);
    let geo = xcb_get_geometry_reply(conn, geo_cookie, ptr::null_mut());
    if geo.is_null() {
        return None;
    }
    let depth = (*geo).depth;
    libc::free(geo as _);
    // now only support little endian
    // https://github.com/FFmpeg/FFmpeg/blob/a9c05eb657d0d05f3ac79fe9973581a41b265a5e/libavdevice/xcbgrab.c#L519
    match depth {
        16 => Some(Pixfmt::RGB565LE),
        32 => Some(Pixfmt::BGRA),
        _ => None,
    }
}
