use std::sync::{Arc, Mutex, RwLock};

use camellia_remote_protocol::log;
#[cfg(any(
    target_os = "windows",
    all(target_os = "macos", feature = "unix-file-copy-paste")
))]
use camellia_remote_protocol::ResultType;
use camellia_remote_protocol::{
    lazy_static,
    tokio::sync::{
        mpsc::{channel, Receiver, Sender},
        Mutex as TokioMutex,
    },
};
use serde_derive::{Deserialize, Serialize};
use thiserror::Error;

pub mod operation;
pub use operation::*;

#[cfg(any(
    target_os = "windows",
    all(target_os = "macos", feature = "unix-file-copy-paste")
))]
pub mod context_send;
pub mod platform;
#[cfg(any(
    target_os = "windows",
    all(target_os = "macos", feature = "unix-file-copy-paste")
))]
pub use context_send::*;

static CONNECTION_GENERATION_COUNTER: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(1);

pub fn next_connection_generation() -> u64 {
    CONNECTION_GENERATION_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
}

#[cfg(target_os = "windows")]
const ERR_CODE_SERVER_FUNCTION_NONE: u32 = 0x00000001;
#[cfg(target_os = "windows")]
const ERR_CODE_INVALID_PARAMETER: u32 = 0x00000002;
#[cfg(target_os = "windows")]
const ERR_CODE_SEND_MSG: u32 = 0x00000003;

#[cfg(any(
    target_os = "windows",
    all(target_os = "macos", feature = "unix-file-copy-paste")
))]
pub(crate) use platform::create_cliprdr_context;

pub struct ProgressPercent {
    pub percent: f64,
    pub is_canceled: bool,
    pub is_failed: bool,
}

// to-do: This trait may be removed, because unix file copy paste does not need it.
/// Ability to handle Clipboard File from remote rustdesk client
///
/// # Note
/// There actually should be 2 parts to implement a useable clipboard file service,
/// but this only contains the RPC server part.
/// The local listener and transport part is too platform specific to wrap up in typeclasses.
pub trait CliprdrServiceContext: Send + Sync {
    /// set to be stopped
    fn set_is_stopped(&mut self) -> Result<(), CliprdrError>;
    /// clear the content on clipboard
    fn empty_clipboard(&mut self, conn_id: i32) -> Result<bool, CliprdrError>;
    /// run as a server for clipboard RPC
    fn server_clip_file(&mut self, conn_id: i32, msg: ClipboardFile) -> Result<(), CliprdrError>;
    /// get the progress of the paste task.
    fn get_progress_percent(&self) -> Option<ProgressPercent>;
    /// cancel the paste task.
    fn cancel(&mut self);
}

#[derive(Error, Debug)]
pub enum CliprdrError {
    #[error("invalid cliprdr name")]
    CliprdrName,
    #[error("failed to init cliprdr")]
    CliprdrInit,
    #[error("cliprdr out of memory")]
    CliprdrOutOfMemory,
    #[error("cliprdr internal error")]
    ClipboardInternalError,
    #[error("cliprdr occupied")]
    ClipboardOccupied,
    #[error("conversion failure")]
    ConversionFailure,
    #[error("failure to read clipboard")]
    OpenClipboard,
    #[error("failure to read file metadata or content, path: {path}, err: {err}")]
    FileError { path: String, err: std::io::Error },
    #[error("invalid request: {description}")]
    InvalidRequest { description: String },
    #[error("cliprdr channel full or congested (conn_id: {conn_id})")]
    Backpressure { conn_id: i32 },
    #[error("common request: {description}")]
    CommonError { description: String },
    #[error("unknown cliprdr error")]
    Unknown(u32),
}

pub const FILE_CONTENTS_SIZE_FLAG: u32 = 0x1;
pub const FILE_CONTENTS_RANGE_FLAG: u32 = 0x2;
pub const FILE_CONTENTS_SIZE_BYTES: u32 = 8;
pub const FILE_CONTENTS_MAX_REQUEST_BYTES: u32 = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValidatedFileContentsRequest {
    Size,
    Range { offset: u64, length: u32, end: u64 },
}

pub fn validate_file_contents_request(
    dw_flags: u32,
    n_position_low: u32,
    n_position_high: u32,
    cb_requested: u32,
) -> Result<ValidatedFileContentsRequest, CliprdrError> {
    match dw_flags {
        FILE_CONTENTS_SIZE_FLAG => {
            if n_position_low != 0
                || n_position_high != 0
                || cb_requested != FILE_CONTENTS_SIZE_BYTES
            {
                return Err(CliprdrError::InvalidRequest {
                    description: "non-canonical file size request".to_owned(),
                });
            }
            Ok(ValidatedFileContentsRequest::Size)
        }
        FILE_CONTENTS_RANGE_FLAG => {
            if cb_requested == 0 || cb_requested > FILE_CONTENTS_MAX_REQUEST_BYTES {
                return Err(CliprdrError::InvalidRequest {
                    description: format!(
                        "file content request length {cb_requested} is outside 1..={FILE_CONTENTS_MAX_REQUEST_BYTES}"
                    ),
                });
            }
            let offset = (u64::from(n_position_high) << 32) | u64::from(n_position_low);
            let end = offset.checked_add(u64::from(cb_requested)).ok_or_else(|| {
                CliprdrError::InvalidRequest {
                    description: "file content request offset overflow".to_owned(),
                }
            })?;
            Ok(ValidatedFileContentsRequest::Range {
                offset,
                length: cb_requested,
                end,
            })
        }
        _ => Err(CliprdrError::InvalidRequest {
            description: format!("invalid file content request flags: {dw_flags}"),
        }),
    }
}

pub fn validate_file_contents_payload_len(length: usize) -> Result<u32, CliprdrError> {
    let length = u32::try_from(length).map_err(|_| CliprdrError::InvalidRequest {
        description: "file content response length is not representable".to_owned(),
    })?;
    if length > FILE_CONTENTS_MAX_REQUEST_BYTES {
        return Err(CliprdrError::InvalidRequest {
            description: format!(
                "file content response length {length} exceeds {FILE_CONTENTS_MAX_REQUEST_BYTES}"
            ),
        });
    }
    Ok(length)
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "t", content = "c")]
pub enum ClipboardFile {
    NotifyCallback {
        r#type: String,
        title: String,
        text: String,
    },
    MonitorReady,
    FormatList {
        format_list: Vec<(i32, String)>,
    },
    FormatListResponse {
        msg_flags: i32,
    },
    FormatDataRequest {
        requested_format_id: i32,
    },
    FormatDataResponse {
        msg_flags: i32,
        format_data: Vec<u8>,
    },
    FileContentsRequest {
        stream_id: u32,
        list_index: u32,
        dw_flags: u32,
        n_position_low: u32,
        n_position_high: u32,
        cb_requested: u32,
        have_clip_data_id: bool,
        clip_data_id: u32,
    },
    FileContentsResponse {
        msg_flags: u32,
        stream_id: u32,
        requested_data: Vec<u8>,
    },
    TryEmpty,
    Files {
        files: Vec<(String, u64)>,
    },
}

pub const CLIPRDR_CHANNEL_BOUND: usize = 64;
pub const MAX_CLIPRDR_PAYLOAD_BYTES: usize = 16 * 1024 * 1024; // 16 MiB

struct MsgChannel {
    peer_id: String,
    conn_id: i32,
    #[allow(dead_code)]
    sender: Sender<ClipboardFile>,
    receiver: Arc<TokioMutex<Receiver<ClipboardFile>>>,
}

lazy_static::lazy_static! {
    static ref VEC_MSG_CHANNEL: RwLock<Vec<MsgChannel>> = Default::default();
    static ref CLIENT_CONN_ID_COUNTER: Mutex<i32> = Mutex::new(0);
}

impl ClipboardFile {
    pub fn is_stopping_allowed(&self) -> bool {
        matches!(
            self,
            ClipboardFile::MonitorReady
                | ClipboardFile::FormatList { .. }
                | ClipboardFile::FormatDataRequest { .. }
        )
    }

    pub fn is_beginning_message(&self) -> bool {
        matches!(
            self,
            ClipboardFile::MonitorReady | ClipboardFile::FormatList { .. }
        )
    }
}

pub fn get_client_conn_id(peer_id: &str) -> Option<i32> {
    VEC_MSG_CHANNEL
        .read()
        .unwrap()
        .iter()
        .find(|x| x.peer_id == peer_id)
        .map(|x| x.conn_id)
}

fn get_conn_id() -> i32 {
    let mut lock = CLIENT_CONN_ID_COUNTER.lock().unwrap();
    *lock += 1;
    *lock
}

pub fn get_rx_cliprdr_client(peer_id: &str) -> (i32, Arc<TokioMutex<Receiver<ClipboardFile>>>) {
    let mut lock = VEC_MSG_CHANNEL.write().unwrap();
    match lock.iter().find(|x| x.peer_id == peer_id) {
        Some(msg_channel) => (msg_channel.conn_id, msg_channel.receiver.clone()),
        None => {
            let (sender, receiver) = channel(CLIPRDR_CHANNEL_BOUND);
            let receiver = Arc::new(TokioMutex::new(receiver));
            let receiver2 = receiver.clone();
            let conn_id = get_conn_id();
            let msg_channel = MsgChannel {
                peer_id: peer_id.to_owned(),
                conn_id,
                sender,
                receiver,
            };
            lock.push(msg_channel);
            (conn_id, receiver2)
        }
    }
}

pub fn get_rx_cliprdr_server(conn_id: i32) -> Arc<TokioMutex<Receiver<ClipboardFile>>> {
    let mut lock = VEC_MSG_CHANNEL.write().unwrap();
    match lock.iter().find(|x| x.conn_id == conn_id) {
        Some(msg_channel) => msg_channel.receiver.clone(),
        None => {
            let (sender, receiver) = channel(CLIPRDR_CHANNEL_BOUND);
            let receiver = Arc::new(TokioMutex::new(receiver));
            let receiver2 = receiver.clone();
            let msg_channel = MsgChannel {
                peer_id: "".to_string(),
                conn_id,
                sender,
                receiver,
            };
            lock.push(msg_channel);
            receiver2
        }
    }
}

pub fn remove_channel_by_conn_id(conn_id: i32) {
    let mut lock = VEC_MSG_CHANNEL.write().unwrap();
    if let Some(index) = lock.iter().position(|x| x.conn_id == conn_id) {
        lock.remove(index);
    }
}

#[inline]
pub fn send_data(conn_id: i32, data: ClipboardFile) -> Result<(), CliprdrError> {
    #[cfg(target_os = "windows")]
    return send_data_to_channel(conn_id, data);
    #[cfg(not(target_os = "windows"))]
    if conn_id == 0 {
        send_data_to_all(data);
        Ok(())
    } else {
        send_data_to_channel(conn_id, data)
    }
}

#[inline]
fn send_data_to_channel(conn_id: i32, data: ClipboardFile) -> Result<(), CliprdrError> {
    let payload_len = match &data {
        ClipboardFile::FormatDataResponse { format_data, .. } => format_data.len(),
        ClipboardFile::FileContentsResponse { requested_data, .. } => requested_data.len(),
        ClipboardFile::Files { files } => files.iter().map(|(f, _)| f.len()).sum(),
        _ => 0,
    };
    if payload_len > MAX_CLIPRDR_PAYLOAD_BYTES {
        log::warn!(
            "Cliprdr payload too large ({} bytes > {}), dropping",
            payload_len,
            MAX_CLIPRDR_PAYLOAD_BYTES
        );
        return Err(CliprdrError::InvalidRequest {
            description: format!(
                "cliprdr payload exceeds max budget of {} bytes",
                MAX_CLIPRDR_PAYLOAD_BYTES
            ),
        });
    }

    let sender = {
        let lock = VEC_MSG_CHANNEL.read().unwrap();
        lock.iter()
            .find(|x| x.conn_id == conn_id)
            .map(|x| x.sender.clone())
    };

    if let Some(sender) = sender {
        match sender.try_send(data) {
            Ok(()) => Ok(()),
            Err(camellia_remote_protocol::tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                log::warn!(
                    "Cliprdr channel for conn_id {conn_id} is full ({CLIPRDR_CHANNEL_BOUND} messages queued), backpressure triggered"
                );
                Err(CliprdrError::Backpressure { conn_id })
            }
            Err(camellia_remote_protocol::tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                Err(CliprdrError::InvalidRequest {
                    description: "channel closed".to_string(),
                })
            }
        }
    } else {
        Err(CliprdrError::InvalidRequest {
            description: "conn_id not found".to_string(),
        })
    }
}

#[inline]
#[cfg(target_os = "windows")]
pub fn send_data_exclude(conn_id: i32, data: ClipboardFile) {
    let senders: Vec<(i32, Sender<ClipboardFile>)> = {
        let lock = VEC_MSG_CHANNEL.read().unwrap();
        lock.iter()
            .filter(|x| x.conn_id != conn_id)
            .map(|x| (x.conn_id, x.sender.clone()))
            .collect()
    };
    for (target_id, sender) in senders {
        if let Err(e) = sender.try_send(data.clone()) {
            log::debug!("send_data_exclude failed for conn_id {target_id}: {:?}", e);
        }
    }
}

#[inline]
fn send_data_to_all(data: ClipboardFile) {
    let senders: Vec<(i32, Sender<ClipboardFile>)> = {
        let lock = VEC_MSG_CHANNEL.read().unwrap();
        lock.iter().map(|x| (x.conn_id, x.sender.clone())).collect()
    };
    for (target_id, sender) in senders {
        if let Err(e) = sender.try_send(data.clone()) {
            log::debug!("send_data_to_all failed for conn_id {target_id}: {:?}", e);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_contents_size_request_requires_canonical_fields() {
        assert_eq!(
            validate_file_contents_request(FILE_CONTENTS_SIZE_FLAG, 0, 0, 8).unwrap(),
            ValidatedFileContentsRequest::Size
        );

        for (low, high, length) in [(1, 0, 8), (0, 1, 8), (0, 0, 7), (0, 0, 9)] {
            assert!(
                validate_file_contents_request(FILE_CONTENTS_SIZE_FLAG, low, high, length).is_err()
            );
        }
    }

    #[test]
    fn file_contents_range_request_enforces_offset_and_allocation_budget() {
        assert_eq!(
            validate_file_contents_request(FILE_CONTENTS_RANGE_FLAG, 0, 0, 1).unwrap(),
            ValidatedFileContentsRequest::Range {
                offset: 0,
                length: 1,
                end: 1,
            }
        );
        assert_eq!(
            validate_file_contents_request(
                FILE_CONTENTS_RANGE_FLAG,
                u32::MAX,
                0,
                FILE_CONTENTS_MAX_REQUEST_BYTES,
            )
            .unwrap(),
            ValidatedFileContentsRequest::Range {
                offset: u64::from(u32::MAX),
                length: FILE_CONTENTS_MAX_REQUEST_BYTES,
                end: u64::from(u32::MAX) + u64::from(FILE_CONTENTS_MAX_REQUEST_BYTES),
            }
        );

        for length in [
            0,
            FILE_CONTENTS_MAX_REQUEST_BYTES + 1,
            i32::MAX as u32,
            i32::MIN as u32,
            u32::MAX,
        ] {
            assert!(
                validate_file_contents_request(FILE_CONTENTS_RANGE_FLAG, 0, 0, length).is_err()
            );
        }
        assert!(
            validate_file_contents_request(FILE_CONTENTS_RANGE_FLAG, u32::MAX, u32::MAX, 1,)
                .is_err()
        );
        assert!(validate_file_contents_request(0, 0, 0, 1).is_err());
        assert!(validate_file_contents_request(3, 0, 0, 1).is_err());
    }

    #[test]
    fn file_contents_response_payload_enforces_allocation_budget() {
        assert_eq!(validate_file_contents_payload_len(0).unwrap(), 0);
        assert_eq!(
            validate_file_contents_payload_len(FILE_CONTENTS_MAX_REQUEST_BYTES as usize).unwrap(),
            FILE_CONTENTS_MAX_REQUEST_BYTES
        );
        assert!(
            validate_file_contents_payload_len(FILE_CONTENTS_MAX_REQUEST_BYTES as usize + 1)
                .is_err()
        );
    }
}
