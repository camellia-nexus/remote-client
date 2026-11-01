use lazy_static::lazy_static;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, RwLock,
    },
    time::{Duration, Instant},
};
use uuid::Uuid;
use zeroize::Zeroizing;

const DEFAULT_CAPABILITY_TTL: Duration = Duration::from_secs(30);

pub struct CapabilityRecord {
    pub peer_id: String,
    pub secret: Zeroizing<String>,
    pub created_at: Instant,
    pub ttl: Duration,
    pub consumed: AtomicBool,
}

pub struct CapabilityVault {
    records: Arc<RwLock<HashMap<String, CapabilityRecord>>>,
}

impl Default for CapabilityVault {
    fn default() -> Self {
        Self::new()
    }
}

impl CapabilityVault {
    pub fn new() -> Self {
        Self {
            records: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub fn create_capability(&self, peer_id: &str, secret: &str) -> String {
        self.create_capability_with_ttl(peer_id, secret, DEFAULT_CAPABILITY_TTL)
    }

    pub fn create_capability_with_ttl(&self, peer_id: &str, secret: &str, ttl: Duration) -> String {
        let handle = format!("cap_{}", Uuid::new_v4().simple());
        let record = CapabilityRecord {
            peer_id: peer_id.to_string(),
            secret: Zeroizing::new(secret.to_string()),
            created_at: Instant::now(),
            ttl,
            consumed: AtomicBool::new(false),
        };

        let mut lock = self.records.write().unwrap();
        // Opportunistic cleanup of expired capabilities
        lock.retain(|_, rec| {
            rec.created_at.elapsed() < rec.ttl && !rec.consumed.load(Ordering::Relaxed)
        });
        lock.insert(handle.clone(), record);
        handle
    }

    pub fn consume_capability(&self, peer_id: &str, handle: &str) -> Option<Zeroizing<String>> {
        let mut lock = self.records.write().unwrap();
        let record = lock.remove(handle)?;

        if record.consumed.swap(true, Ordering::SeqCst) {
            // Already consumed (replay attempt)
            return None;
        }

        if record.created_at.elapsed() >= record.ttl {
            // Expired
            return None;
        }

        if record.peer_id != peer_id {
            // Target peer ID mismatch
            return None;
        }

        Some(record.secret)
    }

    #[cfg(test)]
    pub fn count(&self) -> usize {
        self.records.read().unwrap().len()
    }
}

lazy_static! {
    static ref GLOBAL_VAULT: CapabilityVault = CapabilityVault::new();
}

pub fn create_capability_handle(peer_id: &str, secret: &str) -> String {
    GLOBAL_VAULT.create_capability(peer_id, secret)
}

pub fn consume_capability_handle(peer_id: &str, handle: &str) -> Option<Zeroizing<String>> {
    GLOBAL_VAULT.consume_capability(peer_id, handle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_capability_vault_single_use() {
        let vault = CapabilityVault::new();
        let handle = vault.create_capability("peer_123", "CANARY_SECRET_999");

        assert!(handle.starts_with("cap_"));

        // First consume succeeds
        let secret = vault.consume_capability("peer_123", &handle);
        assert_eq!(
            secret.as_deref().map(|s| s.as_str()),
            Some("CANARY_SECRET_999")
        );

        // Replay attempt fails
        let replay = vault.consume_capability("peer_123", &handle);
        assert!(
            replay.is_none(),
            "Replay of consumed capability must return None"
        );
    }

    #[test]
    fn test_capability_vault_rejects_peer_id_mismatch() {
        let vault = CapabilityVault::new();
        let handle = vault.create_capability("peer_123", "CANARY_SECRET_888");

        // Wrong peer ID attempt fails and removes the capability
        let result = vault.consume_capability("peer_999", &handle);
        assert!(result.is_none(), "Mismatched peer_id must return None");

        // Subsequent attempt with right peer ID also fails (fail-closed)
        let retry = vault.consume_capability("peer_123", &handle);
        assert!(
            retry.is_none(),
            "Compromised/mismatched handle must not be reusable"
        );
    }

    #[test]
    fn test_capability_vault_expires_after_ttl() {
        let vault = CapabilityVault::new();
        let handle = vault.create_capability_with_ttl(
            "peer_123",
            "CANARY_SECRET_777",
            Duration::from_millis(10),
        );

        std::thread::sleep(Duration::from_millis(20));

        let expired = vault.consume_capability("peer_123", &handle);
        assert!(expired.is_none(), "Expired capability must return None");
    }
}
