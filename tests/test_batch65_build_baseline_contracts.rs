//! Integration and contract tests for Batch 65:
//! BUILD-001 — Client 生成步骤和静态检查技术债未形成闭环.

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_batch65_bridge_files_exist_and_unignored() {
    let root = get_client_root();
    let bridge_rs = root.join("src/bridge_generated.rs");
    let bridge_ios = root.join("flutter/ios/Runner/bridge_generated.h");
    let bridge_mac = root.join("flutter/macos/Runner/bridge_generated.h");

    assert!(bridge_rs.exists(), "src/bridge_generated.rs must exist");
    let meta = fs::metadata(&bridge_rs).expect("metadata for bridge_generated.rs");
    assert!(meta.len() > 1000, "bridge_generated.rs must not be empty");

    assert!(bridge_ios.exists(), "iOS bridge header must exist");
    assert!(bridge_mac.exists(), "macOS bridge header must exist");

    let client_gi = fs::read_to_string(root.join(".gitignore")).expect("read client .gitignore");
    let flutter_gi =
        fs::read_to_string(root.join("flutter/.gitignore")).expect("read flutter .gitignore");

    assert!(
        !client_gi.contains("src/bridge_generated.rs"),
        "client .gitignore must not ignore src/bridge_generated.rs"
    );
    assert!(
        !flutter_gi.contains("**/Runner/bridge_generated.h"),
        "flutter .gitignore must not ignore Runner/bridge_generated.h"
    );
}

#[test]
fn test_batch65_build_rs_asserts_bridge_prerequisite() {
    let root = get_client_root();
    let build_rs = root.join("build.rs");
    assert!(build_rs.exists(), "build.rs must exist");

    let content = fs::read_to_string(&build_rs).expect("read build.rs");
    assert!(
        content.contains("fn ensure_bridge_prerequisites()"),
        "build.rs must define ensure_bridge_prerequisites()"
    );
    assert!(
        content.contains("src/bridge_generated.rs"),
        "build.rs must check src/bridge_generated.rs"
    );
    assert!(
        content.contains("BUILD-001 ERROR"),
        "build.rs must provide informative BUILD-001 error diagnostic"
    );
    assert!(
        content.contains("ensure_bridge_prerequisites();"),
        "build.rs must call ensure_bridge_prerequisites() in main()"
    );
}

#[test]
fn test_batch65_build_py_bridge_handling() {
    let root = get_client_root();
    let build_py = root.join("build.py");
    assert!(build_py.exists(), "build.py must exist");

    let content = fs::read_to_string(&build_py).expect("read build.py");
    assert!(
        content.contains("def ensure_bridge(force=False):"),
        "build.py must define ensure_bridge(force=False)"
    );
    assert!(
        content.contains("--regenerate-bridge"),
        "build.py must support --regenerate-bridge CLI option"
    );
    assert!(
        content.contains("ensure_bridge(force=args.regenerate_bridge)"),
        "build.py must invoke ensure_bridge"
    );
}

#[test]
fn test_batch65_clippy_baseline_invariants() {
    let root = get_client_root();
    let baseline_path = root.join(".github/config/clippy-baseline.json");
    assert!(baseline_path.exists(), "clippy-baseline.json must exist");

    let text = fs::read_to_string(&baseline_path).expect("read clippy-baseline.json");
    let json: serde_json::Value = serde_json::from_str(&text).expect("parse clippy JSON");

    assert_eq!(json["schema_version"].as_i64(), Some(1));
    assert_eq!(json["total_allowed_warnings"].as_i64(), Some(1579));

    let by_pkg = json["by_package"].as_object().expect("by_package map");
    assert_eq!(
        by_pkg.get("camellia-remote").and_then(|v| v.as_i64()),
        Some(1103)
    );
    assert_eq!(by_pkg.get("scrap").and_then(|v| v.as_i64()), Some(355));
    assert_eq!(by_pkg.get("enigo").and_then(|v| v.as_i64()), Some(118));
    assert_eq!(
        by_pkg.get("virtual_display").and_then(|v| v.as_i64()),
        Some(3)
    );

    let sum_pkgs: i64 = by_pkg.values().filter_map(|v| v.as_i64()).sum();
    assert_eq!(sum_pkgs, 1579);

    let by_code = json["by_lint_code"].as_object().expect("by_lint_code map");
    assert!(by_code.len() > 20);
    let sum_codes: i64 = by_code.values().filter_map(|v| v.as_i64()).sum();
    assert_eq!(sum_codes, 1579);

    let fps = json["fingerprints"].as_array().expect("fingerprints array");
    assert_eq!(
        fps.len() as i64,
        json["total_unique_fingerprints"].as_i64().unwrap_or(0)
    );
}

#[test]
fn test_batch65_flutter_analyze_baseline_invariants() {
    let root = get_client_root();
    let baseline_path = root.join(".github/config/flutter-analyze-baseline.json");
    assert!(
        baseline_path.exists(),
        "flutter-analyze-baseline.json must exist"
    );

    let text = fs::read_to_string(&baseline_path).expect("read flutter baseline JSON");
    let json: serde_json::Value = serde_json::from_str(&text).expect("parse flutter JSON");

    assert_eq!(json["schema_version"].as_i64(), Some(1));
    assert_eq!(json["total_allowed_issues"].as_i64(), Some(896));

    let by_sev = json["by_severity"].as_object().expect("by_severity map");
    assert_eq!(by_sev.get("INFO").and_then(|v| v.as_i64()), Some(896));
    assert!(!by_sev.contains_key("WARNING"));
    assert!(!by_sev.contains_key("ERROR"));

    let by_code = json["by_lint_code"].as_object().expect("by_lint_code map");
    assert_eq!(by_code.len(), 31);
    let sum_codes: i64 = by_code.values().filter_map(|v| v.as_i64()).sum();
    assert_eq!(sum_codes, 896);

    let fps = json["fingerprints"].as_array().expect("fingerprints array");
    assert_eq!(
        fps.len() as i64,
        json["total_unique_fingerprints"].as_i64().unwrap_or(0)
    );
}

#[test]
fn test_batch65_ci_workflow_quality_gate() {
    let root = get_client_root();
    let ci_yml = root.join(".github/workflows/ci.yml");
    assert!(ci_yml.exists(), "ci.yml must exist");

    let content = fs::read_to_string(&ci_yml).expect("read ci.yml");
    assert!(
        content.contains("verify_quality_baselines.py --clippy"),
        "ci.yml must run verify_quality_baselines.py --clippy"
    );
    assert!(
        content.contains("verify_quality_baselines.py --flutter"),
        "ci.yml must run verify_quality_baselines.py --flutter"
    );
    assert!(
        !content.contains("flutter analyze --no-fatal-infos"),
        "ci.yml must eliminate unbudgeted flutter analyze --no-fatal-infos"
    );
}
