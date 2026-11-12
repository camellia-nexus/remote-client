#![allow(clippy::upper_case_acronyms)]

#[cfg(quartz)]
extern crate block;
#[macro_use]
extern crate cfg_if;
pub use camellia_remote_protocol::libc;
#[cfg(dxgi)]
extern crate winapi;

pub use common::*;

#[cfg(quartz)]
pub mod quartz;

#[cfg(x11)]
pub mod x11;

#[cfg(all(x11, feature = "wayland"))]
pub mod wayland;

#[cfg(dxgi)]
pub mod dxgi;

#[cfg(target_os = "android")]
pub mod android;

mod common;
pub use common::frame_raw;
