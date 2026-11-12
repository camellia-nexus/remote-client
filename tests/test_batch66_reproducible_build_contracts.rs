//! Integration and contract tests for Batch 66:
//! BUILD-003 — Client 可复现 Native 构建与 SOURCE_DATE_EPOCH 约束闭环.

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_batch66_build_date_format_and_utc_standardization() {
    let build_date = camellia_remote::BUILD_DATE;
    assert!(
        build_date.ends_with(" UTC"),
        "BUILD_DATE '{build_date}' must end with ' UTC'"
    );
    assert_eq!(
        build_date.len(),
        20,
        "BUILD_DATE '{build_date}' length must be 20 characters (YYYY-MM-DD HH:MM UTC)"
    );

    // Validate format: YYYY-MM-DD HH:MM UTC
    let parts: Vec<&str> = build_date.split(' ').collect();
    assert_eq!(
        parts.len(),
        3,
        "BUILD_DATE must have 3 space-separated parts"
    );
    assert_eq!(parts[2], "UTC", "Third part must be 'UTC'");

    let date_parts: Vec<&str> = parts[0].split('-').collect();
    assert_eq!(date_parts.len(), 3, "Date must have year-month-day");
    let year: u32 = date_parts[0].parse().expect("valid year");
    let month: u32 = date_parts[1].parse().expect("valid month");
    let day: u32 = date_parts[2].parse().expect("valid day");
    assert!(
        (1970..=2100).contains(&year),
        "Year {year} out of expected range"
    );
    assert!((1..=12).contains(&month), "Month {month} out of range");
    assert!((1..=31).contains(&day), "Day {day} out of range");

    let time_parts: Vec<&str> = parts[1].split(':').collect();
    assert_eq!(time_parts.len(), 2, "Time must have hour:minute");
    let hour: u32 = time_parts[0].parse().expect("valid hour");
    let minute: u32 = time_parts[1].parse().expect("valid minute");
    assert!((0..=23).contains(&hour), "Hour {hour} out of range");
    assert!((0..=59).contains(&minute), "Minute {minute} out of range");
}

#[test]
fn test_batch66_version_constant_matches_manifest() {
    let version = camellia_remote::VERSION;
    let manifest_version = env!("CARGO_PKG_VERSION");
    assert_eq!(
        version, manifest_version,
        "VERSION constant must match CARGO_PKG_VERSION"
    );

    let semver_parts: Vec<&str> = version.split('.').collect();
    assert_eq!(
        semver_parts.len(),
        3,
        "VERSION must be a 3-component SemVer (MAJOR.MINOR.PATCH)"
    );
    for part in semver_parts {
        let n: u32 = part.parse().expect("valid semver integer component");
        assert!(n < 1000000, "Component {n} in sane bounds");
    }
}

#[test]
fn test_batch66_lexicographical_chronological_ordering() {
    // Invariant: Because YYYY-MM-DD HH:MM UTC is zero-padded fixed-width,
    // string comparison .cmp() strictly mirrors chronological ordering.
    // This is relied upon by is_installed_lower_version() on Windows.
    let earlier = "2026-11-11 23:59 UTC";
    let later = "2026-11-12 00:00 UTC";
    assert!(
        later > earlier,
        "Lexicographical ordering must reflect chronological ordering"
    );

    let year_change_early = "2025-12-31 23:59 UTC";
    let year_change_late = "2026-01-01 00:00 UTC";
    assert!(year_change_late > year_change_early);
}

#[test]
fn test_batch66_src_version_rs_tracked_and_unignored() {
    let root = get_client_root();
    let version_rs = root.join("src/version.rs");
    assert!(version_rs.exists(), "src/version.rs must exist");

    let client_gi = fs::read_to_string(root.join(".gitignore")).expect("read client .gitignore");
    assert!(
        !client_gi.contains("src/version.rs") && !client_gi.contains("/src/version.rs"),
        "client .gitignore must not ignore src/version.rs"
    );

    let content = fs::read_to_string(&version_rs).expect("read src/version.rs");
    assert!(
        content.contains("pub const VERSION: &str = env!(\"CARGO_PKG_VERSION\");"),
        "src/version.rs must define VERSION via env!(\"CARGO_PKG_VERSION\")"
    );
    assert!(
        content.contains("option_env!(\"CAMELLIA_BUILD_DATE\")"),
        "src/version.rs must define BUILD_DATE via option_env!(\"CAMELLIA_BUILD_DATE\")"
    );
    assert!(
        content.contains("\"1970-01-01 00:00 UTC\""),
        "src/version.rs must fall back to 1970-01-01 00:00 UTC"
    );
}

#[test]
fn test_batch66_build_rs_invokes_protocol_gen_version() {
    let root = get_client_root();
    let build_rs = root.join("build.rs");
    assert!(build_rs.exists(), "build.rs must exist");

    let content = fs::read_to_string(&build_rs).expect("read build.rs");
    assert!(
        content.contains("camellia_remote_protocol::gen_version();"),
        "build.rs must call camellia_remote_protocol::gen_version()"
    );
}

#[test]
fn test_batch66_sync_version_script_contracts() {
    let root = get_client_root();
    let sync_sh = root.join(".github/scripts/sync-version.sh");
    assert!(
        sync_sh.exists(),
        ".github/scripts/sync-version.sh must exist"
    );

    let content = fs::read_to_string(&sync_sh).expect("read sync-version.sh");
    assert!(
        content.contains("source date epoch must be a non-negative decimal integer"),
        "sync-version.sh must validate source date epoch"
    );
    assert!(
        content.contains("%Y-%m-%d %H:%M UTC"),
        "sync-version.sh must format build date as %Y-%m-%d %H:%M UTC"
    );
    assert!(
        content.contains("GITHUB_ENV"),
        "sync-version.sh must support GITHUB_ENV export"
    );
    assert!(
        content.contains("option_env!(\"CAMELLIA_BUILD_DATE\")"),
        "sync-version.sh must preserve tracked src/version.rs template"
    );
}

#[test]
fn test_batch66_msi_preprocess_build_date_regex() {
    let root = get_client_root();
    let preprocess_py = root.join("res/msi/preprocess.py");
    assert!(preprocess_py.exists(), "res/msi/preprocess.py must exist");

    let content = fs::read_to_string(&preprocess_py).expect("read preprocess.py");
    assert!(
        content.contains("(?: UTC)?"),
        "res/msi/preprocess.py BUILD_DATE regex must support (?: UTC)?"
    );
}
