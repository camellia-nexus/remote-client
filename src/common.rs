use std::{
    collections::HashMap,
    future::Future,
    net::{SocketAddr, ToSocketAddrs},
    sync::{Arc, Mutex, RwLock},
    task::Poll,
};

use serde_json::{json, Map, Value};

#[cfg(not(target_os = "ios"))]
use camellia_remote_protocol::whoami;
use camellia_remote_protocol::{
    anyhow::{anyhow, Context},
    bail,
    base64::{engine::general_purpose::STANDARD as BASE64, Engine as _},
    bytes::Bytes,
    config::{
        self, keys, use_ws, Config, LocalConfig, Socks5Server, CONNECT_TIMEOUT, READ_TIMEOUT,
        RENDEZVOUS_PORT,
    },
    crypto::{box_, secretbox, sign},
    futures::future::join_all,
    futures_util::future::poll_fn,
    log,
    message_proto::*,
    protobuf::{Enum, Message as _},
    rendezvous_proto::*,
    socket_client,
    tcp::{CipherRole, Encrypt},
    timeout,
    tokio::{
        self,
        net::UdpSocket,
        time::{Duration, Instant, Interval},
    },
    ResultType, Stream,
};

use crate::{
    hbbs_http::create_http_client_async_for_configuration,
    ui_interface::{get_api_server as ui_get_api_server, get_option, set_option},
};

#[derive(Debug, Eq, PartialEq)]
pub enum GrabState {
    Ready,
    Run,
    Wait,
    Exit,
}

pub type NotifyMessageBox = fn(String, String, String, String) -> dyn Future<Output = ()>;

// the executable name of the portable version
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub const PORTABLE_APPNAME_RUNTIME_ENV_KEY: &str =
    camellia_windows_bootstrap::PORTABLE_APP_NAME_ENV_KEY;
#[cfg(any(target_os = "android", target_os = "ios"))]
pub const PORTABLE_APPNAME_RUNTIME_ENV_KEY: &str = "CAMELLIA_REMOTE_APPNAME";

pub const PLATFORM_WINDOWS: &str = "Windows";
pub const PLATFORM_LINUX: &str = "Linux";
pub const PLATFORM_MACOS: &str = "Mac OS";
pub const PLATFORM_ANDROID: &str = "Android";

pub const TIMER_OUT: Duration = Duration::from_secs(1);
pub const DEFAULT_KEEP_ALIVE: i32 = 60_000;

const MIN_VER_MULTI_UI_SESSION: &str = "1.2.4";
const TRACEPARENT_HEADER: &str = "traceparent";
const CAMELLIA_EVENT_ID_HEADER: &str = "X-Camellia-Event-ID";

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct HttpOperation {
    trace_id: String,
    event_id: String,
}

impl HttpOperation {
    pub(crate) fn new() -> Self {
        let event_id = uuid::Uuid::new_v4();
        Self {
            trace_id: event_id.simple().to_string(),
            event_id: event_id.to_string(),
        }
    }

    pub(crate) fn from_event_id(event_id: &str) -> ResultType<Self> {
        let parsed = uuid::Uuid::parse_str(event_id)?;
        if parsed.get_version_num() != 4
            || parsed.get_variant() != uuid::Variant::RFC4122
            || parsed.to_string() != event_id
        {
            bail!("HTTP operation event ID must be a canonical UUIDv4");
        }
        Ok(Self {
            trace_id: parsed.simple().to_string(),
            event_id: event_id.to_owned(),
        })
    }

    pub(crate) fn correlation_headers(&self) -> [(String, String); 2] {
        let span_id = format!("{:016x}", uuid::Uuid::new_v4().as_u128() as u64);
        [
            (
                TRACEPARENT_HEADER.to_owned(),
                format!("00-{}-{span_id}-01", self.trace_id),
            ),
            (CAMELLIA_EVENT_ID_HEADER.to_owned(), self.event_id.clone()),
        ]
    }
}

pub mod input {
    pub const MOUSE_TYPE_MOVE: i32 = 0;
    pub const MOUSE_TYPE_DOWN: i32 = 1;
    pub const MOUSE_TYPE_UP: i32 = 2;
    pub const MOUSE_TYPE_WHEEL: i32 = 3;
    pub const MOUSE_TYPE_TRACKPAD: i32 = 4;
    /// Relative mouse movement type for gaming/3D applications.
    /// This type sends delta (dx, dy) values instead of absolute coordinates.
    /// NOTE: This requires Flutter-side pointer lock and cursor-control plumbing.
    pub const MOUSE_TYPE_MOVE_RELATIVE: i32 = 5;

    /// Mask to extract the mouse event type from the mask field.
    /// The lower 3 bits contain the event type (MOUSE_TYPE_*), giving a valid range of 0-7.
    /// Currently defined types use values 0-5; values 6 and 7 are reserved for future use.
    pub const MOUSE_TYPE_MASK: i32 = 0x7;

    pub const MOUSE_BUTTON_LEFT: i32 = 0x01;
    pub const MOUSE_BUTTON_RIGHT: i32 = 0x02;
    pub const MOUSE_BUTTON_WHEEL: i32 = 0x04;
    pub const MOUSE_BUTTON_BACK: i32 = 0x08;
    pub const MOUSE_BUTTON_FORWARD: i32 = 0x10;
}

lazy_static::lazy_static! {
    pub static ref DEVICE_ID: Arc<Mutex<String>> = Default::default();
    pub static ref DEVICE_NAME: Arc<Mutex<String>> = Default::default();
    static ref PUBLIC_IPV6_ADDR: Arc<Mutex<(Option<SocketAddr>, Option<Instant>)>> = Default::default();
}

lazy_static::lazy_static! {
    // Is server process, with "--server" args
    static ref IS_SERVER: bool = std::env::args().nth(1) == Some("--server".to_owned());
    // Is server logic running. The server code can invoked to run by the main process if --server is not running.
    static ref SERVER_RUNNING: Arc<RwLock<bool>> = Default::default();
    static ref IS_MAIN: bool = std::env::args().nth(1).map_or(true, |arg| !arg.starts_with("--"));
    static ref IS_CM: bool = std::env::args().nth(1) == Some("--cm".to_owned()) || std::env::args().nth(1) == Some("--cm-no-ui".to_owned());
}

pub struct SimpleCallOnReturn {
    pub b: bool,
    pub f: Box<dyn Fn() + Send + 'static>,
}

impl Drop for SimpleCallOnReturn {
    fn drop(&mut self) {
        if self.b {
            (self.f)();
        }
    }
}

pub fn global_init() -> bool {
    #[cfg(target_os = "linux")]
    {
        if !crate::platform::linux::is_x11() {
            crate::server::wayland::init();
        }
    }
    true
}

pub fn global_clean() {}

#[inline]
pub fn set_server_running(b: bool) {
    *SERVER_RUNNING.write().unwrap() = b;
}

#[inline]
pub fn is_support_multi_ui_session(ver: &str) -> bool {
    is_support_multi_ui_session_num(camellia_remote_protocol::get_version_number(ver))
}

#[inline]
pub fn is_support_multi_ui_session_num(ver: i64) -> bool {
    ver >= camellia_remote_protocol::get_version_number(MIN_VER_MULTI_UI_SESSION)
}

#[inline]
#[cfg(feature = "unix-file-copy-paste")]
pub fn is_support_file_copy_paste(ver: &str) -> bool {
    is_support_file_copy_paste_num(camellia_remote_protocol::get_version_number(ver))
}

#[inline]
#[cfg(feature = "unix-file-copy-paste")]
pub fn is_support_file_copy_paste_num(ver: i64) -> bool {
    ver >= camellia_remote_protocol::get_version_number("1.3.8")
}

pub fn is_support_remote_print(ver: &str) -> bool {
    camellia_remote_protocol::get_version_number(ver)
        >= camellia_remote_protocol::get_version_number("1.3.9")
}

pub fn is_support_file_paste_if_macos(ver: &str) -> bool {
    camellia_remote_protocol::get_version_number(ver)
        >= camellia_remote_protocol::get_version_number("1.3.9")
}

#[inline]
pub fn is_support_screenshot(ver: &str) -> bool {
    is_support_multi_ui_session_num(camellia_remote_protocol::get_version_number(ver))
}

#[inline]
pub fn is_support_screenshot_num(ver: i64) -> bool {
    ver >= camellia_remote_protocol::get_version_number("1.4.0")
}

#[inline]
pub fn is_support_file_transfer_resume(ver: &str) -> bool {
    is_support_file_transfer_resume_num(camellia_remote_protocol::get_version_number(ver))
}

#[inline]
pub fn is_support_file_transfer_resume_num(ver: i64) -> bool {
    ver >= camellia_remote_protocol::get_version_number("1.4.2")
}

/// Minimum server version required for relative mouse mode support.
/// This constant must mirror Flutter's `kMinVersionForRelativeMouseMode` in `consts.dart`.
const MIN_VERSION_RELATIVE_MOUSE_MODE: &str = "1.4.5";

#[inline]
pub fn is_support_relative_mouse_mode(ver: &str) -> bool {
    is_support_relative_mouse_mode_num(camellia_remote_protocol::get_version_number(ver))
}

#[inline]
pub fn is_support_relative_mouse_mode_num(ver: i64) -> bool {
    ver >= camellia_remote_protocol::get_version_number(MIN_VERSION_RELATIVE_MOUSE_MODE)
}

// is server process, with "--server" args
#[inline]
pub fn is_server() -> bool {
    *IS_SERVER
}

#[inline]
pub fn need_fs_cm_send_files() -> bool {
    #[cfg(windows)]
    {
        is_server()
    }
    #[cfg(not(windows))]
    {
        false
    }
}

#[inline]
pub fn is_main() -> bool {
    *IS_MAIN
}

#[inline]
pub fn is_cm() -> bool {
    *IS_CM
}

// Is server logic running.
#[inline]
pub fn is_server_running() -> bool {
    *SERVER_RUNNING.read().unwrap()
}

#[inline]
pub fn valid_for_numlock(evt: &KeyEvent) -> bool {
    if let Some(key_event::Union::ControlKey(ck)) = evt.union {
        let v = ck.value();
        (v >= ControlKey::Numpad0.value() && v <= ControlKey::Numpad9.value())
            || v == ControlKey::Decimal.value()
    } else {
        false
    }
}

/// Set sound input device.
pub fn set_sound_input(device: String) {
    let prior_device = get_option("audio-input".to_owned());
    if prior_device != device {
        log::info!("switch to audio input device {}", device);
        std::thread::spawn(move || {
            set_option("audio-input".to_owned(), device);
        });
    } else {
        log::info!("audio input is already set to {}", device);
    }
}

/// Get system's default sound input device name.
#[inline]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn get_default_sound_input() -> Option<String> {
    #[cfg(not(target_os = "linux"))]
    {
        use cpal::traits::{DeviceTrait, HostTrait};
        let host = cpal::default_host();
        let dev = host.default_input_device();
        return if let Some(dev) = dev {
            match dev.name() {
                Ok(name) => Some(name),
                Err(_) => None,
            }
        } else {
            None
        };
    }
    #[cfg(target_os = "linux")]
    {
        let input = crate::platform::linux::get_default_pa_source();
        return if let Some(input) = input {
            Some(input.1)
        } else {
            None
        };
    }
}

#[inline]
#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn get_default_sound_input() -> Option<String> {
    None
}

#[cfg(feature = "use_dasp")]
pub fn audio_resample(
    data: &[f32],
    sample_rate0: u32,
    sample_rate: u32,
    channels: u16,
) -> Vec<f32> {
    use dasp::{interpolate::linear::Linear, signal, Signal};
    let n = data.len() / (channels as usize);
    let n = n * sample_rate as usize / sample_rate0 as usize;
    if channels == 2 {
        let mut source = signal::from_interleaved_samples_iter::<_, [_; 2]>(data.iter().cloned());
        let a = source.next();
        let b = source.next();
        let interp = Linear::new(a, b);
        let mut data = Vec::with_capacity(n << 1);
        for x in source
            .from_hz_to_hz(interp, sample_rate0 as _, sample_rate as _)
            .take(n)
        {
            data.push(x[0]);
            data.push(x[1]);
        }
        data
    } else {
        let mut source = signal::from_iter(data.iter().cloned());
        let a = source.next();
        let b = source.next();
        let interp = Linear::new(a, b);
        source
            .from_hz_to_hz(interp, sample_rate0 as _, sample_rate as _)
            .take(n)
            .collect()
    }
}

pub fn audio_rechannel(
    input: Vec<f32>,
    in_hz: u32,
    out_hz: u32,
    in_chan: u16,
    output_chan: u16,
) -> Vec<f32> {
    if in_chan == output_chan {
        return input;
    }
    let mut input = input;
    input.truncate(input.len() / in_chan as usize * in_chan as usize);
    match (in_chan, output_chan) {
        (1, 2) => audio_rechannel_1_2(&input, in_hz, out_hz),
        (1, 3) => audio_rechannel_1_3(&input, in_hz, out_hz),
        (1, 4) => audio_rechannel_1_4(&input, in_hz, out_hz),
        (1, 5) => audio_rechannel_1_5(&input, in_hz, out_hz),
        (1, 6) => audio_rechannel_1_6(&input, in_hz, out_hz),
        (1, 7) => audio_rechannel_1_7(&input, in_hz, out_hz),
        (1, 8) => audio_rechannel_1_8(&input, in_hz, out_hz),
        (2, 1) => audio_rechannel_2_1(&input, in_hz, out_hz),
        (2, 3) => audio_rechannel_2_3(&input, in_hz, out_hz),
        (2, 4) => audio_rechannel_2_4(&input, in_hz, out_hz),
        (2, 5) => audio_rechannel_2_5(&input, in_hz, out_hz),
        (2, 6) => audio_rechannel_2_6(&input, in_hz, out_hz),
        (2, 7) => audio_rechannel_2_7(&input, in_hz, out_hz),
        (2, 8) => audio_rechannel_2_8(&input, in_hz, out_hz),
        (3, 1) => audio_rechannel_3_1(&input, in_hz, out_hz),
        (3, 2) => audio_rechannel_3_2(&input, in_hz, out_hz),
        (3, 4) => audio_rechannel_3_4(&input, in_hz, out_hz),
        (3, 5) => audio_rechannel_3_5(&input, in_hz, out_hz),
        (3, 6) => audio_rechannel_3_6(&input, in_hz, out_hz),
        (3, 7) => audio_rechannel_3_7(&input, in_hz, out_hz),
        (3, 8) => audio_rechannel_3_8(&input, in_hz, out_hz),
        (4, 1) => audio_rechannel_4_1(&input, in_hz, out_hz),
        (4, 2) => audio_rechannel_4_2(&input, in_hz, out_hz),
        (4, 3) => audio_rechannel_4_3(&input, in_hz, out_hz),
        (4, 5) => audio_rechannel_4_5(&input, in_hz, out_hz),
        (4, 6) => audio_rechannel_4_6(&input, in_hz, out_hz),
        (4, 7) => audio_rechannel_4_7(&input, in_hz, out_hz),
        (4, 8) => audio_rechannel_4_8(&input, in_hz, out_hz),
        (5, 1) => audio_rechannel_5_1(&input, in_hz, out_hz),
        (5, 2) => audio_rechannel_5_2(&input, in_hz, out_hz),
        (5, 3) => audio_rechannel_5_3(&input, in_hz, out_hz),
        (5, 4) => audio_rechannel_5_4(&input, in_hz, out_hz),
        (5, 6) => audio_rechannel_5_6(&input, in_hz, out_hz),
        (5, 7) => audio_rechannel_5_7(&input, in_hz, out_hz),
        (5, 8) => audio_rechannel_5_8(&input, in_hz, out_hz),
        (6, 1) => audio_rechannel_6_1(&input, in_hz, out_hz),
        (6, 2) => audio_rechannel_6_2(&input, in_hz, out_hz),
        (6, 3) => audio_rechannel_6_3(&input, in_hz, out_hz),
        (6, 4) => audio_rechannel_6_4(&input, in_hz, out_hz),
        (6, 5) => audio_rechannel_6_5(&input, in_hz, out_hz),
        (6, 7) => audio_rechannel_6_7(&input, in_hz, out_hz),
        (6, 8) => audio_rechannel_6_8(&input, in_hz, out_hz),
        (7, 1) => audio_rechannel_7_1(&input, in_hz, out_hz),
        (7, 2) => audio_rechannel_7_2(&input, in_hz, out_hz),
        (7, 3) => audio_rechannel_7_3(&input, in_hz, out_hz),
        (7, 4) => audio_rechannel_7_4(&input, in_hz, out_hz),
        (7, 5) => audio_rechannel_7_5(&input, in_hz, out_hz),
        (7, 6) => audio_rechannel_7_6(&input, in_hz, out_hz),
        (7, 8) => audio_rechannel_7_8(&input, in_hz, out_hz),
        (8, 1) => audio_rechannel_8_1(&input, in_hz, out_hz),
        (8, 2) => audio_rechannel_8_2(&input, in_hz, out_hz),
        (8, 3) => audio_rechannel_8_3(&input, in_hz, out_hz),
        (8, 4) => audio_rechannel_8_4(&input, in_hz, out_hz),
        (8, 5) => audio_rechannel_8_5(&input, in_hz, out_hz),
        (8, 6) => audio_rechannel_8_6(&input, in_hz, out_hz),
        (8, 7) => audio_rechannel_8_7(&input, in_hz, out_hz),
        _ => input,
    }
}

macro_rules! audio_rechannel {
    ($name:ident, $in_channels:expr, $out_channels:expr) => {
        fn $name(input: &[f32], in_hz: u32, out_hz: u32) -> Vec<f32> {
            use fon::{chan::Ch32, Audio, Frame};
            let mut in_audio =
                Audio::<Ch32, $in_channels>::with_silence(in_hz, input.len() / $in_channels);
            for (x, y) in input.chunks_exact($in_channels).zip(in_audio.iter_mut()) {
                let mut f = Frame::<Ch32, $in_channels>::default();
                let mut i = 0;
                for c in f.channels_mut() {
                    *c = x[i].into();
                    i += 1;
                }
                *y = f;
            }
            Audio::<Ch32, $out_channels>::with_audio(out_hz, &in_audio)
                .as_f32_slice()
                .to_owned()
        }
    };
}

audio_rechannel!(audio_rechannel_1_2, 1, 2);
audio_rechannel!(audio_rechannel_1_3, 1, 3);
audio_rechannel!(audio_rechannel_1_4, 1, 4);
audio_rechannel!(audio_rechannel_1_5, 1, 5);
audio_rechannel!(audio_rechannel_1_6, 1, 6);
audio_rechannel!(audio_rechannel_1_7, 1, 7);
audio_rechannel!(audio_rechannel_1_8, 1, 8);
audio_rechannel!(audio_rechannel_2_1, 2, 1);
audio_rechannel!(audio_rechannel_2_3, 2, 3);
audio_rechannel!(audio_rechannel_2_4, 2, 4);
audio_rechannel!(audio_rechannel_2_5, 2, 5);
audio_rechannel!(audio_rechannel_2_6, 2, 6);
audio_rechannel!(audio_rechannel_2_7, 2, 7);
audio_rechannel!(audio_rechannel_2_8, 2, 8);
audio_rechannel!(audio_rechannel_3_1, 3, 1);
audio_rechannel!(audio_rechannel_3_2, 3, 2);
audio_rechannel!(audio_rechannel_3_4, 3, 4);
audio_rechannel!(audio_rechannel_3_5, 3, 5);
audio_rechannel!(audio_rechannel_3_6, 3, 6);
audio_rechannel!(audio_rechannel_3_7, 3, 7);
audio_rechannel!(audio_rechannel_3_8, 3, 8);
audio_rechannel!(audio_rechannel_4_1, 4, 1);
audio_rechannel!(audio_rechannel_4_2, 4, 2);
audio_rechannel!(audio_rechannel_4_3, 4, 3);
audio_rechannel!(audio_rechannel_4_5, 4, 5);
audio_rechannel!(audio_rechannel_4_6, 4, 6);
audio_rechannel!(audio_rechannel_4_7, 4, 7);
audio_rechannel!(audio_rechannel_4_8, 4, 8);
audio_rechannel!(audio_rechannel_5_1, 5, 1);
audio_rechannel!(audio_rechannel_5_2, 5, 2);
audio_rechannel!(audio_rechannel_5_3, 5, 3);
audio_rechannel!(audio_rechannel_5_4, 5, 4);
audio_rechannel!(audio_rechannel_5_6, 5, 6);
audio_rechannel!(audio_rechannel_5_7, 5, 7);
audio_rechannel!(audio_rechannel_5_8, 5, 8);
audio_rechannel!(audio_rechannel_6_1, 6, 1);
audio_rechannel!(audio_rechannel_6_2, 6, 2);
audio_rechannel!(audio_rechannel_6_3, 6, 3);
audio_rechannel!(audio_rechannel_6_4, 6, 4);
audio_rechannel!(audio_rechannel_6_5, 6, 5);
audio_rechannel!(audio_rechannel_6_7, 6, 7);
audio_rechannel!(audio_rechannel_6_8, 6, 8);
audio_rechannel!(audio_rechannel_7_1, 7, 1);
audio_rechannel!(audio_rechannel_7_2, 7, 2);
audio_rechannel!(audio_rechannel_7_3, 7, 3);
audio_rechannel!(audio_rechannel_7_4, 7, 4);
audio_rechannel!(audio_rechannel_7_5, 7, 5);
audio_rechannel!(audio_rechannel_7_6, 7, 6);
audio_rechannel!(audio_rechannel_7_8, 7, 8);
audio_rechannel!(audio_rechannel_8_1, 8, 1);
audio_rechannel!(audio_rechannel_8_2, 8, 2);
audio_rechannel!(audio_rechannel_8_3, 8, 3);
audio_rechannel!(audio_rechannel_8_4, 8, 4);
audio_rechannel!(audio_rechannel_8_5, 8, 5);
audio_rechannel!(audio_rechannel_8_6, 8, 6);
audio_rechannel!(audio_rechannel_8_7, 8, 7);

pub struct CheckTestNatType {
    is_direct: bool,
}

impl CheckTestNatType {
    pub fn new() -> Self {
        Self {
            is_direct: Config::get_socks().is_none() && !config::use_ws(),
        }
    }
}

impl Drop for CheckTestNatType {
    fn drop(&mut self) {
        let is_direct = Config::get_socks().is_none() && !config::use_ws();
        if self.is_direct != is_direct {
            test_nat_type();
        }
    }
}

pub fn test_nat_type() {
    test_ipv6_sync();
    use std::sync::atomic::{AtomicBool, Ordering};
    std::thread::spawn(move || {
        static IS_RUNNING: AtomicBool = AtomicBool::new(false);
        if IS_RUNNING.load(Ordering::SeqCst) {
            return;
        }
        IS_RUNNING.store(true, Ordering::SeqCst);

        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        crate::ipc::get_socks_ws();
        let is_direct = Config::get_socks().is_none() && !config::use_ws();
        if !is_direct {
            Config::set_nat_type(NatType::SYMMETRIC as _);
            IS_RUNNING.store(false, Ordering::SeqCst);
            return;
        }

        let mut i = 0;
        loop {
            match test_nat_type_() {
                Ok(true) => break,
                Err(err) => {
                    log::error!("test nat: {}", err);
                }
                _ => {}
            }
            if Config::get_nat_type() != 0 {
                break;
            }
            i = i * 2 + 1;
            if i > 300 {
                i = 300;
            }
            std::thread::sleep(std::time::Duration::from_secs(i));
        }

        IS_RUNNING.store(false, Ordering::SeqCst);
    });
}

#[tokio::main(flavor = "current_thread")]
async fn test_nat_type_() -> ResultType<bool> {
    log::info!("Testing nat ...");
    let start = std::time::Instant::now();
    let server1 = Config::get_rendezvous_server();
    let server2 = crate::increase_port(&server1, -1);
    let mut msg_out = RendezvousMessage::new();
    let serial = Config::get_serial();
    msg_out.set_test_nat_request(TestNatRequest {
        serial,
        ..Default::default()
    });
    let mut port1 = 0;
    let mut port2 = 0;
    let mut local_addr = None;
    let key = crate::get_key(true).await;
    for i in 0..2 {
        let server = if i == 0 { &*server1 } else { &*server2 };
        let mut socket =
            socket_client::connect_tcp_local(server, local_addr, CONNECT_TIMEOUT).await?;
        if i == 0 {
            // reuse the local addr is required for nat test
            local_addr = Some(socket.local_addr());
            Config::set_option(
                "local-ip-addr".to_owned(),
                socket.local_addr().ip().to_string(),
            );
        }
        secure_tcp_silent(&mut socket, &key).await?;
        socket.send(&msg_out).await?;
        if let Some(msg_in) = get_next_nonkeyexchange_msg(&mut socket, None).await {
            if let Some(rendezvous_message::Union::TestNatResponse(tnr)) = msg_in.union {
                log::debug!("Got nat response from {}: port={}", server, tnr.port);
                if i == 0 {
                    port1 = tnr.port;
                } else {
                    port2 = tnr.port;
                }
                if let Some(cu) = tnr.cu.as_ref() {
                    Config::set_option(
                        "rendezvous-servers".to_owned(),
                        cu.rendezvous_servers.join(","),
                    );
                    Config::set_serial(cu.serial);
                }
            }
        } else {
            break;
        }
    }
    let ok = port1 > 0 && port2 > 0;
    if ok {
        let t = if port1 == port2 {
            NatType::ASYMMETRIC
        } else {
            NatType::SYMMETRIC
        };
        Config::set_nat_type(t as _);
        log::info!("Tested nat type: {:?} in {:?}", t, start.elapsed());
    }
    Ok(ok)
}

pub async fn get_rendezvous_server(ms_timeout: u64) -> (String, Vec<String>, bool) {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let (mut a, mut b) = get_rendezvous_server_(ms_timeout);
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let (mut a, mut b) = get_rendezvous_server_(ms_timeout).await;
    #[cfg(windows)]
    if let Ok(lic) = crate::platform::get_license_from_exe_name() {
        if !lic.host.is_empty() {
            a = lic.host;
        }
    }
    let mut b: Vec<String> = b
        .drain(..)
        .map(|x| x.trim().to_owned())
        .filter(|x| !x.is_empty())
        .map(|x| socket_client::check_port(x, config::RENDEZVOUS_PORT))
        .collect();
    let c = if b.contains(&a) {
        b = b.drain(..).filter(|x| x != &a).collect();
        true
    } else {
        a = b.pop().unwrap_or(a);
        false
    };
    (a, b, c)
}

#[inline]
#[cfg(any(target_os = "android", target_os = "ios"))]
fn get_rendezvous_server_(_ms_timeout: u64) -> (String, Vec<String>) {
    (
        Config::get_rendezvous_server(),
        Config::get_rendezvous_servers(),
    )
}

#[inline]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
async fn get_rendezvous_server_(ms_timeout: u64) -> (String, Vec<String>) {
    crate::ipc::get_rendezvous_server(ms_timeout).await
}

#[inline]
#[cfg(any(target_os = "android", target_os = "ios"))]
pub async fn get_nat_type(_ms_timeout: u64) -> i32 {
    Config::get_nat_type()
}

#[inline]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub async fn get_nat_type(ms_timeout: u64) -> i32 {
    crate::ipc::get_nat_type(ms_timeout).await
}

// used for client to test which server is faster in case stop-servic=Y
#[tokio::main(flavor = "current_thread")]
async fn test_rendezvous_server_() {
    let servers = Config::get_rendezvous_servers();
    if servers.len() <= 1 {
        return;
    }
    let mut futs = Vec::new();
    for host in servers {
        futs.push(tokio::spawn(async move {
            let tm = std::time::Instant::now();
            let connection = socket_client::connect_tcp(
                crate::check_port(&host, RENDEZVOUS_PORT),
                CONNECT_TIMEOUT,
            )
            .await;
            let healthy = if let Ok(mut connection) = connection {
                let key = crate::get_key(true).await;
                secure_tcp_silent(&mut connection, &key).await.is_ok()
            } else {
                false
            };
            if healthy {
                let elapsed = tm.elapsed().as_micros();
                Config::update_latency(&host, elapsed as _);
            } else {
                Config::update_latency(&host, -1);
            }
        }));
    }
    join_all(futs).await;
    Config::reset_online();
}

pub fn test_rendezvous_server() {
    std::thread::spawn(test_rendezvous_server_);
}

pub fn refresh_rendezvous_server() {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    test_rendezvous_server();
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    std::thread::spawn(|| {
        if crate::ipc::test_rendezvous_server().is_err() {
            test_rendezvous_server();
        }
    });
}

pub fn run_me<T: AsRef<std::ffi::OsStr>>(args: Vec<T>) -> std::io::Result<std::process::Child> {
    #[cfg(target_os = "linux")]
    if let Ok(appdir) = std::env::var("APPDIR") {
        let appimage_cmd = std::path::Path::new(&appdir).join("AppRun");
        if appimage_cmd.exists() {
            log::info!("path: {:?}", appimage_cmd);
            return std::process::Command::new(appimage_cmd).args(&args).spawn();
        }
    }
    let cmd = std::env::current_exe()?;
    let mut cmd = std::process::Command::new(cmd);
    #[cfg(windows)]
    let mut force_foreground = false;
    #[cfg(windows)]
    {
        let arg_strs = args
            .iter()
            .map(|x| x.as_ref().to_string_lossy())
            .collect::<Vec<_>>();
        if arg_strs == vec!["--install"] || arg_strs == &["--noinstall"] {
            cmd.env(crate::platform::SET_FOREGROUND_WINDOW, "1");
            force_foreground = true;
        }
    }
    let result = cmd.args(&args).spawn();
    match result.as_ref() {
        Ok(_child) =>
        {
            #[cfg(windows)]
            if force_foreground {
                unsafe { winapi::um::winuser::AllowSetForegroundWindow(_child.id() as u32) };
            }
        }
        Err(err) => log::error!("run_me: {err:?}"),
    }
    result
}

#[inline]
pub fn username() -> String {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    return whoami::username()
        .unwrap_or_default()
        .trim_end_matches('\0')
        .to_owned();
    #[cfg(any(target_os = "android", target_os = "ios"))]
    return DEVICE_NAME.lock().unwrap().clone();
}

#[inline(always)]
#[cfg(not(target_os = "ios"))]
pub fn whoami_hostname() -> String {
    let mut hostname = whoami::hostname().unwrap_or_else(|_| "localhost".to_string());
    hostname.make_ascii_lowercase();
    hostname
}

#[inline]
pub fn hostname() -> String {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        #[allow(unused_mut)]
        let mut name = whoami_hostname();
        // some time, there is .local, some time not, so remove it for osx
        #[cfg(target_os = "macos")]
        if name.ends_with(".local") {
            name = name.trim_end_matches(".local").to_owned();
        }
        name
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    return DEVICE_NAME.lock().unwrap().clone();
}

#[inline]
pub fn get_sysinfo() -> serde_json::Value {
    use camellia_remote_protocol::sysinfo::System;
    let mut system = System::new();
    system.refresh_memory();
    system.refresh_cpu();
    let memory = system.total_memory();
    let memory = (memory as f64 / 1024. / 1024. / 1024. * 100.).round() / 100.;
    let cpus = system.cpus();
    let cpu_name = cpus.first().map(|x| x.brand()).unwrap_or_default();
    let cpu_name = cpu_name.trim_end();
    let cpu_freq = cpus.first().map(|x| x.frequency()).unwrap_or_default();
    let cpu_freq = (cpu_freq as f64 / 1024. * 100.).round() / 100.;
    let cpu = if cpu_freq > 0. {
        format!("{}, {}GHz, ", cpu_name, cpu_freq)
    } else {
        "".to_owned() // android
    };
    let num_cpus = num_cpus::get();
    let num_pcpus = num_cpus::get_physical();
    let mut os = system.distribution_id();
    os = format!("{} / {}", os, system.long_os_version().unwrap_or_default());
    #[cfg(windows)]
    {
        os = format!("{os} - {}", system.os_version().unwrap_or_default());
    }
    let hostname = hostname(); // sys.hostname() return localhost on android in my test
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let out;
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let mut out;
    out = json!({
        "cpu": format!("{cpu}{num_cpus}/{num_pcpus} cores"),
        "memory": format!("{memory}GB"),
        "os": os,
        "hostname": hostname,
    });
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        let username = crate::platform::get_active_username();
        if !username.is_empty() && (!cfg!(windows) || username != "SYSTEM") {
            out["username"] = json!(username);
        }
    }
    out
}

#[inline]
pub fn check_port<T: std::string::ToString>(host: T, port: i32) -> String {
    camellia_remote_protocol::socket_client::check_port(host, port)
}

#[inline]
pub fn increase_port<T: std::string::ToString>(host: T, offset: i32) -> String {
    camellia_remote_protocol::socket_client::increase_port(host, offset)
}

pub const POSTFIX_SERVICE: &'static str = "_service";

#[inline]
pub fn is_control_key(evt: &KeyEvent, key: &ControlKey) -> bool {
    if let Some(key_event::Union::ControlKey(ck)) = evt.union {
        ck.value() == key.value()
    } else {
        false
    }
}

#[inline]
pub fn is_modifier(evt: &KeyEvent) -> bool {
    if let Some(key_event::Union::ControlKey(ck)) = evt.union {
        let v = ck.value();
        v == ControlKey::Alt.value()
            || v == ControlKey::Shift.value()
            || v == ControlKey::Control.value()
            || v == ControlKey::Meta.value()
            || v == ControlKey::RAlt.value()
            || v == ControlKey::RShift.value()
            || v == ControlKey::RControl.value()
            || v == ControlKey::RWin.value()
    } else {
        false
    }
}

#[inline]
pub fn get_app_name() -> String {
    camellia_remote_protocol::config::APP_NAME
        .read()
        .unwrap()
        .clone()
}

#[inline]
pub fn get_uri_prefix() -> String {
    "camellia-remote://".to_owned()
}

#[cfg(target_os = "macos")]
pub fn get_full_name() -> String {
    format!(
        "{}.{}",
        camellia_remote_protocol::config::ORG.read().unwrap(),
        camellia_remote_protocol::config::APP_NAME.read().unwrap(),
    )
}

pub fn is_setup(name: &str) -> bool {
    !config::is_disable_installation() && name.to_lowercase().ends_with("install.exe")
}

pub fn get_custom_rendezvous_server(custom: String) -> String {
    #[cfg(windows)]
    if let Ok(lic) = crate::platform::windows::get_license_from_exe_name() {
        if !lic.host.is_empty() {
            return lic.host.clone();
        }
    }
    if !custom.is_empty() {
        return custom;
    }
    if !config::PROD_RENDEZVOUS_SERVER.read().unwrap().is_empty() {
        return config::PROD_RENDEZVOUS_SERVER.read().unwrap().clone();
    }
    "".to_owned()
}

#[inline]
pub fn get_api_server(api: String, custom: String) -> String {
    if Config::no_register_device() {
        return "".to_owned();
    }
    let mut res = get_api_server_(api, custom);
    if res.ends_with('/') {
        res.pop();
    }
    if res.starts_with("https")
        && res.ends_with(":21114")
        && get_builtin_option(keys::OPTION_ALLOW_HTTPS_21114) != "Y"
    {
        return res.replace(":21114", "");
    }
    res
}

fn get_api_server_(api: String, custom: String) -> String {
    #[cfg(windows)]
    if let Ok(lic) = crate::platform::windows::get_license_from_exe_name() {
        if !lic.api.is_empty() {
            return lic.api.clone();
        }
    }
    if !api.is_empty() {
        return api.to_owned();
    }
    let api = config::API_SERVER.read().unwrap().clone();
    if !api.is_empty() {
        return api;
    }
    let s0 = get_custom_rendezvous_server(custom);
    if !s0.is_empty() {
        let s = crate::increase_port(&s0, -2);
        if s == s0 {
            return format!("http://{}:{}", s, config::RENDEZVOUS_PORT - 2);
        } else {
            return format!("http://{}", s);
        }
    }
    "".to_owned()
}

#[inline]
pub fn is_public(_url: &str) -> bool {
    // This fresh baseline has no compiled-in vendor-operated API. Every
    // management endpoint is operator-configured and therefore follows the
    // self-hosted proxy and synchronization path.
    false
}

pub fn get_udp_punch_enabled() -> bool {
    // Honor the global "Disable UDP" switch by short-circuiting all UDP punch logic.
    !is_udp_disabled()
        && config::option2bool(
            keys::OPTION_ENABLE_UDP_PUNCH,
            &get_local_option(keys::OPTION_ENABLE_UDP_PUNCH),
        )
}

pub fn get_ipv6_punch_enabled() -> bool {
    config::option2bool(
        keys::OPTION_ENABLE_IPV6_PUNCH,
        &get_local_option(keys::OPTION_ENABLE_IPV6_PUNCH),
    )
}

pub fn get_local_option(key: &str) -> String {
    LocalConfig::get_option(key)
}

pub fn get_audit_server(api: String, custom: String, typ: String) -> String {
    let url = get_api_server(api, custom);
    if url.is_empty() {
        return "".to_owned();
    }
    format!("{}/api/audit/{}", url, typ)
}

/// Authorization header for API requests made by the native service.
///
/// Device telemetry, audit events, and recording uploads are privileged data.
/// Callers must skip the request when there is no account session instead of
/// falling back to public device identifiers.
pub fn get_api_access_token() -> Option<String> {
    let token = LocalConfig::get_option("access_token");
    if token.is_empty()
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        None
    } else {
        Some(token)
    }
}

pub fn get_api_auth_header() -> Option<String> {
    get_api_access_token().map(|token| format!("Authorization: Bearer {token}"))
}

#[derive(Clone, Copy)]
struct RawTcpPolicy {
    first: bool,
    fallback: bool,
}

impl RawTcpPolicy {
    fn capture(
        url: &str,
        api: &str,
        proxy_configured: bool,
        websocket: bool,
        force_raw: bool,
    ) -> Self {
        let allowed = !proxy_configured && !websocket && should_use_tcp_proxy_for_api_url(url, api);
        Self {
            first: allowed && force_raw,
            fallback: allowed,
        }
    }
}

#[inline]
fn should_use_tcp_proxy_for_api_url(url: &str, api_url: &str) -> bool {
    if api_url.is_empty() || is_public(api_url) {
        return false;
    }

    match (url::Url::parse(url), url::Url::parse(api_url)) {
        (Ok(target), Ok(api)) => {
            matches!(target.scheme(), "http" | "https")
                && matches!(api.scheme(), "http" | "https")
                && target.has_host()
                && api.has_host()
                && target.origin() == api.origin()
                && target.username().is_empty()
                && target.password().is_none()
                && api.username().is_empty()
                && api.password().is_none()
        }
        _ => false,
    }
}

fn tcp_proxy_log_target(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .map(|parsed| {
            let mut redacted = format!("{}://", parsed.scheme());
            let Some(host) = parsed.host() else {
                return "<invalid-url>".to_owned();
            };
            redacted.push_str(&host.to_string());
            if let Some(port) = parsed.port() {
                redacted.push(':');
                redacted.push_str(&port.to_string());
            }
            redacted.push_str(parsed.path());
            redacted
        })
        .unwrap_or_else(|| "<invalid-url>".to_owned())
}

#[inline]
fn get_tcp_proxy_addr() -> String {
    check_port(Config::get_rendezvous_server(), RENDEZVOUS_PORT)
}

/// Owned routing inputs; never re-read configuration after request admission.
pub(crate) struct RawTcpContext {
    endpoint: String,
    key: String,
}

pub(crate) async fn capture_raw_tcp_context() -> RawTcpContext {
    RawTcpContext {
        endpoint: get_tcp_proxy_addr(),
        key: crate::get_key(true).await,
    }
}

/// Send an HTTP request via the rendezvous server's TCP proxy using protobuf.
/// Resolves through the shared bounded DNS pool, connects to numeric addresses
/// with the captured no-proxy policy, authenticates, sends `HttpProxyRequest`,
/// receives `HttpProxyResponse`.
///
/// The entire operation (DNS + connect + handshake + send + receive) is wrapped in
/// an overall timeout of `CONNECT_TIMEOUT + READ_TIMEOUT` so that a stall at
/// any stage cannot block the caller indefinitely.
async fn tcp_proxy_request(
    context: RawTcpContext,
    method: &str,
    url: &str,
    body: &[u8],
    headers: Vec<HeaderEntry>,
) -> ResultType<HttpProxyResponse> {
    let RawTcpContext {
        endpoint: tcp_addr,
        key,
    } = context;
    // Validate before DNS/connect, not merely before sending the HTTP body.
    if get_rs_pk(&key).is_none() {
        bail!("raw_tcp_invalid_key");
    }

    let parsed = url::Url::parse(url)?;
    let path = if let Some(query) = parsed.query() {
        format!("{}?{}", parsed.path(), query)
    } else {
        parsed.path().to_string()
    };

    log::debug!(
        "Sending {} {} via TCP proxy to {}",
        method,
        parsed.path(),
        tcp_addr
    );

    let overall_timeout = CONNECT_TIMEOUT + READ_TIMEOUT;
    timeout(overall_timeout, async {
        // One DNS+connect budget, not one timeout per returned address. A
        // cancelled OS lookup retains its shared permit until getaddrinfo ends.
        let mut conn = timeout(CONNECT_TIMEOUT, async {
            let addresses = crate::hbbs_http::resolve_endpoint(&tcp_addr)
                .await.map_err(|_| anyhow!("raw_tcp_dns_failed"))?;
            for address in addresses {
                if let Ok(mut connection) = camellia_remote_protocol::tcp::FramedStream::new(
                    address, None, CONNECT_TIMEOUT,
                ).await {
                    *connection.0.codec_mut() = camellia_remote_protocol::bytes_codec::BytesCodec::with_max_packet_length(
                        camellia_remote_protocol::bytes_codec::RENDEZVOUS_CONTROL_MAX_PACKET_LENGTH,
                    );
                    return Ok(Stream::Tcp(connection));
                }
            }
            Err(anyhow!("raw_tcp_connect_failed"))
        }).await??;
        secure_tcp_silent(&mut conn, &key).await?;

        let mut req = HttpProxyRequest::new();
        req.method = method.to_uppercase();
        req.path = path;
        req.headers = headers.into();
        req.body = Bytes::from(body.to_vec());
        req.licence_key = key;

        let mut msg_out = RendezvousMessage::new();
        msg_out.set_http_proxy_request(req);
        conn.send(&msg_out).await?;

        match conn.next().await {
            Some(Ok(bytes)) => {
                let msg_in = RendezvousMessage::parse_from_bytes(&bytes)?;
                match msg_in.union {
                    Some(rendezvous_message::Union::HttpProxyResponse(resp)) => Ok(resp),
                    _ => bail!("Unexpected response from TCP proxy"),
                }
            }
            Some(Err(e)) => bail!("TCP proxy read error: {}", e),
            None => bail!("TCP proxy connection closed without response"),
        }
    })
    .await?
}

/// The UI bridge chooses one route before sending, never HTTP then TCP replay.
/// Unlike the historical fallback helper, this requires the full API origin.
pub(crate) fn bridge_raw_tcp_target(url: &str) -> bool {
    if get_builtin_option(keys::OPTION_USE_RAW_TCP_FOR_API) != "Y" || use_ws() {
        return false;
    }
    match (url::Url::parse(url), url::Url::parse(&ui_get_api_server())) {
        (Ok(target), Ok(api)) => target.origin() == api.origin(),
        _ => false,
    }
}

pub(crate) async fn bridge_raw_tcp_request(
    context: RawTcpContext,
    url: &str,
    method: &str,
    body: &[u8],
    headers: Vec<HeaderEntry>,
) -> ResultType<HttpProxyResponse> {
    tcp_proxy_request(context, method, url, body, headers).await
}

/// Build HeaderEntry list from "Key: Value" style header string (used by post_request).
/// If the caller supplies a Content-Type header it overrides the default `application/json`.
fn parse_simple_header(header: &str) -> Vec<HeaderEntry> {
    let mut entries = Vec::new();
    let mut has_content_type = false;
    if !header.is_empty() {
        let tmp: Vec<&str> = header.splitn(2, ": ").collect();
        if tmp.len() == 2 {
            if tmp[0].eq_ignore_ascii_case("Content-Type") {
                has_content_type = true;
            }
            entries.push(HeaderEntry {
                name: tmp[0].into(),
                value: tmp[1].into(),
                ..Default::default()
            });
        }
    }
    if !has_content_type {
        entries.insert(
            0,
            HeaderEntry {
                name: "Content-Type".into(),
                value: "application/json".into(),
                ..Default::default()
            },
        );
    }
    entries
}

fn post_header_entries(header: &str, operation: &HttpOperation) -> Vec<HeaderEntry> {
    let mut entries = parse_simple_header(header);
    entries.retain(|entry| {
        !entry.name.eq_ignore_ascii_case(TRACEPARENT_HEADER)
            && !entry.name.eq_ignore_ascii_case(CAMELLIA_EVENT_ID_HEADER)
    });
    entries.extend(
        operation
            .correlation_headers()
            .into_iter()
            .map(|(name, value)| HeaderEntry {
                name,
                value,
                ..Default::default()
            }),
    );
    entries
}

/// POST request via TCP proxy.
async fn post_request_via_tcp_proxy(
    context: RawTcpContext,
    url: &str,
    body: &str,
    header: &str,
    operation: &HttpOperation,
) -> ResultType<String> {
    let headers = post_header_entries(header, operation);
    let resp = tcp_proxy_request(context, "POST", url, body.as_bytes(), headers).await?;
    if !resp.error.is_empty() {
        bail!("TCP proxy error: {}", resp.error);
    }
    Ok(String::from_utf8_lossy(&resp.body).to_string())
}

async fn post_request_http(
    url: &str,
    body: &str,
    header: &str,
    operation: &HttpOperation,
    proxy_conf: &Option<Socks5Server>,
) -> ResultType<(u16, String)> {
    let client = create_http_client_async_for_configuration(proxy_conf.as_ref())?;
    let response = post_request_(
        url,
        body.to_owned(),
        post_header_entries(header, operation),
        client,
    )
    .await?;
    let status = response.status().as_u16();
    let text = response.text().await?;
    Ok((status, text))
}

/// Try `http_fn` first; on connection failure or 5xx, fall back to `tcp_fn`
/// if the URL is eligible. 4xx responses are returned as-is.
async fn with_tcp_proxy_fallback<HttpFut, TcpFut>(
    url: &str,
    method: &str,
    policy: RawTcpPolicy,
    http_fn: HttpFut,
    tcp_fn: TcpFut,
) -> ResultType<String>
where
    HttpFut: Future<Output = ResultType<(u16, String)>>,
    TcpFut: Future<Output = ResultType<String>>,
{
    if policy.first {
        return tcp_fn.await;
    }

    let http_result = http_fn.await;
    let should_fallback = match &http_result {
        Err(_) => true,
        Ok((status, _)) => *status >= 500,
    };

    if should_fallback && policy.fallback {
        log::warn!(
            "HTTP {} to {} failed or 5xx (result: {:?}), trying TCP proxy fallback",
            method,
            tcp_proxy_log_target(url),
            http_result
                .as_ref()
                .map(|(s, _)| *s)
                .map_err(|e| e.to_string()),
        );
        match tcp_fn.await {
            Ok(resp) => return Ok(resp),
            Err(tcp_err) => {
                log::warn!("TCP proxy fallback also failed: {:?}", tcp_err);
            }
        }
    }

    http_result.map(|(_status, text)| text)
}

/// POST request with raw TCP proxy support.
/// - If `USE_RAW_TCP_FOR_API` is "Y" and WS is off, goes directly through TCP proxy.
/// - Otherwise tries HTTP first; on connection failure or 5xx status,
///   falls back to TCP proxy if WS is off.
/// - 4xx responses are returned as-is (server is reachable, business logic error).
/// - If fallback also fails, returns the original HTTP result (text or error).
pub async fn post_request(url: String, body: String, header: &str) -> ResultType<String> {
    let operation = HttpOperation::new();
    post_request_with_operation(url, body, header, &operation).await
}

pub(crate) async fn post_request_with_operation(
    url: String,
    body: String,
    header: &str,
    operation: &HttpOperation,
) -> ResultType<String> {
    // One operation has one captured proxy policy. Changes to live settings
    // cannot turn a failed explicit proxy into a later direct/raw-TCP attempt.
    let proxy_conf = Config::get_socks();
    let policy = RawTcpPolicy::capture(
        &url,
        &ui_get_api_server(),
        proxy_conf.is_some(),
        use_ws(),
        get_builtin_option(keys::OPTION_USE_RAW_TCP_FOR_API) == "Y",
    );
    let raw_context = capture_raw_tcp_context().await;
    with_tcp_proxy_fallback(
        &url,
        "POST",
        policy,
        post_request_http(&url, &body, header, operation, &proxy_conf),
        post_request_via_tcp_proxy(raw_context, &url, &body, header, operation),
    )
    .await
}

async fn post_request_(
    url: &str,
    body: String,
    headers: Vec<HeaderEntry>,
    client: reqwest::Client,
) -> ResultType<reqwest::Response> {
    let mut req = client.post(url);
    for entry in headers {
        req = req.header(entry.name, entry.value);
    }
    let to = std::time::Duration::from_secs(12);
    match req.body(body).timeout(to).send().await {
        Ok(resp) => Ok(resp),
        Err(e) => Err(anyhow!("{:?}", e)),
    }
}

#[tokio::main(flavor = "current_thread")]
pub async fn post_request_sync(url: String, body: String, header: &str) -> ResultType<String> {
    post_request(url, body, header).await
}

#[inline]
pub fn make_privacy_mode_msg_with_details(
    state: back_notification::PrivacyModeState,
    details: String,
    impl_key: String,
) -> Message {
    let mut misc = Misc::new();
    let mut back_notification = BackNotification {
        details,
        impl_key,
        ..Default::default()
    };
    back_notification.set_privacy_mode_state(state);
    misc.set_back_notification(back_notification);
    let mut msg_out = Message::new();
    msg_out.set_misc(misc);
    msg_out
}

#[inline]
pub fn make_privacy_mode_msg(
    state: back_notification::PrivacyModeState,
    impl_key: String,
) -> Message {
    make_privacy_mode_msg_with_details(state, "".to_owned(), impl_key)
}

pub fn is_keyboard_mode_supported(
    keyboard_mode: &KeyboardMode,
    version_number: i64,
    peer_platform: &str,
) -> bool {
    match keyboard_mode {
        KeyboardMode::Legacy => true,
        KeyboardMode::Map => {
            if peer_platform.to_lowercase() == crate::PLATFORM_ANDROID.to_lowercase() {
                false
            } else {
                version_number >= camellia_remote_protocol::get_version_number("1.2.0")
            }
        }
        KeyboardMode::Translate => {
            version_number >= camellia_remote_protocol::get_version_number("1.2.0")
        }
        KeyboardMode::Auto => {
            version_number >= camellia_remote_protocol::get_version_number("1.2.0")
        }
    }
}

pub fn get_supported_keyboard_modes(version: i64, peer_platform: &str) -> Vec<KeyboardMode> {
    KeyboardMode::iter()
        .filter(|&mode| is_keyboard_mode_supported(mode, version, peer_platform))
        .map(|&mode| mode)
        .collect::<Vec<_>>()
}

pub fn make_fd_to_json(id: i32, path: String, entries: &Vec<FileEntry>) -> String {
    let fd_json = _make_fd_to_json(id, path, entries);
    serde_json::to_string(&fd_json).unwrap_or("".into())
}

pub fn _make_fd_to_json(id: i32, path: String, entries: &Vec<FileEntry>) -> Map<String, Value> {
    let mut fd_json = serde_json::Map::new();
    fd_json.insert("id".into(), json!(id));
    fd_json.insert("path".into(), json!(path));

    let mut entries_out = vec![];
    for entry in entries {
        let mut entry_map = serde_json::Map::new();
        entry_map.insert("entry_type".into(), json!(entry.entry_type.value()));
        entry_map.insert("name".into(), json!(entry.name));
        entry_map.insert("size".into(), json!(entry.size));
        entry_map.insert("modified_time".into(), json!(entry.modified_time));
        entries_out.push(entry_map);
    }
    fd_json.insert("entries".into(), json!(entries_out));
    fd_json
}

pub fn make_vec_fd_to_json(fds: &[FileDirectory]) -> String {
    let mut fd_jsons = vec![];

    for fd in fds.iter() {
        let fd_json = _make_fd_to_json(fd.id, fd.path.clone(), &fd.entries);
        fd_jsons.push(fd_json);
    }

    serde_json::to_string(&fd_jsons).unwrap_or("".into())
}

pub fn make_empty_dirs_response_to_json(res: &ReadEmptyDirsResponse) -> String {
    let mut map: Map<String, Value> = serde_json::Map::new();
    map.insert("path".into(), json!(res.path));

    let mut fd_jsons = vec![];

    for fd in res.empty_dirs.iter() {
        let fd_json = _make_fd_to_json(fd.id, fd.path.clone(), &fd.entries);
        fd_jsons.push(fd_json);
    }
    map.insert("empty_dirs".into(), fd_jsons.into());

    serde_json::to_string(&map).unwrap_or("".into())
}

/// The function to handle the url scheme sent by the system.
///
/// 1. Try to send the url scheme from ipc.
/// 2. If failed to send the url scheme, we open a new main window to handle this url scheme.
pub fn handle_url_scheme(url: String) {
    #[cfg(not(target_os = "ios"))]
    if let Err(err) = crate::ipc::send_url_scheme(url.clone()) {
        log::debug!("Send the url to the existing flutter process failed, {}. Let's open a new program to handle this.", err);
        let _ = crate::run_me(vec![url]);
    }
}

#[inline]
pub fn encode64<T: AsRef<[u8]>>(input: T) -> String {
    BASE64.encode(input)
}

#[inline]
pub fn decode64<T: AsRef<[u8]>>(
    input: T,
) -> Result<Vec<u8>, camellia_remote_protocol::base64::DecodeError> {
    BASE64.decode(input)
}

pub async fn get_key(sync: bool) -> String {
    #[cfg(windows)]
    if let Ok(lic) = crate::platform::windows::get_license_from_exe_name() {
        if !lic.key.is_empty() {
            return lic.key;
        }
    }
    #[cfg(target_os = "ios")]
    let mut key = Config::get_option("key");
    #[cfg(not(target_os = "ios"))]
    let mut key = if sync {
        Config::get_option("key")
    } else {
        let mut options = crate::ipc::get_options_async().await;
        options.remove("key").unwrap_or_default()
    };
    if key.is_empty() {
        key = config::RS_PUB_KEY.read().unwrap().clone();
    }
    key
}

pub fn pk_to_fingerprint(pk: Vec<u8>) -> String {
    let s: String = pk.iter().map(|u| format!("{:02x}", u)).collect();
    s.chars()
        .enumerate()
        .map(|(i, c)| {
            if i > 0 && i % 4 == 0 {
                format!(" {}", c)
            } else {
                format!("{}", c)
            }
        })
        .collect()
}

#[inline]
pub async fn get_next_nonkeyexchange_msg(
    conn: &mut Stream,
    timeout: Option<u64>,
) -> Option<RendezvousMessage> {
    let timeout = timeout.unwrap_or(READ_TIMEOUT);
    for _ in 0..2 {
        if let Some(Ok(bytes)) = conn.next_timeout(timeout).await {
            if let Ok(msg_in) = RendezvousMessage::parse_from_bytes(&bytes) {
                match &msg_in.union {
                    Some(rendezvous_message::Union::KeyExchange(_)) => {
                        continue;
                    }
                    _ => {
                        return Some(msg_in);
                    }
                }
            }
        }
        break;
    }
    None
}

#[cfg(all(target_os = "windows", not(target_pointer_width = "64")))]
pub fn check_process(arg: &str, same_session_id: bool) -> bool {
    let mut path = std::env::current_exe().unwrap_or_default();
    if let Ok(linked) = path.read_link() {
        path = linked;
    }
    let Some(filename) = path.file_name() else {
        return false;
    };
    let filename = filename.to_string_lossy().to_string();
    match crate::platform::windows::get_pids_with_first_arg_check_session(
        &filename,
        arg,
        same_session_id,
    ) {
        Ok(pids) => {
            let self_pid = camellia_remote_protocol::sysinfo::Pid::from_u32(std::process::id());
            pids.into_iter().filter(|pid| *pid != self_pid).count() > 0
        }
        Err(e) => {
            log::error!("Failed to check process with arg: \"{}\", {}", arg, e);
            false
        }
    }
}

#[allow(unused_mut)]
#[cfg(not(all(target_os = "windows", not(target_pointer_width = "64"))))]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn check_process(arg: &str, mut same_uid: bool) -> bool {
    #[cfg(target_os = "macos")]
    if !crate::platform::is_root() && !same_uid {
        log::warn!("Can not get other process's command line arguments on macos without root");
        same_uid = true;
    }
    use camellia_remote_protocol::sysinfo::System;
    let mut sys = System::new();
    sys.refresh_processes();
    let mut path = std::env::current_exe().unwrap_or_default();
    if let Ok(linked) = path.read_link() {
        path = linked;
    }
    let path = path.to_string_lossy().to_lowercase();
    let my_uid = sys
        .process((std::process::id() as usize).into())
        .map(|x| x.user_id())
        .unwrap_or_default();
    for (_, p) in sys.processes().iter() {
        let mut cur_path = p.exe().to_path_buf();
        if let Ok(linked) = cur_path.read_link() {
            cur_path = linked;
        }
        if cur_path.to_string_lossy().to_lowercase() != path {
            continue;
        }
        if p.pid().to_string() == std::process::id().to_string() {
            continue;
        }
        if same_uid && p.user_id() != my_uid {
            continue;
        }
        // on mac, p.cmd() get "/Applications/RustDesk.app/Contents/MacOS/RustDesk", "XPC_SERVICE_NAME=com.carriez.RustDesk_server"
        let parg = if p.cmd().len() <= 1 { "" } else { &p.cmd()[1] };
        if arg.is_empty() {
            if !parg.starts_with("--") {
                return true;
            }
        } else if arg == parg {
            return true;
        }
    }
    false
}

async fn secure_tcp_impl(conn: &mut Stream, key: &str, log_on_success: bool) -> ResultType<()> {
    let rs_pk = get_rs_pk(key);
    let Some(rs_pk) = rs_pk else {
        bail!("Handshake failed: invalid public key from rendezvous server");
    };
    let bytes = timeout(READ_TIMEOUT, conn.next())
        .await?
        .ok_or_else(|| anyhow!("Handshake failed: rendezvous server closed the connection"))??;
    let msg_in = RendezvousMessage::parse_from_bytes(&bytes)
        .context("Handshake failed: invalid rendezvous response")?;
    let Some(rendezvous_message::Union::KeyExchange(ex)) = msg_in.union else {
        bail!("Handshake failed: key exchange response was required");
    };
    if ex.keys.len() != 1 {
        bail!("Handshake failed: invalid key exchange message");
    }
    let their_pk_b = sign::verify(&ex.keys[0], &rs_pk)
        .map_err(|_| anyhow!("Signature mismatch in key exchange"))?;
    let (asymmetric_value, symmetric_value, key) = create_symmetric_key_msg(
        get_pk(&their_pk_b).context("Wrong their public length in key exchange")?,
    )?;
    let mut msg_out = RendezvousMessage::new();
    msg_out.set_key_exchange(KeyExchange {
        keys: vec![asymmetric_value, symmetric_value],
        ..Default::default()
    });
    timeout(CONNECT_TIMEOUT, conn.send(&msg_out)).await??;
    conn.set_key(key, CipherRole::Initiator);
    if !conn.is_secured() {
        bail!("Handshake failed: secure channel was not activated");
    }
    if log_on_success {
        log::info!("Connection secured");
    }
    Ok(())
}

pub async fn secure_tcp(conn: &mut Stream, key: &str) -> ResultType<()> {
    secure_tcp_impl(conn, key, true).await
}

async fn secure_tcp_silent(conn: &mut Stream, key: &str) -> ResultType<()> {
    secure_tcp_impl(conn, key, false).await
}

#[inline]
pub fn get_pk(pk: &[u8]) -> Option<[u8; 32]> {
    if pk.len() == 32 {
        let mut tmp = [0u8; 32];
        tmp[..].copy_from_slice(&pk);
        Some(tmp)
    } else {
        None
    }
}

#[inline]
pub fn get_rs_pk(str_base64: &str) -> Option<sign::PublicKey> {
    if let Ok(pk) = crate::decode64(str_base64) {
        get_pk(&pk).and_then(|x| sign::PublicKey::from_slice(&x))
    } else {
        None
    }
}

pub fn decode_id_pk(signed: &[u8], key: &sign::PublicKey) -> ResultType<(String, [u8; 32])> {
    let res = IdPk::parse_from_bytes(
        &sign::verify(signed, key).map_err(|_| anyhow!("Signature mismatch"))?,
    )?;
    if let Some(pk) = get_pk(&res.pk) {
        Ok((res.id, pk))
    } else {
        bail!("Wrong their public length");
    }
}

pub fn create_symmetric_key_msg(
    their_pk_b: [u8; 32],
) -> ResultType<(Bytes, Bytes, secretbox::Key)> {
    let their_pk_b = box_::PublicKey(their_pk_b);
    let (our_pk_b, out_sk_b) = box_::gen_keypair();
    let key = secretbox::gen_key();
    let nonce = box_::Nonce([0u8; box_::NONCEBYTES]);
    let key_envelope = Encrypt::encode_session_key(&key);
    let sealed_key = box_::seal(&key_envelope, &nonce, &their_pk_b, &out_sk_b)
        .map_err(|_| anyhow!("Handshake failed: session key encryption failed"))?;
    Ok((Vec::from(our_pk_b.0).into(), sealed_key.into(), key))
}

#[inline]
pub fn using_public_server() -> bool {
    false
}

pub struct ThrottledInterval {
    interval: Interval,
    next_tick: Instant,
    min_interval: Duration,
}

impl ThrottledInterval {
    pub fn new(i: Interval) -> ThrottledInterval {
        let period = i.period();
        ThrottledInterval {
            interval: i,
            next_tick: Instant::now(),
            min_interval: Duration::from_secs_f64(period.as_secs_f64() * 0.9),
        }
    }

    pub async fn tick(&mut self) -> Instant {
        let instant = poll_fn(|cx| self.poll_tick(cx));
        instant.await
    }

    pub fn poll_tick(&mut self, cx: &mut std::task::Context<'_>) -> Poll<Instant> {
        match self.interval.poll_tick(cx) {
            Poll::Ready(instant) => {
                let now = Instant::now();
                if self.next_tick <= now {
                    self.next_tick = now + self.min_interval;
                    Poll::Ready(instant)
                } else {
                    // This call is required since tokio 1.27
                    cx.waker().wake_by_ref();
                    Poll::Pending
                }
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

pub type RustDeskInterval = ThrottledInterval;

#[inline]
pub fn rustdesk_interval(i: Interval) -> ThrottledInterval {
    ThrottledInterval::new(i)
}

pub fn load_custom_client() {
    #[cfg(debug_assertions)]
    if let Ok(data) = std::fs::read_to_string("./custom.txt") {
        read_custom_client(data.trim());
        return;
    }
    let Some(path) = std::env::current_exe().map_or(None, |x| x.parent().map(|x| x.to_path_buf()))
    else {
        return;
    };
    #[cfg(target_os = "macos")]
    let path = path.join("../Resources");
    let path = path.join("custom.txt");
    if path.is_file() {
        let Ok(data) = std::fs::read_to_string(&path) else {
            log::error!("Failed to read custom client config");
            return;
        };
        read_custom_client(&data.trim());
    }
}

fn read_custom_client_advanced_settings(
    settings: serde_json::Value,
    map_display_settings: &HashMap<String, &&str>,
    map_local_settings: &HashMap<String, &&str>,
    map_settings: &HashMap<String, &&str>,
    map_buildin_settings: &HashMap<String, &&str>,
    is_override: bool,
) {
    let mut display_settings = if is_override {
        config::OVERWRITE_DISPLAY_SETTINGS.write().unwrap()
    } else {
        config::DEFAULT_DISPLAY_SETTINGS.write().unwrap()
    };
    let mut local_settings = if is_override {
        config::OVERWRITE_LOCAL_SETTINGS.write().unwrap()
    } else {
        config::DEFAULT_LOCAL_SETTINGS.write().unwrap()
    };
    let mut server_settings = if is_override {
        config::OVERWRITE_SETTINGS.write().unwrap()
    } else {
        config::DEFAULT_SETTINGS.write().unwrap()
    };
    let mut buildin_settings = config::BUILTIN_SETTINGS.write().unwrap();

    if let Some(settings) = settings.as_object() {
        for (k, v) in settings {
            let Some(v) = v.as_str() else {
                continue;
            };
            if let Some(k2) = map_display_settings.get(k) {
                display_settings.insert(k2.to_string(), v.to_owned());
            } else if let Some(k2) = map_local_settings.get(k) {
                local_settings.insert(k2.to_string(), v.to_owned());
            } else if let Some(k2) = map_settings.get(k) {
                server_settings.insert(k2.to_string(), v.to_owned());
            } else if let Some(k2) = map_buildin_settings.get(k) {
                buildin_settings.insert(k2.to_string(), v.to_owned());
            } else {
                let k2 = k.replace("_", "-");
                let k = k2.replace("-", "_");
                // display
                display_settings.insert(k.clone(), v.to_owned());
                display_settings.insert(k2.clone(), v.to_owned());
                // local
                local_settings.insert(k.clone(), v.to_owned());
                local_settings.insert(k2.clone(), v.to_owned());
                // server
                server_settings.insert(k.clone(), v.to_owned());
                server_settings.insert(k2.clone(), v.to_owned());
                // buildin
                buildin_settings.insert(k.clone(), v.to_owned());
                buildin_settings.insert(k2.clone(), v.to_owned());
            }
        }
    }
}

#[inline]
#[cfg(target_os = "macos")]
pub fn get_dst_align_rgba() -> usize {
    // https://developer.apple.com/forums/thread/712709
    // Memory alignment should be multiple of 64.
    if crate::ui_interface::use_texture_render() {
        64
    } else {
        1
    }
}

#[inline]
#[cfg(not(target_os = "macos"))]
pub fn get_dst_align_rgba() -> usize {
    1
}

pub fn read_custom_client(config: &str) {
    let Ok(data) = decode64(config) else {
        log::error!("Failed to decode custom client config");
        return;
    };
    const KEY: &str = "";
    let data = if KEY.is_empty() {
        data
    } else {
        let Some(pk) = get_rs_pk(KEY) else {
            log::error!("Failed to parse public key of custom client");
            return;
        };
        let Ok(data) = sign::verify(&data, &pk) else {
            log::error!("Failed to dec custom client config");
            return;
        };
        data
    };
    let Ok(mut data) =
        serde_json::from_slice::<std::collections::HashMap<String, serde_json::Value>>(&data)
    else {
        log::error!("Failed to parse custom client config");
        return;
    };

    if let Some(app_name) = data.remove("app-name") {
        if let Some(app_name) = app_name.as_str() {
            *config::APP_NAME.write().unwrap() = app_name.to_owned();
        }
    }

    let mut map_display_settings = HashMap::new();
    for s in keys::KEYS_DISPLAY_SETTINGS {
        map_display_settings.insert(s.replace("_", "-"), s);
    }
    let mut map_local_settings = HashMap::new();
    for s in keys::KEYS_LOCAL_SETTINGS {
        map_local_settings.insert(s.replace("_", "-"), s);
    }
    let mut map_settings = HashMap::new();
    for s in keys::KEYS_SETTINGS {
        map_settings.insert(s.replace("_", "-"), s);
    }
    let mut buildin_settings = HashMap::new();
    for s in keys::KEYS_BUILDIN_SETTINGS {
        buildin_settings.insert(s.replace("_", "-"), s);
    }
    if let Some(default_settings) = data.remove("default-settings") {
        read_custom_client_advanced_settings(
            default_settings,
            &map_display_settings,
            &map_local_settings,
            &map_settings,
            &buildin_settings,
            false,
        );
    }
    if let Some(overwrite_settings) = data.remove("override-settings") {
        read_custom_client_advanced_settings(
            overwrite_settings,
            &map_display_settings,
            &map_local_settings,
            &map_settings,
            &buildin_settings,
            true,
        );
    }
    for (k, v) in data {
        if let Some(v) = v.as_str() {
            config::HARD_SETTINGS
                .write()
                .unwrap()
                .insert(k, v.to_owned());
        };
    }
}

#[inline]
pub fn is_empty_uni_link(arg: &str) -> bool {
    let prefix = crate::get_uri_prefix();
    if !arg.starts_with(&prefix) {
        return false;
    }
    arg[prefix.len()..].chars().all(|c| c == '/')
}

pub fn get_hwid() -> Bytes {
    use camellia_remote_protocol::sha2::{Digest, Sha256};

    let uuid = camellia_remote_protocol::get_uuid();
    let mut hasher = Sha256::new();
    hasher.update(&uuid);
    Bytes::from(hasher.finalize().to_vec())
}

#[inline]
pub fn get_builtin_option(key: &str) -> String {
    if key == keys::OPTION_HIDE_POWERED_BY_ME {
        return "Y".to_owned();
    }
    config::BUILTIN_SETTINGS
        .read()
        .unwrap()
        .get(key)
        .cloned()
        .unwrap_or_default()
}

/// Whether this build is an OEM-customised client.
///
/// Rebranding is not customisation: the fork carries its own name but ships the
/// complete product, so update checks, the server-setup card and the ordinary
/// option defaults all stay available. Only a real `custom.txt` deployment,
/// which populates the hard/built-in settings, should narrow the UI.
#[inline]
pub fn is_custom_client() -> bool {
    false
}

pub fn verify_login(_raw: &str, _id: &str) -> bool {
    true
    /*
    if is_custom_client() {
        return true;
    }
    #[cfg(debug_assertions)]
    return true;
    let Ok(pk) = crate::decode64("IycjQd4TmWvjjLnYd796Rd+XkK+KG+7GU1Ia7u4+vSw=") else {
        return false;
    };
    let Some(key) = get_pk(&pk).map(|x| sign::PublicKey(x)) else {
        return false;
    };
    let Ok(v) = crate::decode64(raw) else {
        return false;
    };
    let raw = sign::verify(&v, &key).unwrap_or_default();
    let v_str = std::str::from_utf8(&raw)
        .unwrap_or_default()
        .split(":")
        .next()
        .unwrap_or_default();
    v_str == id
    */
}

#[inline]
pub fn is_udp_disabled() -> bool {
    Config::get_option(keys::OPTION_DISABLE_UDP) == "Y"
}

// this crate https://github.com/yoshd/stun-client supports nat type
async fn stun_ipv6_test(stun_server: &str) -> ResultType<(SocketAddr, String)> {
    use std::net::ToSocketAddrs;
    use stunclient::StunClient;
    let local_addr = SocketAddr::from(([0u16; 8], 0)); // [::]:0
    let socket = UdpSocket::bind(&local_addr).await?;
    let Some(stun_addr) = stun_server
        .to_socket_addrs()?
        .filter(|x| x.is_ipv6())
        .next()
    else {
        bail!(
            "Failed to resolve STUN ipv6 server address: {}",
            stun_server
        );
    };
    let client = StunClient::new(stun_addr);
    let addr = client.query_external_address_async(&socket).await?;
    Ok(if addr.ip().is_ipv6() {
        (addr, stun_server.to_owned())
    } else {
        bail!("STUN server returned non-IPv6 address: {}", addr)
    })
}

async fn stun_ipv4_test(stun_server: &str) -> ResultType<(SocketAddr, String)> {
    use std::net::ToSocketAddrs;
    use stunclient::StunClient;
    let local_addr = SocketAddr::from(([0u8; 4], 0));
    let socket = UdpSocket::bind(&local_addr).await?;
    let Some(stun_addr) = stun_server
        .to_socket_addrs()?
        .filter(|x| x.is_ipv4())
        .next()
    else {
        bail!(
            "Failed to resolve STUN ipv4 server address: {}",
            stun_server
        );
    };
    let client = StunClient::new(stun_addr);
    let addr = client.query_external_address_async(&socket).await?;
    Ok(if addr.ip().is_ipv4() {
        (addr, stun_server.to_owned())
    } else {
        bail!("STUN server returned non-IPv6 address: {}", addr)
    })
}

static STUNS_V4: [&str; 3] = [
    "stun.l.google.com:19302",
    "stun.cloudflare.com:3478",
    "stun.nextcloud.com:3478",
];

static STUNS_V6: [&str; 3] = [
    "stun.l.google.com:19302",
    "stun.cloudflare.com:3478",
    "stun.nextcloud.com:3478",
];

pub async fn test_nat_ipv4() -> ResultType<(SocketAddr, String)> {
    use camellia_remote_protocol::futures::future::{select_ok, FutureExt};
    let tests = STUNS_V4
        .iter()
        .map(|&stun| stun_ipv4_test(stun).boxed())
        .collect::<Vec<_>>();

    match select_ok(tests).await {
        Ok(res) => {
            return Ok(res.0);
        }
        Err(e) => {
            bail!(
                "Failed to get public IPv4 address via public STUN servers: {}",
                e
            );
        }
    };
}

async fn test_bind_ipv6() -> ResultType<SocketAddr> {
    let local_addr = SocketAddr::from(([0u16; 8], 0)); // [::]:0
    let socket = UdpSocket::bind(local_addr).await?;
    let addr = STUNS_V6[0]
        .to_socket_addrs()?
        .filter(|x| x.is_ipv6())
        .next()
        .ok_or_else(|| {
            anyhow!(
                "Failed to resolve STUN ipv6 server address: {}",
                STUNS_V6[0]
            )
        })?;
    socket.connect(addr).await?;
    Ok(socket.local_addr()?)
}

pub async fn test_ipv6() -> Option<tokio::task::JoinHandle<()>> {
    if PUBLIC_IPV6_ADDR
        .lock()
        .unwrap()
        .1
        .map(|x| x.elapsed().as_secs() < 60)
        .unwrap_or(false)
    {
        return None;
    }
    PUBLIC_IPV6_ADDR.lock().unwrap().1 = Some(Instant::now());

    match test_bind_ipv6().await {
        Ok(mut addr) => {
            if let std::net::IpAddr::V6(ip) = addr.ip() {
                if !ip.is_loopback()
                    && !ip.is_unspecified()
                    && !ip.is_multicast()
                    && (ip.segments()[0] & 0xe000) == 0x2000
                {
                    addr.set_port(0);
                    PUBLIC_IPV6_ADDR.lock().unwrap().0 = Some(addr);
                    log::debug!("Found public IPv6 address locally: {}", addr);
                }
            }
        }
        Err(e) => {
            log::warn!("Failed to bind IPv6 socket: {}", e);
        }
    }
    // Interestingly, on my macOS, sometimes my ipv6 works, sometimes not (test with ping6 or https://test-ipv6.com/).
    // I checked ifconfig, could not see any difference. Both secure ipv6 and temporary ipv6 are there.
    // So we can not rely on the local ipv6 address queries with if_addrs.
    // above test_bind_ipv6 is safer, because it can fail in this case.
    /*
    std::thread::spawn(|| {
        if let Ok(ifaces) = if_addrs::get_if_addrs() {
            for iface in ifaces {
                if let if_addrs::IfAddr::V6(v6) = iface.addr {
                    let ip = v6.ip;
                    if !ip.is_loopback()
                        && !ip.is_unspecified()
                        && !ip.is_multicast()
                        && !ip.is_unique_local()
                        && !ip.is_unicast_link_local()
                        && (ip.segments()[0] & 0xe000) == 0x2000
                    {
                        // only use the first one, on mac, the first one is the stable
                        // one, the last one is the temporary one. The middle ones are deperecated.
                        *PUBLIC_IPV6_ADDR.lock().unwrap() =
                            Some((SocketAddr::from((ip, 0)), Instant::now()));
                        log::debug!("Found public IPv6 address locally: {}", ip);
                        break;
                    }
                }
            }
        }
    });
    */

    Some(tokio::spawn(async {
        use camellia_remote_protocol::futures::future::{select_ok, FutureExt};
        let tests = STUNS_V6
            .iter()
            .map(|&stun| stun_ipv6_test(stun).boxed())
            .collect::<Vec<_>>();

        match select_ok(tests).await {
            Ok(res) => {
                let mut addr = res.0 .0;
                addr.set_port(0); // Set port to 0 to avoid conflicts
                PUBLIC_IPV6_ADDR.lock().unwrap().0 = Some(addr);
                log::debug!(
                    "Found public IPv6 address via STUN server {}: {}",
                    res.0 .1,
                    addr
                );
            }
            Err(e) => {
                log::error!("Failed to get public IPv6 address: {}", e);
            }
        };
    }))
}

pub async fn punch_udp(
    socket: Arc<UdpSocket>,
    listen: bool,
) -> ResultType<Option<bytes::BytesMut>> {
    let mut retry_interval = Duration::from_millis(20);
    const MAX_INTERVAL: Duration = Duration::from_millis(200);
    const MAX_TIME: Duration = Duration::from_secs(20);
    let mut packets_sent = 0;
    socket.send(&[]).await.ok();
    packets_sent += 1;
    let mut last_send_time = Instant::now();
    let tm = Instant::now();
    let mut data = [0u8; 1500];

    loop {
        tokio::select! {
            _ = camellia_remote_protocol::sleep(retry_interval.as_secs_f32()) => {
                if tm.elapsed() > MAX_TIME {
                    bail!("UDP punch is timed out, stop sending packets after {:?} packets", packets_sent);
                }
                let elapsed = last_send_time.elapsed();

                if elapsed >= retry_interval {
                    socket.send(&[]).await.ok();
                    packets_sent += 1;

                    // Exponentially increase interval to reduce network pressure
                    retry_interval = std::cmp::min(
                        Duration::from_millis((retry_interval.as_millis() as f64 * 1.5) as u64),
                        MAX_INTERVAL
                    );
                    last_send_time = Instant::now();
                }
            }
            res = socket.recv(&mut data) => match res {
                Err(e) => bail!("UDP punch failed, {packets_sent} packets sent: {e}"),
                Ok(n) => {
                    // log::debug!("UDP punch succeeded after sending {} packets after {:?}", packets_sent, tm.elapsed());
                    if listen {
                        if n == 0 {
                            continue;
                        }
                        return Ok(Some(bytes::BytesMut::from(&data[..n])));
                    }
                    return Ok(None);
                }
            }
        }
    }
}

fn test_ipv6_sync() {
    #[tokio::main(flavor = "current_thread")]
    async fn func() {
        if let Some(job) = test_ipv6().await {
            job.await.ok();
        }
    }
    std::thread::spawn(func);
}

pub async fn get_ipv6_socket() -> Option<(Arc<UdpSocket>, bytes::Bytes)> {
    let Some(addr) = PUBLIC_IPV6_ADDR.lock().unwrap().0 else {
        return None;
    };

    match UdpSocket::bind(addr).await {
        Err(err) => {
            log::warn!("Failed to create UDP socket for IPv6: {err}");
        }
        Ok(socket) => {
            if let Ok(local_addr_v6) = socket.local_addr() {
                return Some((
                    Arc::new(socket),
                    camellia_remote_protocol::AddrMangle::encode(local_addr_v6).into(),
                ));
            }
        }
    }
    None
}

// The color is the same to `str2color()` in flutter.
pub fn str2color(s: &str, alpha: u8) -> u32 {
    let bytes = s.as_bytes();
    // dart code `160 << 16 + 114 << 8 + 91` results `0`.
    let mut hash: u32 = 0;
    for &byte in bytes {
        let code = byte as u32;
        hash = code.wrapping_add((hash << 5).wrapping_sub(hash));
    }

    hash = hash % 16777216;
    let rgb = hash & 0xFF7FFF;

    (alpha as u32) << 24 | rgb
}

/// Check control permission state from a u64 bitmap.
/// Each permission uses 2 bits: 0 = not set, 1 = disable, 2 = enable, 3 = invalid (treated as not set)
/// Returns: Some(true) = enabled, Some(false) = disabled, None = not set or invalid
pub fn get_control_permission(
    permissions: u64,
    permission: camellia_remote_protocol::rendezvous_proto::control_permissions::Permission,
) -> Option<bool> {
    use camellia_remote_protocol::protobuf::Enum;
    let index = permission.value();
    if index >= 0 && index < 32 {
        let shift = index * 2;
        let value = (permissions >> shift) & 0b11;
        match value {
            1 => Some(false), // disable
            2 => Some(true),  // enable
            _ => None,        // 0 = not set, 3 = invalid
        }
    } else {
        None
    }
}

pub fn is_direct_ip_access(peer: &str) -> bool {
    camellia_remote_protocol::is_ip_str(peer) || camellia_remote_protocol::is_domain_port_str(peer)
}

// Align the maximum length of the peer id to the maximum length of the peer id in the server.
const MAX_UNTRUSTED_PEER_ID_LEN: usize = 253;
const UNTRUSTED_PEER_ID_FORBIDDEN_CHARS: &[char] = &['"', '<', '>', '/', '\\', '|', '?', '*'];

// Shared validation for peer/connect ids that cross untrusted boundaries before
// they are stored or written into command/script contexts.
pub fn is_valid_untrusted_peer_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_UNTRUSTED_PEER_ID_LEN
        && !id.chars().any(|ch| {
            ch.is_control() || ch.is_whitespace() || UNTRUSTED_PEER_ID_FORBIDDEN_CHARS.contains(&ch)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use camellia_remote_protocol::tokio::{
        self,
        time::{interval, interval_at, sleep, Duration, Instant, Interval},
    };
    use std::collections::HashSet;

    #[inline]
    fn get_timestamp_secs() -> u128 {
        (std::time::SystemTime::UNIX_EPOCH
            .elapsed()
            .unwrap()
            .as_millis()
            + 500)
            / 1000
    }

    fn interval_maker() -> Interval {
        interval(Duration::from_secs(1))
    }

    fn interval_at_maker() -> Interval {
        interval_at(
            Instant::now() + Duration::from_secs(1),
            Duration::from_secs(1),
        )
    }

    #[test]
    fn untrusted_peer_id_validation() {
        let cases = [
            ("123456789", true),
            ("m\u{00FC}nchen-pc", true),
            ("192.168.1.10:21118", true),
            ("9123456234@public", true),
            (
                r#"1" & oWS.Run("cmd.exe /k whoami /priv",1,False) & ""#,
                false,
            ),
            ("", false),
            ("peer id", false),
            ("peer\nid", false),
            ("peer/id", false),
            ("peer?id", false),
        ];

        for (id, expected) in cases {
            assert_eq!(is_valid_untrusted_peer_id(id), expected, "{id:?}");
        }
    }

    // ThrottledInterval tick at the same time as tokio interval, if no sleeps
    #[allow(non_snake_case)]
    #[tokio::test]
    async fn test_RustDesk_interval() {
        let base_intervals = [interval_maker, interval_at_maker];
        for maker in base_intervals.into_iter() {
            let mut tokio_timer = maker();
            let mut tokio_times = Vec::new();
            let mut timer = rustdesk_interval(maker());
            let mut times = Vec::new();
            loop {
                tokio::select! {
                    _ = timer.tick() => {
                        if tokio_times.len() >= 10 && times.len() >= 10 {
                            break;
                        }
                        times.push(get_timestamp_secs());
                    }
                    _ = tokio_timer.tick() => {
                        if tokio_times.len() >= 10 && times.len() >= 10 {
                            break;
                        }
                        tokio_times.push(get_timestamp_secs());
                    }
                }
            }
            assert_eq!(times, tokio_times);
        }
    }

    #[tokio::test]
    async fn test_tokio_time_interval_sleep() {
        let mut timer = interval_maker();
        let mut times = Vec::new();
        sleep(Duration::from_secs(3)).await;
        loop {
            tokio::select! {
                _ = timer.tick() => {
                    times.push(get_timestamp_secs());
                    if times.len() == 5 {
                        break;
                    }
                }
            }
        }
        let times2: HashSet<u128> = HashSet::from_iter(times.clone());
        assert_eq!(times.len(), times2.len() + 3);
    }

    // ThrottledInterval tick less times than tokio interval, if there're sleeps
    #[allow(non_snake_case)]
    #[tokio::test]
    async fn test_RustDesk_interval_sleep() {
        let base_intervals = [interval_maker, interval_at_maker];
        for (i, maker) in base_intervals.into_iter().enumerate() {
            let mut timer = rustdesk_interval(maker());
            let mut times = Vec::new();
            sleep(Duration::from_secs(3)).await;
            loop {
                tokio::select! {
                    _ = timer.tick() => {
                        times.push(get_timestamp_secs());
                        if times.len() == 5 {
                            break;
                        }
                    }
                }
            }
            // No multiple ticks in the `interval` time.
            // Values in "times" are unique and are less than normal tokio interval.
            // See previous test (test_tokio_time_interval_sleep) for comparison.
            let times2: HashSet<u128> = HashSet::from_iter(times.clone());
            assert_eq!(times.len(), times2.len(), "test: {}", i);
        }
    }

    #[test]
    fn test_duration_multiplication() {
        let dur = Duration::from_secs(1);

        assert_eq!(dur * 2, Duration::from_secs(2));
        assert_eq!(
            Duration::from_secs_f64(dur.as_secs_f64() * 0.9),
            Duration::from_millis(900)
        );
        assert_eq!(
            Duration::from_secs_f64(dur.as_secs_f64() * 0.923),
            Duration::from_millis(923)
        );
        assert_eq!(
            Duration::from_secs_f64(dur.as_secs_f64() * 0.923 * 1e-3),
            Duration::from_micros(923)
        );
        assert_eq!(
            Duration::from_secs_f64(dur.as_secs_f64() * 0.923 * 1e-6),
            Duration::from_nanos(923)
        );
        assert_eq!(
            Duration::from_secs_f64(dur.as_secs_f64() * 0.923 * 1e-9),
            Duration::from_nanos(1)
        );
        assert_eq!(
            Duration::from_secs_f64(dur.as_secs_f64() * 0.5 * 1e-9),
            Duration::from_nanos(1)
        );
        assert_eq!(
            Duration::from_secs_f64(dur.as_secs_f64() * 0.499 * 1e-9),
            Duration::from_nanos(0)
        );
    }

    #[test]
    fn fresh_baseline_has_no_compiled_vendor_api() {
        assert!(!is_public("https://example.com"));
        assert!(!is_public("https://custom-server.com"));
        assert!(!is_public("http://192.168.1.1"));
        assert!(!is_public("localhost"));
    }

    #[test]
    fn test_should_use_tcp_proxy_for_api_url() {
        assert!(should_use_tcp_proxy_for_api_url(
            "https://admin.example.com/api/login",
            "https://admin.example.com"
        ));
        assert!(!should_use_tcp_proxy_for_api_url(
            "https://admin.example.com:21114/api/login",
            "https://admin.example.com"
        ));
        assert!(!should_use_tcp_proxy_for_api_url(
            "https://api.telegram.org/bot123/sendMessage",
            "https://admin.example.com"
        ));
        assert!(should_use_tcp_proxy_for_api_url(
            "https://api.example.com/api/login",
            "https://api.example.com"
        ));
        assert!(!should_use_tcp_proxy_for_api_url(
            "https://admin.example.com/api/login",
            "not a url"
        ));
        assert!(!should_use_tcp_proxy_for_api_url(
            "not a url",
            "https://admin.example.com"
        ));
    }

    #[tokio::test]
    async fn explicit_proxy_policy_never_falls_back_after_transport_errors_or_5xx() {
        let url = "https://management.example.test/api/heartbeat";
        for force in [false, true] {
            for status in [None, Some(503)] {
                let policy = RawTcpPolicy::capture(
                    url,
                    "https://management.example.test",
                    true,
                    false,
                    force,
                );
                assert!(!policy.first && !policy.fallback);
                let raw_started = std::sync::atomic::AtomicBool::new(false);
                let result = with_tcp_proxy_fallback(
                    url,
                    "POST",
                    policy,
                    async {
                        match status {
                            Some(code) => Ok((code, "upstream rejected".to_owned())),
                            None => Err(anyhow!("http_proxy_configuration_invalid")),
                        }
                    },
                    async {
                        raw_started.store(true, std::sync::atomic::Ordering::Release);
                        Ok("must not run".to_owned())
                    },
                )
                .await;
                assert!(!raw_started.load(std::sync::atomic::Ordering::Acquire));
                if status.is_none() {
                    assert!(result.is_err());
                } else {
                    assert_eq!(result.unwrap(), "upstream rejected");
                }
            }
        }
    }

    #[test]
    fn raw_policy_is_a_snapshot_of_explicit_proxy_and_full_api_origin() {
        let api = "https://management.example.test";
        let target = format!("{api}/api/login");
        let original = RawTcpPolicy::capture(&target, api, true, false, true);
        let updated = RawTcpPolicy::capture(&target, api, false, false, true);
        assert!(!original.first && !original.fallback);
        assert!(updated.first && updated.fallback);
        for target in [
            "http://management.example.test/api/login",
            "https://management.example.test:8443/api/login",
            "https://other.example.test/api/login",
            "https://user:private@management.example.test/api/login",
        ] {
            let policy = RawTcpPolicy::capture(target, api, false, false, true);
            assert!(!policy.first && !policy.fallback);
        }
        let policy = RawTcpPolicy::capture(&target, api, false, true, true);
        assert!(!policy.first && !policy.fallback);
    }

    #[test]
    fn test_get_tcp_proxy_addr_normalizes_bare_ipv6_host() {
        struct RestoreCustomRendezvousServer(String);

        impl Drop for RestoreCustomRendezvousServer {
            fn drop(&mut self) {
                Config::set_option(
                    keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_string(),
                    self.0.clone(),
                );
            }
        }

        let _restore = RestoreCustomRendezvousServer(Config::get_option(
            keys::OPTION_CUSTOM_RENDEZVOUS_SERVER,
        ));
        Config::set_option(
            keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_string(),
            "1:2".to_string(),
        );

        assert_eq!(get_tcp_proxy_addr(), format!("[1:2]:{RENDEZVOUS_PORT}"));
    }

    #[tokio::test]
    async fn raw_tcp_invalid_key_is_rejected_before_connecting() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let request = tcp_proxy_request(
            RawTcpContext {
                endpoint: listener.local_addr().unwrap().to_string(),
                key: "PRIVATE-INVALID-KEY".to_owned(),
            },
            "POST",
            "https://management.example.test/api/ab/peer/add",
            b"PRIVATE-BODY",
            vec![],
        );
        let result = tokio::time::timeout(Duration::from_secs(2), request)
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(result.to_string(), "raw_tcp_invalid_key");
        assert!(
            tokio::time::timeout(Duration::from_millis(50), listener.accept())
                .await
                .is_err(),
            "invalid credentials must not open a socket"
        );
    }

    #[tokio::test]
    async fn raw_tcp_captured_context_carries_mandatory_headers_on_an_authenticated_channel() {
        use camellia_remote_protocol::tcp::FramedStream;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = listener.local_addr().unwrap().to_string();
        let (public, secret) = sign::gen_keypair();
        let key = BASE64.encode(public.0);
        let expected_key = key.clone();
        let server = tokio::spawn(async move {
            let (socket, address) = listener.accept().await.unwrap();
            let mut connection = FramedStream::from(socket, address);
            let (box_public, box_secret) = box_::gen_keypair();
            let mut challenge = RendezvousMessage::new();
            challenge.set_key_exchange(KeyExchange {
                keys: vec![sign::sign(&box_public.0, &secret).into()],
                ..Default::default()
            });
            connection.send(&challenge).await.unwrap();
            let message =
                RendezvousMessage::parse_from_bytes(&connection.next().await.unwrap().unwrap())
                    .unwrap();
            let Some(rendezvous_message::Union::KeyExchange(exchange)) = message.union else {
                panic!("expected secure handshake, never a plaintext HTTP request");
            };
            assert_eq!(exchange.keys.len(), 2);
            let key = Encrypt::decode(&exchange.keys[1], &exchange.keys[0], &box_secret).unwrap();
            connection.set_key(key, CipherRole::Responder);
            let message =
                RendezvousMessage::parse_from_bytes(&connection.next().await.unwrap().unwrap())
                    .unwrap();
            let Some(rendezvous_message::Union::HttpProxyRequest(request)) = message.union else {
                panic!("expected encrypted HTTP request");
            };
            assert_eq!(request.method, "POST");
            assert_eq!(request.path, "/api/ab/peer/add?guid=book");
            assert_eq!(request.body.as_ref(), b"{\"peers\":[]}");
            assert_eq!(request.licence_key, expected_key);
            for (name, value) in [
                ("Authorization", "Bearer test-secret"),
                ("Idempotency-Key", "03440000-0000-4000-8000-000000000001"),
                ("If-Match", "\"7\""),
            ] {
                assert_eq!(
                    request
                        .headers
                        .iter()
                        .find(|h| h.name == name)
                        .unwrap()
                        .value,
                    value
                );
            }
            let mut response = RendezvousMessage::new();
            response.set_http_proxy_response(HttpProxyResponse {
                status: 200,
                body: Bytes::from_static(b"receipt"),
                ..Default::default()
            });
            connection.send(&response).await.unwrap();
        });
        let request = tcp_proxy_request(
            RawTcpContext { endpoint, key },
            "POST",
            "https://management.example.test/api/ab/peer/add?guid=book",
            b"{\"peers\":[]}",
            [
                ("Authorization", "Bearer test-secret"),
                ("Idempotency-Key", "03440000-0000-4000-8000-000000000001"),
                ("If-Match", "\"7\""),
            ]
            .into_iter()
            .map(|(name, value)| HeaderEntry {
                name: name.to_owned(),
                value: value.to_owned(),
                ..Default::default()
            })
            .collect(),
        );
        let response = tokio::time::timeout(Duration::from_secs(2), request)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.body.as_ref(), b"receipt");
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn raw_tcp_cancellation_during_handshake_closes_socket_without_http_payload() {
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let context = RawTcpContext {
            endpoint: listener.local_addr().unwrap().to_string(),
            key: BASE64.encode(sign::gen_keypair().0 .0),
        };
        let request = tokio::spawn(async move {
            tcp_proxy_request(
                context,
                "POST",
                "https://management.example.test/api/login",
                b"PRIVATE-MUTATION",
                vec![],
            )
            .await
        });
        let (mut socket, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept())
            .await
            .unwrap()
            .unwrap();
        request.abort();
        assert!(request.await.unwrap_err().is_cancelled());
        let mut buffer = [0; 64];
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), socket.read(&mut buffer))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn raw_tcp_rejects_session_sized_control_frame_before_receiving_payload() {
        use camellia_remote_protocol::bytes_codec::RENDEZVOUS_CONTROL_MAX_PACKET_LENGTH;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let context = RawTcpContext {
            endpoint: listener.local_addr().unwrap().to_string(),
            key: BASE64.encode(sign::gen_keypair().0 .0),
        };
        let request = tokio::spawn(async move {
            tcp_proxy_request(
                context,
                "POST",
                "https://management.example.test/api/login",
                b"PRIVATE-MUTATION",
                vec![],
            )
            .await
        });
        let (mut socket, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept())
            .await
            .unwrap()
            .unwrap();
        let header = (((RENDEZVOUS_CONTROL_MAX_PACKET_LENGTH + 1) as u32) << 2) | 3;
        socket.write_all(&header.to_le_bytes()).await.unwrap();
        assert!(tokio::time::timeout(Duration::from_secs(2), request)
            .await
            .unwrap()
            .unwrap()
            .is_err());
        let mut buffer = [0; 64];
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), socket.read(&mut buffer))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }

    #[test]
    fn test_parse_simple_header_respects_custom_content_type() {
        let headers = parse_simple_header("Content-Type: text/plain");

        assert_eq!(
            headers
                .iter()
                .filter(|entry| entry.name.eq_ignore_ascii_case("Content-Type"))
                .count(),
            1
        );
        assert_eq!(
            headers
                .iter()
                .find(|entry| entry.name.eq_ignore_ascii_case("Content-Type"))
                .map(|entry| entry.value.as_str()),
            Some("text/plain")
        );
    }

    #[test]
    fn test_parse_simple_header_preserves_non_content_type_header() {
        let headers = parse_simple_header("Authorization: Bearer token");

        assert!(headers.iter().any(|entry| {
            entry.name.eq_ignore_ascii_case("Authorization")
                && entry.value.as_str() == "Bearer token"
        }));
        assert_eq!(
            headers
                .iter()
                .filter(|entry| entry.name.eq_ignore_ascii_case("Content-Type"))
                .count(),
            1
        );
        assert_eq!(
            headers
                .iter()
                .find(|entry| entry.name.eq_ignore_ascii_case("Content-Type"))
                .map(|entry| entry.value.as_str()),
            Some("application/json")
        );
    }

    #[test]
    fn http_operation_headers_keep_logical_identity_and_rotate_attempt_span() {
        let event_id = "11111111-1111-4111-8111-111111111111";
        let operation = HttpOperation::from_event_id(event_id).unwrap();
        let first = operation.correlation_headers();
        let second = operation.correlation_headers();

        assert_eq!(
            first[1],
            (CAMELLIA_EVENT_ID_HEADER.to_owned(), event_id.to_owned())
        );
        assert_eq!(second[1], first[1]);
        let first_parts = first[0].1.split('-').collect::<Vec<_>>();
        let second_parts = second[0].1.split('-').collect::<Vec<_>>();
        assert_eq!(first[0].0, TRACEPARENT_HEADER);
        assert_eq!(first_parts.len(), 4);
        assert_eq!(first_parts[0], "00");
        assert_eq!(first_parts[1], "11111111111141118111111111111111");
        assert_eq!(first_parts[1], second_parts[1]);
        assert_eq!(first_parts[3], "01");
        assert_eq!(first_parts[2].len(), 16);
        assert!(first_parts[2].bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_ne!(first_parts[2], second_parts[2]);
    }

    #[test]
    fn direct_and_tcp_post_headers_share_contract_and_override_caller_correlation() {
        let operation =
            HttpOperation::from_event_id("22222222-2222-4222-8222-222222222222").unwrap();
        let direct = post_header_entries("Authorization: Bearer token", &operation);
        let tcp = post_header_entries("Authorization: Bearer token", &operation);

        for headers in [&direct, &tcp] {
            assert_eq!(
                headers
                    .iter()
                    .filter(|entry| entry.name.eq_ignore_ascii_case(TRACEPARENT_HEADER))
                    .count(),
                1
            );
            assert_eq!(
                headers
                    .iter()
                    .filter(|entry| entry.name.eq_ignore_ascii_case(CAMELLIA_EVENT_ID_HEADER))
                    .count(),
                1
            );
            assert!(headers.iter().any(|entry| {
                entry.name.eq_ignore_ascii_case("Authorization")
                    && entry.value.as_str() == "Bearer token"
            }));
            assert!(headers.iter().any(|entry| {
                entry.name.eq_ignore_ascii_case(CAMELLIA_EVENT_ID_HEADER)
                    && entry.value.as_str() == "22222222-2222-4222-8222-222222222222"
            }));
        }
        let direct_trace = direct
            .iter()
            .find(|entry| entry.name.eq_ignore_ascii_case(TRACEPARENT_HEADER))
            .unwrap()
            .value
            .as_str();
        let tcp_trace = tcp
            .iter()
            .find(|entry| entry.name.eq_ignore_ascii_case(TRACEPARENT_HEADER))
            .unwrap()
            .value
            .as_str();
        assert_eq!(&direct_trace[3..35], &tcp_trace[3..35]);
        assert_ne!(&direct_trace[36..52], &tcp_trace[36..52]);

        let overridden = post_header_entries(
            "traceparent: 00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-00",
            &operation,
        );
        assert_eq!(
            overridden
                .iter()
                .filter(|entry| entry.name.eq_ignore_ascii_case(TRACEPARENT_HEADER))
                .count(),
            1
        );
        assert!(overridden
            .iter()
            .find(|entry| entry.name.eq_ignore_ascii_case(TRACEPARENT_HEADER))
            .unwrap()
            .value
            .starts_with("00-22222222222242228222222222222222-"));
    }

    #[test]
    fn http_operation_rejects_noncanonical_event_ids() {
        for event_id in [
            "not-a-uuid",
            "00000000-0000-0000-0000-000000000000",
            "11111111-1111-4111-1111-111111111111",
            "11111111-1111-4111-8111-111111111111\r\nInjected: yes",
            "11111111-1111-4111-8111-111111111111,duplicate",
            "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        ] {
            assert!(
                HttpOperation::from_event_id(event_id).is_err(),
                "{event_id}"
            );
        }
    }

    #[test]
    fn test_tcp_proxy_log_target_redacts_query_only() {
        assert_eq!(
            tcp_proxy_log_target("https://example.com/api/heartbeat?token=secret"),
            "https://example.com/api/heartbeat"
        );
    }

    #[test]
    fn test_tcp_proxy_log_target_brackets_ipv6_host_with_port() {
        assert_eq!(
            tcp_proxy_log_target("https://[2001:db8::1]:21114/api/heartbeat?token=secret"),
            "https://[2001:db8::1]:21114/api/heartbeat"
        );
    }

    #[test]
    fn test_mouse_event_constants_and_mask_layout() {
        use super::input::*;

        // Verify MOUSE_TYPE constants are unique and within the mask range.
        let types = [
            MOUSE_TYPE_MOVE,
            MOUSE_TYPE_DOWN,
            MOUSE_TYPE_UP,
            MOUSE_TYPE_WHEEL,
            MOUSE_TYPE_TRACKPAD,
            MOUSE_TYPE_MOVE_RELATIVE,
        ];

        let mut seen = std::collections::HashSet::new();
        for t in types.iter() {
            assert!(seen.insert(*t), "Duplicate mouse type: {}", t);
            assert_eq!(
                *t & MOUSE_TYPE_MASK,
                *t,
                "Mouse type {} exceeds mask {}",
                t,
                MOUSE_TYPE_MASK
            );
        }

        // The mask layout is: lower 3 bits for type, upper bits for buttons (shifted by 3).
        let combined_mask = MOUSE_TYPE_DOWN | ((MOUSE_BUTTON_LEFT | MOUSE_BUTTON_RIGHT) << 3);
        assert_eq!(combined_mask & MOUSE_TYPE_MASK, MOUSE_TYPE_DOWN);
        assert_eq!(combined_mask >> 3, MOUSE_BUTTON_LEFT | MOUSE_BUTTON_RIGHT);
    }
}
