use camellia_remote_protocol::log;
use std::sync::{
    atomic::{AtomicI64, AtomicU64, Ordering},
    Arc, RwLock,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceCallOwner {
    pub conn_id: i32,
    pub call_id: i64,
    pub generation: u64,
}

lazy_static::lazy_static! {
    pub static ref VOICE_CALL_MANAGER: VoiceCallManager = VoiceCallManager::new();
    static ref CALL_ID_COUNTER: AtomicI64 = AtomicI64::new(1);
    static ref GENERATION_COUNTER: AtomicU64 = AtomicU64::new(1);
}

/// Generates a 64-bit cryptographic/monotonic call ID:
/// High 32 bits monotonic sequence + low 32 bits CSPRNG entropy.
pub fn generate_call_id() -> i64 {
    let seq = CALL_ID_COUNTER.fetch_add(1, Ordering::SeqCst) as u64 & 0xFFFF_FFFF;
    let entropy = (camellia_remote_protocol::rand::random::<u32>()) as u64;
    let combined = ((seq << 32) | entropy) as i64;
    if combined == 0 {
        1
    } else {
        combined
    }
}

pub fn next_voice_call_generation() -> u64 {
    GENERATION_COUNTER.fetch_add(1, Ordering::SeqCst)
}

#[derive(Default)]
pub struct VoiceCallManager {
    active_owner: Arc<RwLock<Option<VoiceCallOwner>>>,
    input_device: Arc<RwLock<Option<String>>>,
}

impl VoiceCallManager {
    pub fn new() -> Self {
        Self {
            active_owner: Arc::new(RwLock::new(None)),
            input_device: Arc::new(RwLock::new(None)),
        }
    }

    /// Attempts to register a voice call for `conn_id`.
    /// Returns `Err("busy")` if another connection currently owns the active voice call.
    pub fn try_register_call(
        &self,
        conn_id: i32,
        call_id: i64,
        generation: u64,
    ) -> Result<(), &'static str> {
        let mut lock = self.active_owner.write().unwrap();
        if let Some(owner) = lock.as_ref() {
            if owner.conn_id != conn_id {
                log::warn!(
                    "Voice call rejected: active owner is conn_id={}, attempted by conn_id={}",
                    owner.conn_id,
                    conn_id
                );
                return Err("busy");
            }
        }
        *lock = Some(VoiceCallOwner {
            conn_id,
            call_id,
            generation,
        });
        Ok(())
    }

    /// Releases the active voice call if and only if `conn_id` is the current owner.
    /// Returns `true` if this connection was the owner and the call was released.
    pub fn release_call_if_owner(&self, conn_id: i32) -> bool {
        let mut lock = self.active_owner.write().unwrap();
        if let Some(owner) = lock.as_ref() {
            if owner.conn_id == conn_id {
                *lock = None;
                *self.input_device.write().unwrap() = None;
                log::info!("Voice call released by owning conn_id={}", conn_id);
                return true;
            }
        }
        false
    }

    pub fn is_owner(&self, conn_id: i32) -> bool {
        self.active_owner
            .read()
            .unwrap()
            .as_ref()
            .map_or(false, |o| o.conn_id == conn_id)
    }

    pub fn get_owner(&self) -> Option<VoiceCallOwner> {
        self.active_owner.read().unwrap().clone()
    }

    pub fn set_voice_call_input_device(&self, device: Option<String>, conn_id: Option<i32>) {
        if let Some(cid) = conn_id {
            if !self.is_owner(cid) {
                log::warn!(
                    "Non-owner conn_id={} attempted to set voice call input device",
                    cid
                );
                return;
            }
        }
        *self.input_device.write().unwrap() = device;
    }

    pub fn get_voice_call_input_device(&self) -> Option<String> {
        self.input_device.read().unwrap().clone()
    }

    #[cfg(test)]
    pub fn reset_for_test(&self) {
        *self.active_owner.write().unwrap() = None;
        *self.input_device.write().unwrap() = None;
    }
}
