//! Contract tests for Batch 74 Client Hardening:
//! CONFIG-002 — Custom Client and Group Policy Evaluation Contracts
//! CONFIG-003 — Durable Atomic Address Book / Group Cache Protection Contracts

#![deny(warnings)]

use camellia_remote_protocol::config::{self, HARD_SETTINGS};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;

struct TempDirGuard {
    path: PathBuf,
}

impl TempDirGuard {
    fn new(prefix: &str) -> Self {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("{}_{}_{}", prefix, std::process::id(), timestamp));
        fs::create_dir_all(&path).expect("failed to create temp dir");
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_config002_custom_client_and_policy_evaluation() {
    // 1. Initial baseline: hard settings empty -> not a custom client
    {
        let mut settings = HARD_SETTINGS.write().unwrap();
        settings.clear();
    }
    assert!(!camellia_remote_protocol::config::is_custom_client());
    assert!(!camellia_remote_protocol::config::is_disable_group());
    assert!(!camellia_remote_protocol::config::is_disable_ab());
    assert!(!camellia_remote_protocol::config::is_disable_account());

    // 2. Populate hard settings with custom client configurations
    {
        let mut settings = HARD_SETTINGS.write().unwrap();
        let mut map = HashMap::new();
        map.insert("disable-group".to_string(), "Y".to_string());
        map.insert("disable-ab".to_string(), "Y".to_string());
        map.insert("disable-account".to_string(), "Y".to_string());
        *settings = map;
    }
    assert!(camellia_remote_protocol::config::is_custom_client());
    assert!(camellia_remote_protocol::config::is_disable_group());
    assert!(camellia_remote_protocol::config::is_disable_ab());
    assert!(camellia_remote_protocol::config::is_disable_account());

    // 3. Negative case: values not equal to "Y" must evaluate to false
    {
        let mut settings = HARD_SETTINGS.write().unwrap();
        let mut map = HashMap::new();
        map.insert("disable-group".to_string(), "N".to_string());
        map.insert("disable-ab".to_string(), "false".to_string());
        map.insert("disable-account".to_string(), "".to_string());
        *settings = map;
    }
    // Still considered custom client because hard settings map is not empty
    assert!(camellia_remote_protocol::config::is_custom_client());
    // But specific features are not disabled
    assert!(!camellia_remote_protocol::config::is_disable_group());
    assert!(!camellia_remote_protocol::config::is_disable_ab());
    assert!(!camellia_remote_protocol::config::is_disable_account());

    // Restore clean state
    {
        let mut settings = HARD_SETTINGS.write().unwrap();
        settings.clear();
    }
    assert!(!camellia_remote_protocol::config::is_custom_client());
}

#[test]
fn test_config003_durable_storage_and_error_preservation() {
    let temp_dir = TempDirGuard::new("test_config003_durable");
    let test_file = temp_dir.path().join("durable_cache.bin");

    // 1. Write binary data durably
    let payload = b"{\"peers\":[{\"id\":\"123456789\",\"username\":\"camellia\"}]}";
    config::store_binary_durable(&test_file, payload).expect("store_binary_durable must succeed");

    assert!(test_file.exists());
    let read_back = fs::read(&test_file).expect("must read back file");
    assert_eq!(read_back, payload);

    // 2. Unix file permission check: must be 0o600
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = fs::metadata(&test_file).expect("metadata").permissions();
        assert_eq!(
            perms.mode() & 0o777,
            0o600,
            "durable file mode must be 0o600 on Unix"
        );
    }

    // 3. Verify overwriting replaces contents atomically without leaving temp files
    let payload_v2 = b"{\"peers\":[{\"id\":\"987654321\",\"username\":\"camellia_v2\"}]}";
    config::store_binary_durable(&test_file, payload_v2).expect("overwrite must succeed");
    assert_eq!(fs::read(&test_file).expect("must read back"), payload_v2);

    let tmp_file = temp_dir.path().join("durable_cache.bin.tmp");
    assert!(!tmp_file.exists(), "temp file must be cleanly renamed");
}

#[test]
fn test_config003_concurrent_address_book_and_group_serialization() {
    let temp_dir = TempDirGuard::new("test_config003_concurrent");
    let base_path = Arc::new(temp_dir.path().to_path_buf());

    // Spawn 8 concurrent worker threads writing address book chunks to distinct paths
    let mut handles = Vec::new();
    for i in 0..8 {
        let p = Arc::clone(&base_path);
        let handle = thread::spawn(move || {
            let path = p.join(format!("ab_chunk_{}.json", i));
            let data = format!("{{\"thread_id\": {}, \"iteration\": 42}}", i);
            config::store_binary_durable(&path, data.as_bytes())
                .expect("concurrent store must succeed");
            let read_back = fs::read_to_string(&path).expect("read back");
            assert_eq!(read_back, data);
        });
        handles.push(handle);
    }

    for handle in handles {
        handle.join().expect("thread join must not panic");
    }
}

#[test]
fn test_batch74_source_provenance_contract() {
    let root = get_client_root();
    let prov_path = root.join("SOURCE_PROVENANCE.json");
    let content = fs::read_to_string(&prov_path).expect("must read SOURCE_PROVENANCE.json");
    let json: serde_json::Value =
        serde_json::from_str(&content).expect("SOURCE_PROVENANCE.json must be valid JSON");

    assert_eq!(json["schema_version"], 1);
    assert_eq!(json["component"], "camellia-remote-client");
    assert_eq!(
        json["protocol_source_commit"],
        "891f70bc9507e13a5a555bd9c34e777f8bc2b1c1"
    );
}
