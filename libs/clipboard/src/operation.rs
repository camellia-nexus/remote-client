use crate::CliprdrError;
use camellia_remote_protocol::log;
use camellia_remote_protocol::tokio_util::sync::CancellationToken;
use parking_lot::RwLock;
use std::{
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};

pub const CLIPBOARD_FILE_OP_TTL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ClipboardFileOpId(pub u64);

impl ClipboardFileOpId {
    pub fn new_random() -> Self {
        let val = camellia_remote_protocol::rand::random::<u64>();
        Self(if val == 0 { 1 } else { val })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipboardOpState {
    FormatListReceived,
    DescriptorRequested,
    Transferring,
    Completed,
    Cancelled,
    Expired,
}

#[derive(Debug, Clone)]
pub struct ClipboardFileOperation {
    pub op_id: ClipboardFileOpId,
    pub conn_id: i32,
    pub conn_generation: u64,
    pub side_is_client: bool,
    pub file_descriptor_id: i32,
    pub target_root: Option<PathBuf>,
    pub created_at: Instant,
    pub deadline: Instant,
    pub state: ClipboardOpState,
    pub cancel_token: CancellationToken,
}

impl ClipboardFileOperation {
    pub fn new(
        conn_id: i32,
        conn_generation: u64,
        side_is_client: bool,
        file_descriptor_id: i32,
    ) -> Self {
        let now = Instant::now();
        Self {
            op_id: ClipboardFileOpId::new_random(),
            conn_id,
            conn_generation,
            side_is_client,
            file_descriptor_id,
            target_root: None,
            created_at: now,
            deadline: now + CLIPBOARD_FILE_OP_TTL,
            state: ClipboardOpState::FormatListReceived,
            cancel_token: CancellationToken::new(),
        }
    }

    #[inline]
    pub fn is_expired(&self) -> bool {
        Instant::now() >= self.deadline
    }

    #[inline]
    pub fn matches_connection(&self, conn_id: i32, conn_generation: u64) -> bool {
        if self.conn_id != conn_id {
            return false;
        }
        if self.conn_generation != 0 {
            self.conn_generation == conn_generation
        } else {
            true
        }
    }
}

lazy_static::lazy_static! {
    pub static ref GLOBAL_CLIPBOARD_OP_MGR: Arc<RwLock<Option<ClipboardFileOperation>>> =
        Arc::new(RwLock::new(None));
}

pub struct ClipboardOpGuard;

impl ClipboardOpGuard {
    /// Initiates a new operation, automatically superseding and cancelling any previous operation.
    pub fn initiate_operation(
        conn_id: i32,
        conn_generation: u64,
        side_is_client: bool,
        file_descriptor_id: i32,
    ) -> ClipboardFileOpId {
        let mut guard = GLOBAL_CLIPBOARD_OP_MGR.write();
        if let Some(prev) = guard.take() {
            log::info!(
                "Cancelling previous clipboard operation {:?} (conn_id={}, gen={})",
                prev.op_id,
                prev.conn_id,
                prev.conn_generation
            );
            prev.cancel_token.cancel();
        }
        let op = ClipboardFileOperation::new(
            conn_id,
            conn_generation,
            side_is_client,
            file_descriptor_id,
        );
        let op_id = op.op_id;
        *guard = Some(op);
        op_id
    }

    pub fn set_target_root(
        op_id: ClipboardFileOpId,
        target_root: PathBuf,
    ) -> Result<(), CliprdrError> {
        let mut guard = GLOBAL_CLIPBOARD_OP_MGR.write();
        if let Some(op) = guard.as_mut() {
            if op.op_id == op_id {
                op.target_root = Some(target_root);
                return Ok(());
            }
        }
        Err(CliprdrError::InvalidRequest {
            description: "No matching active operation for target root".to_string(),
        })
    }

    /// Validates an incoming FormatDataResponse against the active operation.
    pub fn validate_format_data_response(
        conn_id: i32,
        conn_generation: u64,
    ) -> Result<(ClipboardFileOpId, Option<PathBuf>, CancellationToken), CliprdrError> {
        let mut guard = GLOBAL_CLIPBOARD_OP_MGR.write();
        let Some(op) = guard.as_mut() else {
            return Err(CliprdrError::InvalidRequest {
                description: "No active clipboard file operation".to_string(),
            });
        };

        if op.is_expired() {
            op.state = ClipboardOpState::Expired;
            op.cancel_token.cancel();
            guard.take();
            return Err(CliprdrError::InvalidRequest {
                description: "Clipboard file operation expired (30s TTL)".to_string(),
            });
        }

        if !op.matches_connection(conn_id, conn_generation) {
            log::warn!(
                "Rejecting cross-session FormatDataResponse from conn_id={} gen={}, active is conn_id={} gen={}",
                conn_id, conn_generation, op.conn_id, op.conn_generation
            );
            return Err(CliprdrError::InvalidRequest {
                description: "Connection or generation mismatch".to_string(),
            });
        }

        op.state = ClipboardOpState::Transferring;
        Ok((op.op_id, op.target_root.clone(), op.cancel_token.clone()))
    }

    /// Validates an incoming FileContentsResponse against the active operation.
    pub fn validate_file_contents_response(
        conn_id: i32,
        conn_generation: u64,
    ) -> Result<ClipboardFileOpId, CliprdrError> {
        let guard = GLOBAL_CLIPBOARD_OP_MGR.read();
        let Some(op) = guard.as_ref() else {
            return Err(CliprdrError::InvalidRequest {
                description: "No active clipboard file operation".to_string(),
            });
        };

        if op.is_expired() {
            return Err(CliprdrError::InvalidRequest {
                description: "Clipboard file operation expired (30s TTL)".to_string(),
            });
        }

        if !op.matches_connection(conn_id, conn_generation) {
            log::warn!(
                "Rejecting cross-session FileContentsResponse from conn_id={} gen={}, active is conn_id={} gen={}",
                conn_id, conn_generation, op.conn_id, op.conn_generation
            );
            return Err(CliprdrError::InvalidRequest {
                description: "Connection or generation mismatch".to_string(),
            });
        }

        Ok(op.op_id)
    }

    /// Aborts any active operation for the given connection upon disconnect or permission revocation.
    pub fn abort_for_connection(conn_id: i32, conn_generation: u64) {
        let mut guard = GLOBAL_CLIPBOARD_OP_MGR.write();
        if let Some(op) = guard.as_ref() {
            if op.matches_connection(conn_id, conn_generation) {
                log::info!(
                    "Aborting clipboard operation {:?} for closed conn_id={}",
                    op.op_id,
                    conn_id
                );
                op.cancel_token.cancel();
                guard.take();
            }
        }
    }

    #[cfg(test)]
    pub fn reset_for_test() {
        let mut guard = GLOBAL_CLIPBOARD_OP_MGR.write();
        if let Some(op) = guard.take() {
            op.cancel_token.cancel();
        }
    }
}
