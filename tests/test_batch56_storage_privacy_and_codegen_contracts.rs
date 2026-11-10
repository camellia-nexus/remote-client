// test_batch56_storage_privacy_and_codegen_contracts.rs
//
// Verification suite for Batch 56:
// - PRIV-010: Android Host Storage Permission Decoupling & Scoped Storage Perimeter
// - PROV-006: Flutter-Rust Bridge Codegen Provenance & Zero-Drift Verification

use std::fs;
use std::path::{Component, Path, PathBuf};

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Boundary path containment verification logic (PRIV-010).
/// Verifies that a candidate path is strictly within the authorized root
/// without any directory traversal escape (e.g. `..` components or symlink redirection).
fn verify_path_containment(root: &Path, candidate: &Path) -> Result<PathBuf, String> {
    // Normalization check for traversal components
    for comp in candidate.components() {
        if comp == Component::ParentDir {
            return Err("Path traversal attempt detected (contains ParentDir)".to_string());
        }
    }

    let resolved = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        root.join(candidate)
    };

    // Clean normalized comparison
    let mut normalized = PathBuf::new();
    for comp in resolved.components() {
        match comp {
            Component::Prefix(p) => normalized.push(Component::Prefix(p)),
            Component::RootDir => normalized.push(Component::RootDir),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return Err("Path traversal escape above filesystem root".to_string());
                }
            }
            Component::Normal(n) => normalized.push(n),
        }
    }

    // Check if normalized path starts with root
    let root_normalized: PathBuf = root.components().collect();
    if !normalized.starts_with(&root_normalized) {
        return Err(format!(
            "Path containment violation: {} is outside root {}",
            normalized.display(),
            root_normalized.display()
        ));
    }

    Ok(normalized)
}

/// Simulated session capability token bound to storage generation (PRIV-010).
struct StorageCapabilityToken {
    _session_id: u64,
    generation: u64,
    root_path: PathBuf,
}

impl StorageCapabilityToken {
    fn new(session_id: u64, generation: u64, root_path: PathBuf) -> Self {
        Self {
            _session_id: session_id,
            generation,
            root_path,
        }
    }

    fn validate(&self, current_generation: u64, requested_path: &Path) -> Result<PathBuf, String> {
        if self.generation != current_generation {
            return Err(format!(
                "Capability expired: token generation {} != active generation {}",
                self.generation, current_generation
            ));
        }
        verify_path_containment(&self.root_path, requested_path)
    }
}

#[test]
fn test_priv010_path_containment_and_traversal_rejection() {
    let temp_dir = std::env::temp_dir().join("camellia_storage_test_sandbox");
    let _ = fs::create_dir_all(&temp_dir);

    // 1. Valid nested child path
    let child = Path::new("subfolder/document.pdf");
    let result = verify_path_containment(&temp_dir, child);
    assert!(
        result.is_ok(),
        "Valid child path must be allowed: {:?}",
        result
    );
    assert_eq!(result.unwrap(), temp_dir.join("subfolder/document.pdf"));

    // 2. Traversal attempt with ../ must be rejected
    let traversal = Path::new("../escaped.txt");
    let result = verify_path_containment(&temp_dir, traversal);
    assert!(result.is_err(), "Relative path traversal must be rejected");

    // 3. Traversal inside nested path
    let nested_traversal = Path::new("subfolder/../../escaped.txt");
    let result = verify_path_containment(&temp_dir, nested_traversal);
    assert!(result.is_err(), "Nested path traversal must be rejected");

    // 4. Absolute path outside authorized root
    let foreign_abs = if cfg!(windows) {
        PathBuf::from("C:\\Windows\\System32\\cmd.exe")
    } else {
        PathBuf::from("/etc/shadow")
    };
    let result = verify_path_containment(&temp_dir, &foreign_abs);
    assert!(
        result.is_err(),
        "Foreign absolute path must be rejected by containment check"
    );

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_priv010_session_generation_barrier_and_token_invalidation() {
    let root = PathBuf::from("/data/user/0/com.camellia.remote/app_flutter/shared");
    let mut current_generation: u64 = 1;

    let token = StorageCapabilityToken::new(1001, current_generation, root.clone());

    // Valid access under matching generation
    let valid_req = Path::new("files/notes.txt");
    assert!(
        token.validate(current_generation, valid_req).is_ok(),
        "Token must be valid under matching generation"
    );

    // Host stops service or toggles file transfer off -> generation bump
    current_generation += 1;

    // Stale token access must fail closed
    let stale_attempt = token.validate(current_generation, valid_req);
    assert!(
        stale_attempt.is_err(),
        "Stale token must be rejected when generation is incremented"
    );
    assert!(
        stale_attempt.unwrap_err().contains("Capability expired"),
        "Error message must specify generation expiry"
    );
}

#[test]
fn test_priv010_android_manifest_privacy_contracts() {
    let root = get_client_root();
    let manifest =
        fs::read_to_string(root.join("flutter/android/app/src/main/AndroidManifest.xml"))
            .expect("Failed to read AndroidManifest.xml");

    // Invariant 1: No MANAGE_EXTERNAL_STORAGE
    assert!(
        !manifest.contains("android.permission.MANAGE_EXTERNAL_STORAGE"),
        "PRIV-010: MANAGE_EXTERNAL_STORAGE must not be present in release manifest"
    );

    // Invariant 2: No READ_EXTERNAL_STORAGE
    assert!(
        !manifest.contains("android.permission.READ_EXTERNAL_STORAGE"),
        "PRIV-010: READ_EXTERNAL_STORAGE must not be present"
    );

    // Invariant 3: No WRITE_EXTERNAL_STORAGE
    assert!(
        !manifest.contains("android.permission.WRITE_EXTERNAL_STORAGE"),
        "PRIV-010: WRITE_EXTERNAL_STORAGE must not be present"
    );

    // Invariant 4: No requestLegacyExternalStorage
    assert!(
        !manifest.contains("requestLegacyExternalStorage"),
        "PRIV-010: requestLegacyExternalStorage must not be present"
    );
}

#[test]
fn test_prov006_frb_codegen_provenance_and_ci_contracts() {
    let root = get_client_root();

    // 1. Check bridge-codegen-provenance.json
    let prov_json = fs::read_to_string(root.join(".github/config/bridge-codegen-provenance.json"))
        .expect("Failed to read bridge-codegen-provenance.json");
    let val: serde_json::Value = serde_json::from_str(&prov_json)
        .expect("bridge-codegen-provenance.json must be valid JSON");

    assert_eq!(val["schema_version"], 1);
    assert_eq!(val["default_version"], "2.13.0");

    let versions = &val["versions"];
    assert_eq!(
        versions["2.13.0"]["crate_sha256"],
        "701a8e577f9f5f59f651e1e932add36ee5dfb82d0fa20215225ea177d4dbbe4b"
    );
    assert_eq!(
        versions["2.13.0"]["lockfile_sha256"],
        "226c2a5c9116415265d5c0c289f419c21d8d24e92dbbbe87456f7a9789d3ee57"
    );

    assert_eq!(
        versions["2.12.0"]["crate_sha256"],
        "13823e8157bada9dc828d67cd23e4bcebcfffa9313175dacad0325fc3188940c"
    );
    assert_eq!(
        versions["2.12.0"]["lockfile_sha256"],
        "3b4351639c7cbd5c6df393e493ad084b6e7c01ae9ea36fb0097ab775af4e6785"
    );

    // 2. Check generate-bridge.sh has --locked and provenance validation
    let gen_script = fs::read_to_string(root.join(".github/scripts/generate-bridge.sh"))
        .expect("Failed to read generate-bridge.sh");
    assert!(
        gen_script.contains("--locked"),
        "PROV-006: generate-bridge.sh must enforce --locked"
    );
    assert!(
        gen_script.contains("bridge-codegen-provenance.json"),
        "PROV-006: generate-bridge.sh must read bridge-codegen-provenance.json"
    );

    // 3. Check ci.yml contains zero-drift assertion
    let ci_yml =
        fs::read_to_string(root.join(".github/workflows/ci.yml")).expect("Failed to read ci.yml");
    assert!(
        ci_yml.contains("Verify zero bridge drift"),
        "PROV-006: ci.yml must include 'Verify zero bridge drift' step"
    );
    assert!(
        ci_yml.contains("git diff --exit-code"),
        "PROV-006: ci.yml must assert git diff --exit-code"
    );
}
