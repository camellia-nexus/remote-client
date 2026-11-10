//! Integration and contract tests for Batch 57:
//! - BUILD-015: Advanced Multi-Language CodeQL Matrix & SARIF Security Analysis

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_build015_codeql_workflow_and_config_integrity() {
    let repo_root = get_repo_root();
    let workflow_path = repo_root.join(".github/workflows/codeql.yml");
    let config_path = repo_root.join(".github/codeql/codeql-config.yml");

    assert!(workflow_path.exists(), "codeql.yml must exist");
    assert!(config_path.exists(), "codeql-config.yml must exist");

    let workflow_content = fs::read_to_string(&workflow_path).expect("read codeql.yml");
    let config_content = fs::read_to_string(&config_path).expect("read codeql-config.yml");

    // All 7 required languages must be in the matrix
    let required_languages = [
        "actions",
        "c-cpp",
        "java-kotlin",
        "javascript-typescript",
        "python",
        "rust",
        "swift",
    ];

    for lang in &required_languages {
        assert!(
            workflow_content.contains(&format!("language: {lang}")),
            "CodeQL matrix missing language: {}",
            lang
        );
    }

    // Must specify SARIF category
    assert!(
        workflow_content.contains("category: \"/language:${{ matrix.language }}\""),
        "{}",
        "SARIF category must be specified as /language:${{ matrix.language }}"
    );

    // CodeQL config must ignore generated bridge files
    assert!(
        config_content.contains("bridge_generated"),
        "codeql-config.yml must ignore bridge_generated files"
    );
    assert!(
        config_content.contains("generated_bridge"),
        "codeql-config.yml must ignore generated_bridge files"
    );

    // Swift bridge mocks must export required entry points
    assert!(
        workflow_content.contains("camellia_remote_core_main"),
        "codeql.yml must mock camellia_remote_core_main for Swift runner linking"
    );
    assert!(
        workflow_content.contains("handle_applicationShouldOpenUntitledFile"),
        "codeql.yml must mock handle_applicationShouldOpenUntitledFile for Swift runner linking"
    );
}

#[test]
fn test_build015_codeql_actions_immutable_sha_pinning() {
    let repo_root = get_repo_root();
    let workflow_path = repo_root.join(".github/workflows/codeql.yml");
    let workflow_content = fs::read_to_string(&workflow_path).expect("read codeql.yml");

    let codeql_sha = "9418214df1f2c4b8128c770156c409013b07d6b9";
    let checkout_sha = "3d3c42e5aac5ba805825da76410c181273ba90b1";

    assert!(
        workflow_content.contains(&format!("github/codeql-action/init@{codeql_sha}")),
        "codeql init action must be pinned to immutable SHA"
    );
    assert!(
        workflow_content.contains(&format!("github/codeql-action/analyze@{codeql_sha}")),
        "codeql analyze action must be pinned to immutable SHA"
    );
    assert!(
        workflow_content.contains(&format!("actions/checkout@{checkout_sha}")),
        "checkout action must be pinned to immutable SHA"
    );
}

#[test]
fn test_build015_codeql_permissions_and_security_events() {
    let repo_root = get_repo_root();
    let workflow_path = repo_root.join(".github/workflows/codeql.yml");
    let workflow_content = fs::read_to_string(&workflow_path).expect("read codeql.yml");

    assert!(
        workflow_content.contains("security-events: write"),
        "workflow must declare security-events: write"
    );
    assert!(
        workflow_content.contains("contents: read"),
        "workflow must declare contents: read"
    );
    assert!(
        workflow_content.contains("actions: read"),
        "workflow must declare actions: read"
    );
}
