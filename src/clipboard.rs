#[cfg(not(target_os = "android"))]
use arboard::{ClipboardData, ClipboardFormat};
#[cfg(target_os = "linux")]
use arboard::{LinuxClipboardKind, SetExtLinux};
use camellia_remote_protocol::{bail, log, message_proto::*, ResultType};
use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};

pub const CLIPBOARD_NAME: &'static str = "clipboard";
#[cfg(feature = "unix-file-copy-paste")]
pub const FILE_CLIPBOARD_NAME: &'static str = "file-clipboard";
pub const CLIPBOARD_INTERVAL: u64 = 333;

// This format is used to store the flag in the clipboard.
const RUSTDESK_CLIPBOARD_OWNER_FORMAT: &'static str = "dyn.com.rustdesk.owner";

// Add special format for Excel XML Spreadsheet
const CLIPBOARD_FORMAT_EXCEL_XML_SPREADSHEET: &'static str = "XML Spreadsheet";

#[cfg(not(target_os = "android"))]
lazy_static::lazy_static! {
    static ref ARBOARD_MTX: Arc<Mutex<()>> = Arc::new(Mutex::new(()));
    // cache the clipboard msg
    static ref LAST_MULTI_CLIPBOARDS: Arc<Mutex<MultiClipboards>> = Arc::new(Mutex::new(MultiClipboards::new()));
    // For updating in server and getting content in cm.
    // Clipboard on Linux is "server--clients" mode.
    // The clipboard content is owned by the server and passed to the clients when requested.
    // Plain text is the only exception, it does not require the server to be present.
    static ref CLIPBOARD_CTX: Arc<Mutex<Option<ClipboardContext>>> = Arc::new(Mutex::new(None));
}

#[cfg(not(target_os = "android"))]
const CLIPBOARD_GET_MAX_RETRY: usize = 3;
#[cfg(not(target_os = "android"))]
const CLIPBOARD_GET_RETRY_INTERVAL_DUR: Duration = Duration::from_millis(33);

#[cfg(not(target_os = "android"))]
pub fn valid_rgba_dimensions(width: i32, height: i32, data_len: usize) -> Option<(usize, usize)> {
    let width = usize::try_from(width).ok()?;
    let height = usize::try_from(height).ok()?;
    if width == 0 || height == 0 || width > 16384 || height > 16384 {
        return None;
    }
    let expected_len = width.checked_mul(height)?.checked_mul(4)?;
    (data_len == expected_len).then_some((width, height))
}

#[cfg(not(target_os = "android"))]
const SUPPORTED_FORMATS: &[ClipboardFormat] = &[
    ClipboardFormat::Text,
    ClipboardFormat::Html,
    ClipboardFormat::Rtf,
    ClipboardFormat::ImageRgba,
    ClipboardFormat::ImagePng,
    ClipboardFormat::ImageSvg,
    #[cfg(feature = "unix-file-copy-paste")]
    ClipboardFormat::FileUrl,
    ClipboardFormat::Special(CLIPBOARD_FORMAT_EXCEL_XML_SPREADSHEET),
    ClipboardFormat::Special(RUSTDESK_CLIPBOARD_OWNER_FORMAT),
];

#[cfg(not(target_os = "android"))]
pub fn check_clipboard(
    ctx: &mut Option<ClipboardContext>,
    side: ClipboardSide,
    force: bool,
) -> Option<Message> {
    let (msg, clipboards) = read_clipboard_message(ctx, side, force)?;
    *LAST_MULTI_CLIPBOARDS.lock().unwrap() = clipboards;
    Some(msg)
}

#[cfg(target_os = "linux")]
pub fn peek_clipboard(
    ctx: &mut Option<ClipboardContext>,
    side: ClipboardSide,
    force: bool,
) -> Option<Message> {
    let (msg, _) = read_clipboard_message(ctx, side, force)?;
    Some(msg)
}

#[cfg(not(target_os = "android"))]
fn read_clipboard_message(
    ctx: &mut Option<ClipboardContext>,
    side: ClipboardSide,
    force: bool,
) -> Option<(Message, MultiClipboards)> {
    if ctx.is_none() {
        *ctx = ClipboardContext::new().ok();
    }
    let ctx2 = ctx.as_mut()?;
    match ctx2.get(side, force) {
        Ok(content) => {
            if !content.is_empty() {
                let mut msg = Message::new();
                let clipboards = proto::create_multi_clipboards(content);
                msg.set_multi_clipboards(clipboards.clone());
                return Some((msg, clipboards));
            }
        }
        Err(e) => {
            log::error!("Failed to get clipboard content. {}", e);
        }
    }
    None
}

#[cfg(all(feature = "unix-file-copy-paste", target_os = "macos"))]
pub fn is_file_url_set_by_rustdesk(url: &Vec<String>) -> bool {
    if url.len() != 1 {
        return false;
    }
    url.iter()
        .next()
        .map(|s| {
            for prefix in &["file:///tmp/.rustdesk_", "//tmp/.rustdesk_"] {
                if s.starts_with(prefix) {
                    return s[prefix.len()..].parse::<uuid::Uuid>().is_ok();
                }
            }
            false
        })
        .unwrap_or(false)
}

#[cfg(feature = "unix-file-copy-paste")]
pub fn check_clipboard_files(
    ctx: &mut Option<ClipboardContext>,
    side: ClipboardSide,
    force: bool,
) -> Option<Vec<String>> {
    if ctx.is_none() {
        *ctx = ClipboardContext::new().ok();
    }
    let ctx2 = ctx.as_mut()?;
    match ctx2.get_files(side, force) {
        Ok(Some(urls)) => {
            if !urls.is_empty() {
                return Some(urls);
            }
        }
        Err(e) => {
            log::error!("Failed to get clipboard file urls. {}", e);
        }
        _ => {}
    }
    None
}

#[cfg(not(target_os = "android"))]
enum ClipboardWorkerJob {
    Update {
        generation: u64,
        data: Vec<ClipboardData>,
        side: ClipboardSide,
    },
    #[cfg(all(target_os = "linux", feature = "unix-file-copy-paste"))]
    UpdateFiles {
        files: Vec<String>,
        side: ClipboardSide,
    },
    #[cfg(feature = "unix-file-copy-paste")]
    EmptyFiles { side: ClipboardSide, conn_id: i32 },
}

#[cfg(not(target_os = "android"))]
struct ClipboardWorker {
    tx: std::sync::mpsc::SyncSender<ClipboardWorkerJob>,
    current_gen: Arc<AtomicU64>,
}

#[cfg(not(target_os = "android"))]
static CLIPBOARD_WORKER: OnceLock<ClipboardWorker> = OnceLock::new();

#[cfg(not(target_os = "android"))]
fn get_clipboard_worker() -> &'static ClipboardWorker {
    CLIPBOARD_WORKER.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::sync_channel(32);
        let current_gen = Arc::new(AtomicU64::new(0));
        let worker_gen = Arc::clone(&current_gen);
        std::thread::Builder::new()
            .name("clipboard_worker".to_string())
            .spawn(move || {
                while let Ok(job) = rx.recv() {
                    match job {
                        ClipboardWorkerJob::Update {
                            generation,
                            data,
                            side,
                        } => {
                            let latest = worker_gen.load(Ordering::Acquire);
                            if generation < latest {
                                log::debug!(
                                    "Dropping stale clipboard update: gen {generation} < latest {latest}"
                                );
                                continue;
                            }
                            do_update_clipboard_(data, side);
                        }
                        #[cfg(all(target_os = "linux", feature = "unix-file-copy-paste"))]
                        ClipboardWorkerJob::UpdateFiles { files, side } => {
                            do_update_clipboard_(vec![ClipboardData::FileUrl(files)], side);
                        }
                        #[cfg(feature = "unix-file-copy-paste")]
                        ClipboardWorkerJob::EmptyFiles { side, conn_id } => {
                            if let Err(e) = try_empty_clipboard_files_sync(side, conn_id) {
                                log::error!("Failed to empty clipboard files: {}", e);
                            }
                        }
                    }
                }
            })
            .expect("Failed to spawn clipboard worker thread");
        ClipboardWorker { tx, current_gen }
    })
}

#[cfg(all(target_os = "linux", feature = "unix-file-copy-paste"))]
pub fn update_clipboard_files(files: Vec<String>, side: ClipboardSide) {
    if !files.is_empty() {
        let worker = get_clipboard_worker();
        let _ = worker
            .tx
            .try_send(ClipboardWorkerJob::UpdateFiles { files, side });
    }
}

#[cfg(feature = "unix-file-copy-paste")]
pub fn try_empty_clipboard_files(side: ClipboardSide, conn_id: i32) {
    let worker = get_clipboard_worker();
    let _ = worker
        .tx
        .try_send(ClipboardWorkerJob::EmptyFiles { side, conn_id });
}

#[cfg(feature = "unix-file-copy-paste")]
pub fn try_empty_clipboard_files_sync(_side: ClipboardSide, _conn_id: i32) -> ResultType<()> {
    let mut ctx = CLIPBOARD_CTX.lock().unwrap();
    if ctx.is_none() {
        match ClipboardContext::new() {
            Ok(x) => {
                *ctx = Some(x);
            }
            Err(e) => {
                log::error!("Failed to create clipboard context: {}", e);
                bail!("Failed to create clipboard context: {}", e);
            }
        }
    }
    #[allow(unused_mut)]
    if let Some(mut ctx) = ctx.as_mut() {
        #[cfg(target_os = "linux")]
        {
            use clipboard::platform::unix;
            if unix::fuse::empty_local_files(_side == ClipboardSide::Client, _conn_id) {
                ctx.try_empty_clipboard_files(_side);
            }
        }
        #[cfg(target_os = "macos")]
        {
            ctx.try_empty_clipboard_files(_side);
            // No need to make sure the context is enabled.
            clipboard::ContextSend::proc(|context| -> ResultType<()> {
                if !context.empty_clipboard(_conn_id)? {
                    bail!("Failed to empty clipboard files for conn_id {}", _conn_id);
                }
                Ok(())
            })?;
        }
    }
    Ok(())
}

#[cfg(target_os = "windows")]
pub fn try_empty_clipboard_files(side: ClipboardSide, conn_id: i32) {
    log::debug!("try to empty {} cliprdr for conn_id {}", side, conn_id);
    let _ = clipboard::ContextSend::proc(|context| -> ResultType<()> {
        context.empty_clipboard(conn_id)?;
        Ok(())
    });
}

#[cfg(target_os = "windows")]
pub fn check_clipboard_cm() -> ResultType<MultiClipboards> {
    let mut ctx = CLIPBOARD_CTX.lock().unwrap();
    if ctx.is_none() {
        match ClipboardContext::new() {
            Ok(x) => {
                *ctx = Some(x);
            }
            Err(e) => {
                camellia_remote_protocol::bail!("Failed to create clipboard context: {}", e);
            }
        }
    }
    if let Some(ctx) = ctx.as_mut() {
        let content = ctx.get(ClipboardSide::Host, false)?;
        let clipboards = proto::create_multi_clipboards(content);
        Ok(clipboards)
    } else {
        camellia_remote_protocol::bail!("Failed to create clipboard context");
    }
}

#[cfg(not(target_os = "android"))]
fn do_update_clipboard_(mut to_update_data: Vec<ClipboardData>, side: ClipboardSide) {
    let mut ctx = CLIPBOARD_CTX.lock().unwrap();
    if ctx.is_none() {
        match ClipboardContext::new() {
            Ok(x) => {
                *ctx = Some(x);
            }
            Err(e) => {
                log::error!("Failed to create clipboard context: {}", e);
                return;
            }
        }
    }
    if let Some(ctx) = ctx.as_mut() {
        to_update_data = append_owner_marker(to_update_data, side);
        if let Err(e) = ctx.set(&to_update_data) {
            log::debug!("Failed to set clipboard: {}", e);
        } else {
            log::debug!("{} updated on {}", CLIPBOARD_NAME, side);
        }
    }
}

#[cfg(not(target_os = "android"))]
fn append_owner_marker(mut data: Vec<ClipboardData>, side: ClipboardSide) -> Vec<ClipboardData> {
    data.push(ClipboardData::Special((
        RUSTDESK_CLIPBOARD_OWNER_FORMAT.to_owned(),
        side.get_owner_data(),
    )));
    data
}

#[cfg(target_os = "linux")]
pub fn set_text_clipboard_with_owner_sync(text: &str, side: ClipboardSide) -> ResultType<()> {
    let mut ctx = CLIPBOARD_CTX.lock().unwrap();
    if ctx.is_none() {
        *ctx = Some(ClipboardContext::new()?);
    }
    let clipboard_ctx = match ctx.as_mut() {
        Some(ctx) => ctx,
        None => bail!("Failed to create clipboard context"),
    };
    let data = append_owner_marker(vec![ClipboardData::Text(text.to_owned())], side);
    clipboard_ctx.set_with_owner_marker_for_linux(&data)
}

#[cfg(not(target_os = "android"))]
pub fn update_clipboard(mut multi_clipboards: Vec<Clipboard>, side: ClipboardSide) {
    if multi_clipboards.len() > proto::MAX_CLIPBOARD_ITEMS {
        log::warn!(
            "MultiClipboards has {} items, truncating to max {}",
            multi_clipboards.len(),
            proto::MAX_CLIPBOARD_ITEMS
        );
        multi_clipboards.truncate(proto::MAX_CLIPBOARD_ITEMS);
    }
    let to_update_data = proto::from_multi_clipboards(multi_clipboards);
    if to_update_data.is_empty() {
        return;
    }
    let worker = get_clipboard_worker();
    let gen = worker.current_gen.fetch_add(1, Ordering::SeqCst) + 1;
    let _ = worker.tx.try_send(ClipboardWorkerJob::Update {
        generation: gen,
        data: to_update_data,
        side,
    });
}

#[cfg(not(target_os = "android"))]
pub struct ClipboardContext {
    inner: arboard::Clipboard,
}

#[cfg(not(target_os = "android"))]
#[allow(unreachable_code)]
impl ClipboardContext {
    pub fn new() -> ResultType<ClipboardContext> {
        let board;
        #[cfg(not(target_os = "linux"))]
        {
            board = arboard::Clipboard::new()?;
        }
        #[cfg(target_os = "linux")]
        {
            let mut i = 1;
            loop {
                // Try 5 times to create clipboard
                // Arboard::new() connect to X server or Wayland compositor, which should be OK most times
                // But sometimes, the connection may fail, so we retry here.
                match arboard::Clipboard::new() {
                    Ok(x) => {
                        board = x;
                        break;
                    }
                    Err(e) => {
                        if i == 5 {
                            return Err(e.into());
                        } else {
                            std::thread::sleep(std::time::Duration::from_millis(30 * i));
                        }
                    }
                }
                i += 1;
            }
        }

        Ok(ClipboardContext { inner: board })
    }

    fn get_formats(&mut self, formats: &[ClipboardFormat]) -> ResultType<Vec<ClipboardData>> {
        // If there're multiple threads or processes trying to access the clipboard at the same time,
        // the previous clipboard owner will fail to access the clipboard.
        // `GetLastError()` will return `ERROR_CLIPBOARD_NOT_OPEN` (OSError(1418): Thread does not have a clipboard open) at this time.
        // See https://github.com/rustdesk-org/arboard/blob/747ab2d9b40a5c9c5102051cf3b0bb38b4845e60/src/platform/windows.rs#L34
        //
        // This is a common case on Windows, so we retry here.
        // Related issues:
        // https://github.com/rustdesk/rustdesk/issues/9263
        // https://github.com/rustdesk/rustdesk/issues/9222#issuecomment-2329233175
        for i in 0..CLIPBOARD_GET_MAX_RETRY {
            match self.inner.get_formats(formats) {
                Ok(data) => {
                    return Ok(data
                        .into_iter()
                        .filter(|c| !matches!(c, arboard::ClipboardData::None))
                        .collect())
                }
                Err(e) => match e {
                    arboard::Error::ClipboardOccupied => {
                        log::debug!("Failed to get clipboard formats, clipboard is occupied, retrying... {}", i + 1);
                        std::thread::sleep(CLIPBOARD_GET_RETRY_INTERVAL_DUR);
                    }
                    _ => {
                        log::error!("Failed to get clipboard formats, {}", e);
                        return Err(e.into());
                    }
                },
            }
        }
        bail!("Failed to get clipboard formats, clipboard is occupied, {CLIPBOARD_GET_MAX_RETRY} retries failed");
    }

    pub fn get(&mut self, side: ClipboardSide, force: bool) -> ResultType<Vec<ClipboardData>> {
        let data = self.get_formats_filter(SUPPORTED_FORMATS, side, force)?;
        // We have a separate service named `file-clipboard` to handle file copy-paste.
        // We need to read the file urls because file copy may set the other clipboard formats such as text.
        #[cfg(feature = "unix-file-copy-paste")]
        {
            if data.iter().any(|c| matches!(c, ClipboardData::FileUrl(_))) {
                return Ok(vec![]);
            }
        }
        Ok(data)
    }

    fn get_formats_filter(
        &mut self,
        formats: &[ClipboardFormat],
        side: ClipboardSide,
        force: bool,
    ) -> ResultType<Vec<ClipboardData>> {
        let _lock = ARBOARD_MTX.lock().unwrap();
        let data = self.get_formats(formats)?;
        if data.is_empty() {
            return Ok(data);
        }
        if !force {
            for c in data.iter() {
                if let ClipboardData::Special((s, d)) = c {
                    if s == RUSTDESK_CLIPBOARD_OWNER_FORMAT && side.is_owner(d) {
                        return Ok(vec![]);
                    }
                }
            }
        }
        Ok(data
            .into_iter()
            .filter(|c| match c {
                ClipboardData::Special((s, _)) => s != RUSTDESK_CLIPBOARD_OWNER_FORMAT,
                // Skip synchronizing empty text to the remote clipboard
                ClipboardData::Text(text) => !text.is_empty(),
                _ => true,
            })
            .collect())
    }

    #[cfg(feature = "unix-file-copy-paste")]
    pub fn get_files(
        &mut self,
        side: ClipboardSide,
        force: bool,
    ) -> ResultType<Option<Vec<String>>> {
        let data = self.get_formats_filter(
            &[
                ClipboardFormat::FileUrl,
                ClipboardFormat::Special(RUSTDESK_CLIPBOARD_OWNER_FORMAT),
            ],
            side,
            force,
        )?;
        Ok(data.into_iter().find_map(|c| match c {
            ClipboardData::FileUrl(urls) => Some(urls),
            _ => None,
        }))
    }

    fn set(&mut self, data: &[ClipboardData]) -> ResultType<()> {
        let _lock = ARBOARD_MTX.lock().unwrap();
        self.inner.set_formats(data)?;
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn set_with_owner_marker_for_linux(&mut self, data: &[ClipboardData]) -> ResultType<()> {
        let _lock = ARBOARD_MTX.lock().unwrap();
        self.inner
            .set()
            .clipboard(LinuxClipboardKind::Clipboard)
            .formats(data)?;
        if let Err(e) = self
            .inner
            .set()
            .clipboard(LinuxClipboardKind::Primary)
            .formats(data)
        {
            log::warn!("Failed to set PRIMARY clipboard with owner marker: {}", e);
        }
        Ok(())
    }

    #[cfg(all(feature = "unix-file-copy-paste", target_os = "macos"))]
    fn get_file_urls_set_by_rustdesk(
        data: Vec<ClipboardData>,
        _side: ClipboardSide,
    ) -> Vec<String> {
        for item in data.into_iter() {
            if let ClipboardData::FileUrl(urls) = item {
                if is_file_url_set_by_rustdesk(&urls) {
                    return urls;
                }
            }
        }
        vec![]
    }

    #[cfg(all(feature = "unix-file-copy-paste", target_os = "linux"))]
    fn get_file_urls_set_by_rustdesk(data: Vec<ClipboardData>, side: ClipboardSide) -> Vec<String> {
        let exclude_path =
            clipboard::platform::unix::fuse::get_exclude_paths(side == ClipboardSide::Client);
        data.into_iter()
            .filter_map(|c| match c {
                ClipboardData::FileUrl(urls) => Some(
                    urls.into_iter()
                        .filter(|s| s.starts_with(&*exclude_path))
                        .collect::<Vec<_>>(),
                ),
                _ => None,
            })
            .flatten()
            .collect::<Vec<_>>()
    }

    #[cfg(feature = "unix-file-copy-paste")]
    fn try_empty_clipboard_files(&mut self, side: ClipboardSide) {
        let _lock = ARBOARD_MTX.lock().unwrap();
        if let Ok(data) = self.get_formats(&[ClipboardFormat::FileUrl]) {
            let urls = Self::get_file_urls_set_by_rustdesk(data, side);
            if !urls.is_empty() {
                // FIXME:
                // The host-side clear file clipboard `let _ = self.inner.clear();`,
                // does not work on KDE Plasma for the installed version.

                // Don't use `camellia_remote_protocol::platform::linux::is_kde()` here.
                // It's not correct in the server process.
                #[cfg(target_os = "linux")]
                let is_kde_x11 = camellia_remote_protocol::platform::linux::is_kde_session()
                    && crate::platform::linux::is_x11();
                #[cfg(target_os = "macos")]
                let is_kde_x11 = false;
                let clear_holder_text = if is_kde_x11 {
                    "Camellia placeholder to clear the file clipboard"
                } else {
                    ""
                }
                .to_string();
                self.inner
                    .set_formats(&[
                        ClipboardData::Text(clear_holder_text),
                        ClipboardData::Special((
                            RUSTDESK_CLIPBOARD_OWNER_FORMAT.to_owned(),
                            side.get_owner_data(),
                        )),
                    ])
                    .ok();
            }
        }
    }
}

pub fn is_support_multi_clipboard(peer_version: &str, peer_platform: &str) -> bool {
    use camellia_remote_protocol::get_version_number;
    if get_version_number(peer_version) < get_version_number("1.3.0") {
        return false;
    }
    if [
        "",
        &camellia_remote_protocol::whoami::Platform::Ios.to_string(),
    ]
    .contains(&peer_platform)
    {
        return false;
    }
    if "Android" == peer_platform && get_version_number(peer_version) < get_version_number("1.3.3")
    {
        return false;
    }
    true
}

#[cfg(not(target_os = "android"))]
pub fn get_current_clipboard_msg(
    peer_version: &str,
    peer_platform: &str,
    side: ClipboardSide,
) -> Option<Message> {
    let mut multi_clipboards = LAST_MULTI_CLIPBOARDS.lock().unwrap();
    if multi_clipboards.clipboards.is_empty() {
        let mut ctx = ClipboardContext::new().ok()?;
        *multi_clipboards = proto::create_multi_clipboards(ctx.get(side, true).ok()?);
    }
    if multi_clipboards.clipboards.is_empty() {
        return None;
    }

    if is_support_multi_clipboard(peer_version, peer_platform) {
        let mut msg = Message::new();
        msg.set_multi_clipboards(multi_clipboards.clone());
        Some(msg)
    } else {
        // Find the first text clipboard and send it.
        multi_clipboards
            .clipboards
            .iter()
            .find(|c| {
                c.format.enum_value()
                    == Ok(camellia_remote_protocol::message_proto::ClipboardFormat::Text)
            })
            .map(|c| {
                let mut msg = Message::new();
                msg.set_clipboard(c.clone());
                msg
            })
    }
}

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum ClipboardSide {
    Host,
    Client,
}

impl ClipboardSide {
    // 01: the clipboard is owned by the host
    // 10: the clipboard is owned by the client
    fn get_owner_data(&self) -> Vec<u8> {
        match self {
            ClipboardSide::Host => vec![0b01],
            ClipboardSide::Client => vec![0b10],
        }
    }

    fn is_owner(&self, data: &[u8]) -> bool {
        if data.len() == 0 {
            return false;
        }
        data[0] & 0b11 != 0
    }
}

impl std::fmt::Display for ClipboardSide {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClipboardSide::Host => write!(f, "host"),
            ClipboardSide::Client => write!(f, "client"),
        }
    }
}

pub use proto::get_msg_if_not_support_multi_clip;
pub mod proto {
    #[cfg(not(target_os = "android"))]
    use arboard::ClipboardData;
    use camellia_remote_protocol::{
        compress::{compress as compress_func, decompress},
        log,
        message_proto::{Clipboard, ClipboardFormat, Message, MultiClipboards},
    };

    pub const MAX_CLIPBOARD_ITEMS: usize = 16;
    pub const MAX_CLIPBOARD_COMPRESSED_BYTES: usize = 16 * 1024 * 1024; // 16 MiB
    pub const MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES: usize = 32 * 1024 * 1024; // 32 MiB
    pub const MAX_CLIPBOARD_TOTAL_DECOMPRESSED_BYTES: usize = 64 * 1024 * 1024; // 64 MiB
    pub const MAX_SPECIAL_NAME_LEN: usize = 256;
    pub const MAX_SPECIAL_PAYLOAD_BYTES: usize = 16 * 1024 * 1024; // 16 MiB

    fn compress_or_raw(raw: Vec<u8>) -> (bool, Vec<u8>) {
        match compress_func(&raw) {
            Ok(compressed) if compressed.len() < raw.len() => (true, compressed),
            Ok(_) => (false, raw),
            Err(err) => {
                log::warn!("Failed to compress clipboard payload, sending raw data: {err}");
                (false, raw)
            }
        }
    }

    fn plain_to_proto(s: String, format: ClipboardFormat) -> Clipboard {
        let (compress, content) = compress_or_raw(s.into_bytes());
        Clipboard {
            compress,
            content: content.into(),
            format: format.into(),
            ..Default::default()
        }
    }

    #[cfg(not(target_os = "android"))]
    fn image_to_proto(a: arboard::ImageData) -> Clipboard {
        match &a {
            arboard::ImageData::Rgba(rgba) => {
                let (compress, content) = compress_or_raw(a.bytes().to_vec());
                Clipboard {
                    compress,
                    content: content.into(),
                    width: rgba.width as _,
                    height: rgba.height as _,
                    format: ClipboardFormat::ImageRgba.into(),
                    ..Default::default()
                }
            }
            arboard::ImageData::Png(png) => Clipboard {
                compress: false,
                content: png.to_owned().to_vec().into(),
                format: ClipboardFormat::ImagePng.into(),
                ..Default::default()
            },
            arboard::ImageData::Svg(_) => {
                let (compress, content) = compress_or_raw(a.bytes().to_vec());
                Clipboard {
                    compress,
                    content: content.into(),
                    format: ClipboardFormat::ImageSvg.into(),
                    ..Default::default()
                }
            }
        }
    }

    pub fn special_to_proto(d: Vec<u8>, s: String) -> Option<Clipboard> {
        if s.len() > MAX_SPECIAL_NAME_LEN || d.len() > MAX_SPECIAL_PAYLOAD_BYTES {
            log::warn!(
                "Special clipboard format '{}' or payload ({} bytes) exceeds bounds",
                s,
                d.len()
            );
            return None;
        }
        let compressed = match compress_func(&d) {
            Ok(compressed) => compressed,
            Err(err) => {
                log::warn!("Dropping special clipboard payload after compression failure: {err}");
                return None;
            }
        };
        let compress = compressed.len() < d.len();
        let content = if compress { compressed } else { d };
        Some(Clipboard {
            compress,
            content: content.into(),
            format: ClipboardFormat::Special.into(),
            special_name: s,
            ..Default::default()
        })
    }

    #[cfg(not(target_os = "android"))]
    fn clipboard_data_to_proto(data: ClipboardData) -> Option<Clipboard> {
        let d = match data {
            ClipboardData::Text(s) => plain_to_proto(s, ClipboardFormat::Text),
            ClipboardData::Rtf(s) => plain_to_proto(s, ClipboardFormat::Rtf),
            ClipboardData::Html(s) => plain_to_proto(s, ClipboardFormat::Html),
            ClipboardData::Image(a) => image_to_proto(a),
            ClipboardData::Special((s, d)) => return special_to_proto(d, s),
            _ => return None,
        };
        Some(d)
    }

    #[cfg(not(target_os = "android"))]
    pub fn create_multi_clipboards(vec_data: Vec<ClipboardData>) -> MultiClipboards {
        MultiClipboards {
            clipboards: vec_data
                .into_iter()
                .filter_map(clipboard_data_to_proto)
                .collect(),
            ..Default::default()
        }
    }

    #[cfg(not(target_os = "android"))]
    pub fn from_clipboard(clipboard: Clipboard) -> Option<ClipboardData> {
        let data = if clipboard.compress {
            if clipboard.content.len() > MAX_CLIPBOARD_COMPRESSED_BYTES {
                log::warn!(
                    "Dropping clipboard payload: compressed length {} exceeds budget",
                    clipboard.content.len()
                );
                return None;
            }
            match decompress(&clipboard.content) {
                Ok(data) => {
                    if data.len() > MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES {
                        log::warn!(
                            "Dropping clipboard payload: decompressed length {} exceeds budget",
                            data.len()
                        );
                        return None;
                    }
                    data
                }
                Err(err) => {
                    log::warn!("Dropping malformed compressed clipboard payload: {err}");
                    return None;
                }
            }
        } else {
            if clipboard.content.len() > MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES {
                log::warn!(
                    "Dropping clipboard payload: uncompressed length {} exceeds budget",
                    clipboard.content.len()
                );
                return None;
            }
            clipboard.content.to_vec()
        };
        match clipboard.format.enum_value() {
            Ok(ClipboardFormat::Text) => String::from_utf8(data).ok().map(ClipboardData::Text),
            Ok(ClipboardFormat::Rtf) => String::from_utf8(data).ok().map(ClipboardData::Rtf),
            Ok(ClipboardFormat::Html) => String::from_utf8(data).ok().map(ClipboardData::Html),
            Ok(ClipboardFormat::ImageRgba) => {
                let (width, height) =
                    super::valid_rgba_dimensions(clipboard.width, clipboard.height, data.len())?;
                Some(ClipboardData::Image(arboard::ImageData::rgba(
                    width,
                    height,
                    data.into(),
                )))
            }
            Ok(ClipboardFormat::ImagePng) => {
                Some(ClipboardData::Image(arboard::ImageData::png(data.into())))
            }
            Ok(ClipboardFormat::ImageSvg) => Some(ClipboardData::Image(arboard::ImageData::svg(
                std::str::from_utf8(&data).unwrap_or_default(),
            ))),
            Ok(ClipboardFormat::Special) => {
                if clipboard.special_name.len() > MAX_SPECIAL_NAME_LEN
                    || data.len() > MAX_SPECIAL_PAYLOAD_BYTES
                {
                    log::warn!(
                        "Dropping special clipboard payload: name len {} or data len {} exceeds bounds",
                        clipboard.special_name.len(),
                        data.len()
                    );
                    return None;
                }
                Some(ClipboardData::Special((clipboard.special_name, data)))
            }
            _ => None,
        }
    }

    #[cfg(not(target_os = "android"))]
    pub fn from_multi_clipboards(multi_clipboards: Vec<Clipboard>) -> Vec<ClipboardData> {
        let mut total_bytes = 0usize;
        let mut result = Vec::new();
        for item in multi_clipboards.into_iter().take(MAX_CLIPBOARD_ITEMS) {
            if let Some(cd) = from_clipboard(item) {
                let item_bytes = match &cd {
                    ClipboardData::Text(t) => t.len(),
                    ClipboardData::Rtf(r) => r.len(),
                    ClipboardData::Html(h) => h.len(),
                    ClipboardData::Image(img) => img.bytes().len(),
                    ClipboardData::Special((_, d)) => d.len(),
                    _ => 0,
                };
                total_bytes = total_bytes.saturating_add(item_bytes);
                if total_bytes > MAX_CLIPBOARD_TOTAL_DECOMPRESSED_BYTES {
                    log::warn!(
                        "Cumulative clipboard items exceed batch budget ({} bytes), truncating remaining items",
                        total_bytes
                    );
                    break;
                }
                result.push(cd);
            }
        }
        result
    }

    pub fn get_msg_if_not_support_multi_clip(
        version: &str,
        platform: &str,
        multi_clipboards: &MultiClipboards,
    ) -> Option<Message> {
        if crate::clipboard::is_support_multi_clipboard(version, platform) {
            return None;
        }

        // Find the first text clipboard and send it.
        multi_clipboards
            .clipboards
            .iter()
            .find(|c| c.format.enum_value() == Ok(ClipboardFormat::Text))
            .map(|c| {
                let mut msg = Message::new();
                msg.set_clipboard(c.clone());
                msg
            })
    }

    #[cfg(all(test, not(target_os = "android")))]
    mod tests {
        use super::*;

        #[test]
        fn malformed_compressed_clipboard_is_dropped_instead_of_restored_as_empty() {
            let clipboard = Clipboard {
                compress: true,
                content: b"not a zstd frame".as_slice().into(),
                format: ClipboardFormat::Text.into(),
                ..Default::default()
            };

            assert!(from_clipboard(clipboard).is_none());
        }

        #[test]
        fn special_to_proto_uncompressed_preserves_original_content_data001() {
            let special_name = "application/x-custom-format".to_string();
            // 4 bytes: compressed form is larger than raw, so compress is false
            let raw_data = vec![1, 2, 3, 4];
            let proto = special_to_proto(raw_data.clone(), special_name.clone())
                .expect("special_to_proto should succeed");
            assert!(!proto.compress, "small payload should not be compressed");
            assert_eq!(proto.special_name, special_name);
            assert_eq!(
                &proto.content[..],
                raw_data.as_slice(),
                "uncompressed special content must be the raw data, not the format name"
            );

            let restored = from_clipboard(proto).expect("from_clipboard should restore payload");
            match restored {
                ClipboardData::Special((name, data)) => {
                    assert_eq!(name, special_name);
                    assert_eq!(data, raw_data);
                }
                other => panic!("expected Special, got {:?}", other),
            }
        }

        #[test]
        fn special_to_proto_compressed_preserves_original_content_data001() {
            let special_name = "application/x-custom-format".to_string();
            // Large compressible payload
            let raw_data = vec![42u8; 10000];
            let proto = special_to_proto(raw_data.clone(), special_name.clone())
                .expect("special_to_proto should succeed");
            assert!(proto.compress, "repetitive payload should be compressed");
            assert_eq!(proto.special_name, special_name);

            let restored = from_clipboard(proto).expect("from_clipboard should restore payload");
            match restored {
                ClipboardData::Special((name, data)) => {
                    assert_eq!(name, special_name);
                    assert_eq!(data, raw_data);
                }
                other => panic!("expected Special, got {:?}", other),
            }
        }

        #[test]
        fn special_to_proto_oversized_name_or_data_is_rejected() {
            let long_name = "x".repeat(MAX_SPECIAL_NAME_LEN + 1);
            assert!(special_to_proto(vec![1, 2, 3], long_name).is_none());
        }
    }
}

#[cfg(all(test, not(target_os = "android")))]
mod rgba_tests {
    use super::valid_rgba_dimensions;

    #[test]
    fn validates_dimensions_against_content_length() {
        assert_eq!(valid_rgba_dimensions(1, 1, 4), Some((1, 1)));
        assert_eq!(valid_rgba_dimensions(1, 1, 3), None);
        assert_eq!(valid_rgba_dimensions(-1, 1, 4), None);
        assert_eq!(valid_rgba_dimensions(0, 1, 0), None);
        assert_eq!(valid_rgba_dimensions(i32::MAX, i32::MAX, 4), None);
        #[cfg(target_pointer_width = "32")]
        assert_eq!(valid_rgba_dimensions(i32::MAX, 2, 0), None);
    }
}

#[cfg(target_os = "android")]
pub fn handle_msg_clipboard(mut cb: Clipboard) {
    use camellia_remote_protocol::protobuf::Message;

    if cb.compress {
        if cb.content.len() > proto::MAX_CLIPBOARD_COMPRESSED_BYTES {
            log::warn!(
                "Android clipboard compressed payload ({} bytes) exceeds budget",
                cb.content.len()
            );
            return;
        }
        cb.content = match camellia_remote_protocol::compress::decompress(&cb.content) {
            Ok(content) => {
                if content.len() > proto::MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES {
                    log::warn!(
                        "Android clipboard decompressed payload ({} bytes) exceeds budget",
                        content.len()
                    );
                    return;
                }
                content.into()
            }
            Err(err) => {
                log::warn!("Dropping malformed compressed Android clipboard payload: {err}");
                return;
            }
        };
        cb.compress = false;
    } else if cb.content.len() > proto::MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES {
        log::warn!(
            "Android clipboard uncompressed payload ({} bytes) exceeds budget",
            cb.content.len()
        );
        return;
    }
    let multi_clips = MultiClipboards {
        clipboards: vec![cb],
        ..Default::default()
    };
    if let Ok(bytes) = multi_clips.write_to_bytes() {
        let _ = scrap::android::ffi::call_clipboard_manager_update_clipboard(&bytes);
    }
}

#[cfg(target_os = "android")]
pub fn handle_msg_multi_clipboards(mut mcb: MultiClipboards) {
    use camellia_remote_protocol::protobuf::Message;

    if mcb.clipboards.len() > proto::MAX_CLIPBOARD_ITEMS {
        log::warn!(
            "Android MultiClipboards has {} items, truncating to {}",
            mcb.clipboards.len(),
            proto::MAX_CLIPBOARD_ITEMS
        );
        mcb.clipboards.truncate(proto::MAX_CLIPBOARD_ITEMS);
    }
    let mut total_decompressed = 0usize;
    for cb in mcb.clipboards.iter_mut() {
        if cb.compress {
            if cb.content.len() > proto::MAX_CLIPBOARD_COMPRESSED_BYTES {
                log::warn!(
                    "Android clipboard compressed item ({} bytes) exceeds budget",
                    cb.content.len()
                );
                return;
            }
            cb.content = match camellia_remote_protocol::compress::decompress(&cb.content) {
                Ok(content) => {
                    if content.len() > proto::MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES {
                        log::warn!(
                            "Android clipboard decompressed item ({} bytes) exceeds budget",
                            content.len()
                        );
                        return;
                    }
                    total_decompressed = total_decompressed.saturating_add(content.len());
                    if total_decompressed > proto::MAX_CLIPBOARD_TOTAL_DECOMPRESSED_BYTES {
                        log::warn!(
                            "Android clipboard cumulative decompressed items exceed total budget ({} bytes)",
                            total_decompressed
                        );
                        return;
                    }
                    content.into()
                }
                Err(err) => {
                    log::warn!(
                        "Dropping multi-clipboard message with malformed compressed payload: {err}"
                    );
                    return;
                }
            };
            cb.compress = false;
        } else {
            if cb.content.len() > proto::MAX_CLIPBOARD_ITEM_DECOMPRESSED_BYTES {
                log::warn!(
                    "Android clipboard uncompressed item ({} bytes) exceeds budget",
                    cb.content.len()
                );
                return;
            }
            total_decompressed = total_decompressed.saturating_add(cb.content.len());
            if total_decompressed > proto::MAX_CLIPBOARD_TOTAL_DECOMPRESSED_BYTES {
                log::warn!(
                    "Android clipboard cumulative items exceed total budget ({} bytes)",
                    total_decompressed
                );
                return;
            }
        }
    }
    if let Ok(bytes) = mcb.write_to_bytes() {
        let _ = scrap::android::ffi::call_clipboard_manager_update_clipboard(&bytes);
    }
}

#[cfg(target_os = "android")]
pub fn get_clipboards_msg(client: bool) -> Option<Message> {
    let mut clipboards = scrap::android::ffi::get_clipboards(client)?;
    let mut msg = Message::new();
    for c in &mut clipboards.clipboards {
        match camellia_remote_protocol::compress::compress(&c.content) {
            Ok(compressed) if compressed.len() < c.content.len() => {
                c.content = compressed.into();
                c.compress = true;
            }
            Ok(_) => c.compress = false,
            Err(err) => {
                log::warn!("Failed to compress Android clipboard payload, sending raw data: {err}");
                c.compress = false;
            }
        }
    }
    msg.set_multi_clipboards(clipboards);
    Some(msg)
}

// We need this mod to notify multiple subscribers when the clipboard changes.
// Because only one clipboard master(listener) can trigger the clipboard change event multiple listeners are created on Linux(x11).
// https://github.com/rustdesk-org/clipboard-master/blob/4fb62e5b62fb6350d82b571ec7ba94b3cd466695/src/master/x11.rs#L226
#[cfg(not(target_os = "android"))]
pub mod clipboard_listener {
    use camellia_remote_protocol::{bail, log, ResultType};
    use clipboard_master::{CallbackResult, ClipboardHandler, Master, Shutdown};
    use std::{
        collections::HashMap,
        io,
        sync::mpsc::{channel, RecvTimeoutError, Sender},
        sync::{Arc, Condvar, Mutex},
        thread::JoinHandle,
        time::Duration,
    };

    lazy_static::lazy_static! {
        pub static ref CLIPBOARD_LISTENER: Arc<Mutex<ClipboardListener>> = Default::default();
    }

    struct SubscriberState {
        pending_next: bool,
        control: Option<CallbackResult>,
        closed: bool,
        sender_count: usize,
    }

    struct SubscriberInner {
        state: Mutex<SubscriberState>,
        cvar: Condvar,
    }

    pub struct ClipboardSender {
        inner: Arc<SubscriberInner>,
    }

    impl Clone for ClipboardSender {
        fn clone(&self) -> Self {
            {
                let mut state = self.inner.state.lock().unwrap();
                state.sender_count += 1;
            }
            Self {
                inner: self.inner.clone(),
            }
        }
    }

    impl Drop for ClipboardSender {
        fn drop(&mut self) {
            let mut state = self.inner.state.lock().unwrap();
            state.sender_count = state.sender_count.saturating_sub(1);
            if state.sender_count == 0 {
                self.inner.cvar.notify_all();
            }
        }
    }

    impl ClipboardSender {
        pub fn send(&self, result: CallbackResult) -> Result<(), ()> {
            let mut state = self.inner.state.lock().unwrap();
            if state.closed {
                return Err(());
            }
            match result {
                CallbackResult::Next => {
                    if !state.pending_next {
                        state.pending_next = true;
                        self.inner.cvar.notify_one();
                    }
                }
                CallbackResult::Stop | CallbackResult::StopWithError(_) => {
                    state.closed = true;
                    state.pending_next = false;
                    if state.control.is_none() {
                        state.control = Some(result);
                    }
                    self.inner.cvar.notify_all();
                }
            }
            Ok(())
        }

        pub fn close(&self) {
            let mut state = self.inner.state.lock().unwrap();
            state.closed = true;
            state.pending_next = false;
            if state.control.is_none() {
                state.control = Some(CallbackResult::Stop);
            }
            self.inner.cvar.notify_all();
        }
    }

    pub struct ClipboardReceiver {
        inner: Arc<SubscriberInner>,
    }

    impl Drop for ClipboardReceiver {
        fn drop(&mut self) {
            let mut state = self.inner.state.lock().unwrap();
            state.closed = true;
        }
    }

    impl ClipboardReceiver {
        pub fn recv_timeout(&self, timeout: Duration) -> Result<CallbackResult, RecvTimeoutError> {
            let mut state = self.inner.state.lock().unwrap();
            let deadline = std::time::Instant::now()
                .checked_add(timeout)
                .unwrap_or_else(|| std::time::Instant::now() + Duration::from_secs(86400 * 365));

            loop {
                // High priority control notifications preempt/deliver immediately
                if let Some(control) = state.control.take() {
                    return Ok(control);
                }
                // Coalesced Next notifications
                if state.pending_next {
                    state.pending_next = false;
                    return Ok(CallbackResult::Next);
                }
                // Disconnected or closed
                if state.closed || state.sender_count == 0 {
                    return Err(RecvTimeoutError::Disconnected);
                }

                let now = std::time::Instant::now();
                if now >= deadline {
                    return Err(RecvTimeoutError::Timeout);
                }
                let remaining = deadline - now;
                let (s, _) = self.inner.cvar.wait_timeout(state, remaining).unwrap();
                state = s;
            }
        }
    }

    pub fn clipboard_channel() -> (ClipboardSender, ClipboardReceiver) {
        let inner = Arc::new(SubscriberInner {
            state: Mutex::new(SubscriberState {
                pending_next: false,
                control: None,
                closed: false,
                sender_count: 1,
            }),
            cvar: Condvar::new(),
        });
        (
            ClipboardSender {
                inner: inner.clone(),
            },
            ClipboardReceiver { inner },
        )
    }

    struct Handler {
        subscribers: Arc<Mutex<HashMap<String, ClipboardSender>>>,
    }

    impl ClipboardHandler for Handler {
        fn on_clipboard_change(&mut self) -> CallbackResult {
            let senders: Vec<ClipboardSender> = {
                let sub_lock = self.subscribers.lock().unwrap();
                sub_lock.values().cloned().collect()
            };
            for tx in senders {
                let _ = tx.send(CallbackResult::Next);
            }
            CallbackResult::Next
        }

        fn on_clipboard_error(&mut self, error: io::Error) -> CallbackResult {
            let msg = format!("Clipboard listener error: {}", error);
            let senders: Vec<ClipboardSender> = {
                let sub_lock = self.subscribers.lock().unwrap();
                sub_lock.values().cloned().collect()
            };
            for tx in senders {
                let _ = tx.send(CallbackResult::StopWithError(io::Error::new(
                    io::ErrorKind::Other,
                    msg.clone(),
                )));
            }
            CallbackResult::Next
        }
    }

    #[derive(Default)]
    pub struct ClipboardListener {
        subscribers: Arc<Mutex<HashMap<String, ClipboardSender>>>,
        handle: Option<(Shutdown, JoinHandle<()>)>,
    }

    pub fn subscribe(name: String) -> ResultType<ClipboardReceiver> {
        log::info!("Subscribe clipboard listener: {}", &name);
        let (tx, rx) = clipboard_channel();
        let mut listener_lock = CLIPBOARD_LISTENER.lock().unwrap();
        let old_tx = listener_lock
            .subscribers
            .lock()
            .unwrap()
            .insert(name.clone(), tx);
        if let Some(old) = old_tx {
            old.close();
        }

        cleanup_stale_listener(&mut listener_lock);
        if listener_lock.handle.is_none() {
            log::info!("Start clipboard listener thread");
            let handler = Handler {
                subscribers: listener_lock.subscribers.clone(),
            };
            let (tx_start_res, rx_start_res) = channel();
            let h = start_clipboard_master_thread(handler, tx_start_res);
            let shutdown = match rx_start_res.recv() {
                Ok((Some(s), _)) => s,
                Ok((None, err)) => {
                    listener_lock.subscribers.lock().unwrap().remove(&name);
                    bail!(err);
                }
                Err(e) => {
                    listener_lock.subscribers.lock().unwrap().remove(&name);
                    bail!("Failed to create clipboard listener: {}", e);
                }
            };
            listener_lock.handle = Some((shutdown, h));
            log::info!("Clipboard listener thread started");
        }

        log::info!("Clipboard listener subscribed: {}", name);
        Ok(rx)
    }

    fn cleanup_stale_listener(listener: &mut ClipboardListener) {
        if !listener
            .handle
            .as_ref()
            .map(|(_, h)| h.is_finished())
            .unwrap_or(false)
        {
            return;
        }
        if let Some((shutdown, h)) = listener.handle.take() {
            log::warn!("Cleaning up stale clipboard listener handle");
            if let Err(e) = h.join() {
                log::error!(
                    "Clipboard listener thread panicked during stale cleanup: {:?}",
                    e
                );
            }
            drop(shutdown);
        }
    }

    pub fn unsubscribe(name: &str) {
        log::info!("Unsubscribe clipboard listener: {}", name);
        let mut listener_lock = CLIPBOARD_LISTENER.lock().unwrap();
        let is_empty = {
            let mut sub_lock = listener_lock.subscribers.lock().unwrap();
            if let Some(tx) = sub_lock.remove(name) {
                tx.close();
            }
            sub_lock.is_empty()
        };
        if is_empty {
            if let Some((shutdown, h)) = listener_lock.handle.take() {
                log::info!("Stop clipboard listener thread");
                shutdown.signal();
                h.join().ok();
                log::info!("Clipboard listener thread stopped");
            }
        }
        log::info!("Clipboard listener unsubscribed: {}", name);
    }

    fn start_clipboard_master_thread(
        handler: impl ClipboardHandler + Send + 'static,
        tx_start_res: Sender<(Option<Shutdown>, String)>,
    ) -> JoinHandle<()> {
        let h = std::thread::spawn(move || match Master::new(handler) {
            Ok(mut master) => {
                tx_start_res
                    .send((Some(master.shutdown_channel()), "".to_owned()))
                    .ok();
                log::debug!("Clipboard listener started");
                if let Err(err) = master.run() {
                    log::error!("Failed to run clipboard listener: {}", err);
                } else {
                    log::debug!("Clipboard listener stopped");
                }
            }
            Err(err) => {
                tx_start_res
                    .send((
                        None,
                        format!("Failed to create clipboard listener: {}", err),
                    ))
                    .ok();
            }
        });
        h
    }
}
