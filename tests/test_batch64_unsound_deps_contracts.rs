//! Integration and contract tests for Batch 64:
//! DEP-001 — Client 保留两个未修复的 unsound 依赖告警 (glib 0.18.5 & atty 0.2.14).

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_dep001_cargo_lock_purges_atty_and_obsolete_bindgen() {
    let client_root = get_client_root();
    let lock_path = client_root.join("Cargo.lock");
    assert!(
        lock_path.exists(),
        "Cargo.lock must exist at {:?}",
        lock_path
    );

    let content = fs::read_to_string(&lock_path).expect("read Cargo.lock");

    // atty package must not exist in Cargo.lock
    assert!(
        !content.contains("name = \"atty\""),
        "Cargo.lock must not contain atty package"
    );

    // ansi_term package must not exist in Cargo.lock
    assert!(
        !content.contains("name = \"ansi_term\""),
        "Cargo.lock must not contain ansi_term package"
    );

    // bindgen 0.59.x (which brought in clap 2 / atty) must not exist
    for block in content.split("[[package]]") {
        if block.contains("name = \"bindgen\"") && block.contains("0.59.") {
            panic!(
                "Cargo.lock must not contain obsolete bindgen 0.59.x: {}",
                block
            );
        }
    }
}

#[test]
fn test_dep001_glib_018_is_locally_patched_without_crates_io_source() {
    let client_root = get_client_root();
    let lock_path = client_root.join("Cargo.lock");
    let content = fs::read_to_string(&lock_path).expect("read Cargo.lock");

    // Split Cargo.lock by [[package]] blocks
    let mut found_glib_018 = false;
    for block in content.split("[[package]]") {
        if block.contains("name = \"glib\"") && block.contains("version = \"0.18.5\"") {
            found_glib_018 = true;
            assert!(
                !block.contains("source = \"registry+https://github.com/rust-lang/crates.io-index\""),
                "glib 0.18.5 must not be sourced from crates.io registry; it must be an in-tree patch:\n{}",
                block
            );
        }
    }
    assert!(found_glib_018, "glib 0.18.5 block must exist in Cargo.lock");
}

#[test]
fn test_dep001_cargo_audit_policy_has_zero_unsound_exceptions() {
    let client_root = get_client_root();
    let policy_path = client_root.join(".github/config/cargo-audit-policy.json");
    assert!(policy_path.exists(), "Audit policy must exist");

    let text = fs::read_to_string(&policy_path).expect("read cargo-audit-policy.json");
    let json: serde_json::Value = serde_json::from_str(&text).expect("valid JSON");

    assert_eq!(
        json["schema_version"].as_i64(),
        Some(1),
        "schema_version must be 1"
    );

    let reviewed_on = json["reviewed_on"].as_str().expect("reviewed_on string");
    assert!(
        reviewed_on >= "2026-11-11",
        "reviewed_on must be >= 2026-11-11, got {}",
        reviewed_on
    );

    let exception_groups = json["exception_groups"]
        .as_array()
        .expect("exception_groups array");
    for group in exception_groups {
        let group_id = group["id"].as_str().unwrap_or("unknown");
        let expires_on = group["expires_on"].as_str().expect("expires_on string");
        assert!(
            expires_on > reviewed_on,
            "Group {} expires_on ({}) must be strictly after reviewed_on ({})",
            group_id,
            expires_on,
            reviewed_on
        );

        let warnings = group["warnings"].as_array().expect("warnings array");
        for warn in warnings {
            let category = warn["category"].as_str().unwrap_or("");
            assert_ne!(
                category, "unsound",
                "Policy must contain ZERO 'unsound' exceptions, found one in group {}",
                group_id
            );

            let package = warn["package"].as_str().unwrap_or("");
            assert_ne!(
                package, "atty",
                "Policy must not contain exceptions for package 'atty'"
            );
            assert_ne!(
                package, "ansi_term",
                "Policy must not contain exceptions for package 'ansi_term'"
            );

            let advisory_id = warn["advisory_id"].as_str().unwrap_or("");
            assert_ne!(
                advisory_id, "RUSTSEC-2024-0429",
                "Policy must not contain exception for glib unsoundness RUSTSEC-2024-0429"
            );
            assert_ne!(
                advisory_id, "RUSTSEC-2021-0145",
                "Policy must not contain exception for atty unsoundness RUSTSEC-2021-0145"
            );
            assert_ne!(
                advisory_id, "RUSTSEC-2024-0375",
                "Policy must not contain exception for atty unmaintained RUSTSEC-2024-0375"
            );
        }
    }

    // Total warning budget must be exactly 24 (9 in gtk3, 15 in inherited)
    let total_warnings: usize = exception_groups
        .iter()
        .map(|g| g["warnings"].as_array().map(|w| w.len()).unwrap_or(0))
        .sum();
    assert_eq!(
        total_warnings, 24,
        "Total policy warnings budget must be exactly 24 after purging atty, ansi_term, and unsound glib (got {})",
        total_warnings
    );
}

#[test]
fn test_dep001_cargo_toml_patch_and_workspace_integrity() {
    let client_root = get_client_root();
    let toml_path = client_root.join("Cargo.toml");
    let content = fs::read_to_string(&toml_path).expect("read Cargo.toml");

    // Excluded from workspace root members to avoid test/dev pollution
    assert!(
        content.contains("\"libs/glib\""),
        "libs/glib must be in workspace.exclude"
    );
    assert!(
        content.contains("\"libs/magnum-opus\""),
        "libs/magnum-opus must be in workspace.exclude"
    );
    assert!(
        content.contains("\"libs/hwcodec\""),
        "libs/hwcodec must be in workspace.exclude"
    );

    // Patches configured
    assert!(
        content.contains("[patch.crates-io]"),
        "[patch.crates-io] must be present"
    );
    assert!(
        content.contains("glib = { path = \"libs/glib\" }"),
        "glib patch must point to libs/glib"
    );
    assert!(
        content.contains("[patch.\"https://github.com/rustdesk-org/magnum-opus\"]"),
        "magnum-opus git patch table must be present"
    );
    assert!(
        content.contains("[patch.\"https://github.com/rustdesk-org/hwcodec\"]"),
        "hwcodec git patch table must be present"
    );
}

#[test]
fn test_dep001_in_tree_patches_verification() {
    let client_root = get_client_root();

    // 1. glib variant_iter upstream fix
    let variant_iter_path = client_root.join("libs/glib/src/variant_iter.rs");
    assert!(variant_iter_path.exists(), "variant_iter.rs must exist");
    let variant_iter_src = fs::read_to_string(&variant_iter_path).expect("read variant_iter.rs");
    assert!(
        variant_iter_src.contains("let mut p: *mut libc::c_char = std::ptr::null_mut();"),
        "variant_iter.rs must declare mutable pointer for g_variant_get_child"
    );
    assert!(
        variant_iter_src.contains("&mut p"),
        "variant_iter.rs must pass &mut p to ffi::g_variant_get_child"
    );

    // 2. magnum-opus modern bindgen
    let magnum_toml = client_root.join("libs/magnum-opus/Cargo.toml");
    let magnum_content = fs::read_to_string(&magnum_toml).expect("read magnum-opus Cargo.toml");
    assert!(
        magnum_content.contains("bindgen = \"0.71\""),
        "magnum-opus must use bindgen 0.71"
    );
    assert!(
        !magnum_content.contains("0.59"),
        "magnum-opus must not use bindgen 0.59"
    );

    // 3. hwcodec modern bindgen
    let hwcodec_toml = client_root.join("libs/hwcodec/Cargo.toml");
    let hwcodec_content = fs::read_to_string(&hwcodec_toml).expect("read hwcodec Cargo.toml");
    assert!(
        hwcodec_content.contains("bindgen = \"0.71\""),
        "hwcodec must use bindgen 0.71"
    );
    assert!(
        !hwcodec_content.contains("0.59"),
        "hwcodec must not use bindgen 0.59"
    );
}

#[test]
fn test_dep001_risk_register_documentation() {
    let client_root = get_client_root();
    let reg_path = client_root.join("docs/dependency-risk-register.md");
    let content = fs::read_to_string(&reg_path).expect("read dependency-risk-register.md");

    assert!(
        content.contains("Review date: 2026-11-11"),
        "Risk register must have review date 2026-11-11"
    );
    assert!(
        content.contains("DEP-001"),
        "Risk register must mention DEP-001"
    );
    assert!(
        content.contains("RUSTSEC-2024-0429"),
        "Risk register must mention glib advisory RUSTSEC-2024-0429"
    );
    assert!(
        content.contains("RUSTSEC-2021-0145"),
        "Risk register must mention atty advisory RUSTSEC-2021-0145"
    );
}

#[cfg(target_os = "linux")]
#[test]
fn test_dep001_variant_str_iter_runtime_soundness() {
    use gtk::glib::prelude::*;

    // 1. Forward iteration through array of strings (RUSTSEC-2024-0429 regression test)
    let expected = vec!["camellia", "remote", "desktop", "safe-variant"];
    let variant = expected.as_slice().to_variant();
    let iter = variant
        .array_iter_str()
        .expect("array_iter_str should succeed on string array variant");
    assert_eq!(
        iter.len(),
        expected.len(),
        "ExactSizeIterator length must match expected slice size"
    );

    let collected: Vec<&str> = iter.collect();
    assert_eq!(
        collected, expected,
        "VariantStrIter forward iteration must yield correct string references"
    );

    // 2. DoubleEndedIterator (rev)
    let rev_iter = variant
        .array_iter_str()
        .expect("array_iter_str should succeed");
    let rev_collected: Vec<&str> = rev_iter.rev().collect();
    let expected_rev: Vec<&str> = expected.iter().rev().copied().collect();
    assert_eq!(
        rev_collected, expected_rev,
        "VariantStrIter reverse iteration must match reversed slice"
    );

    // 3. Boundary test: empty string array
    let empty_items: Vec<&str> = Vec::new();
    let empty_variant = empty_items.as_slice().to_variant();
    let mut empty_iter = empty_variant
        .array_iter_str()
        .expect("empty array_iter_str should succeed");
    assert_eq!(empty_iter.len(), 0);
    assert_eq!(empty_iter.next(), None);

    // 4. Boundary test: type mismatch rejection on non-string array
    let int_variant = 42i32.to_variant();
    assert!(
        int_variant.array_iter_str().is_err(),
        "array_iter_str must fail closed on non-string-array variant"
    );
}
