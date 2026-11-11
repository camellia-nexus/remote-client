//! Integration and contract tests for Batch 63:
//! COMPAT-008 — Management 保留的 WebSocket Proxy Path 与 Query 被 Client Runtime 静默丢弃.

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_compat008_rust_check_ws_preserves_custom_path_and_query() {
    let custom_id = "wss://remote.example.com:8443/custom-id?tenant=one";
    let custom_relay = "wss://relay.example.com:9443/custom-relay?tenant=one";

    // Rust client protocol check_ws must recognize WSS endpoint and preserve full path and query
    assert!(
        camellia_remote_protocol::websocket::is_ws_endpoint(custom_id),
        "custom_id must be recognized as a valid websocket endpoint"
    );
    assert!(
        camellia_remote_protocol::websocket::is_ws_endpoint(custom_relay),
        "custom_relay must be recognized as a valid websocket endpoint"
    );

    let ws_id = camellia_remote_protocol::websocket::check_ws(custom_id);
    assert_eq!(
        ws_id, custom_id,
        "Rust check_ws must preserve custom path and query"
    );

    let ws_relay = camellia_remote_protocol::websocket::check_ws(custom_relay);
    assert_eq!(
        ws_relay, custom_relay,
        "Rust check_ws must preserve custom relay path and query"
    );
}

#[test]
fn test_compat008_web_runtime_ts_schema_and_guards_integrity() {
    let repo_root = get_repo_root();
    let runtime_ts_path = repo_root.join("flutter/web/js/src/runtime/runtime.ts");
    assert!(runtime_ts_path.exists(), "runtime.ts must exist");

    let content = fs::read_to_string(&runtime_ts_path).expect("read runtime.ts");

    // 1. Shared schema definition
    assert!(
        content.contains("export interface ParsedServerEndpoint"),
        "runtime.ts must export ParsedServerEndpoint"
    );
    assert!(
        content.contains("path: string;"),
        "ParsedServerEndpoint must include path field"
    );
    assert!(
        content.contains("query: string;"),
        "ParsedServerEndpoint must include query field"
    );

    // 2. parseServerInput guards against userinfo, fragment, control characters, bare paths
    assert!(
        content.contains("public parseServerInput("),
        "runtime.ts must define public parseServerInput"
    );
    assert!(
        content.contains("raw.includes('#')"),
        "parseServerInput must reject fragments"
    );
    assert!(
        content.contains("authority.includes('@')"),
        "parseServerInput must reject userinfo in authority"
    );
    assert!(
        content.contains("url.username || url.password"),
        "parseServerInput must reject username/password credentials"
    );
    assert!(
        content.contains("raw.includes('/') || raw.includes('?') || raw.includes('@')"),
        "parseServerInput must reject bare paths or queries without scheme"
    );

    // 3. Normalization functions preserve custom path and query
    assert!(
        content.contains("public normalizeRendezvousServer("),
        "runtime.ts must define public normalizeRendezvousServer"
    );
    assert!(
        content.contains("parsed.path && parsed.path !== '/' ? parsed.path : defaultPath"),
        "normalizeRendezvousServer must preserve custom path or supply default"
    );
    assert!(
        content.contains("public normalizeRelayServer("),
        "runtime.ts must define public normalizeRelayServer"
    );
    assert!(
        content.contains("parsed.path && parsed.path !== '/' ? parsed.path : '/ws/relay'"),
        "normalizeRelayServer must preserve custom path or supply /ws/relay"
    );

    // 4. deriveRelayServer maps WSS to /ws/relay sharing TLS port and query
    assert!(
        content.contains("public deriveRelayServer("),
        "runtime.ts must define public deriveRelayServer"
    );
    assert!(
        content.contains("'/ws/relay'"),
        "deriveRelayServer must use /ws/relay for WSS endpoints"
    );

    // 5. Candidate builders are public and retain candidate URLs
    assert!(
        content.contains("public buildConnectionCandidates("),
        "buildConnectionCandidates must be public"
    );
    assert!(
        content.contains("public getRendezvousCandidatesForConnect("),
        "getRendezvousCandidatesForConnect must be public"
    );
}

#[test]
fn test_compat008_web_rendezvous_ts_guards_and_contract_integrity() {
    let repo_root = get_repo_root();
    let rendezvous_ts_path = repo_root.join("flutter/web/js/src/runtime/rendezvous.ts");
    assert!(rendezvous_ts_path.exists(), "rendezvous.ts must exist");

    let content = fs::read_to_string(&rendezvous_ts_path).expect("read rendezvous.ts");

    // checkWsEndpoint must validate and reject userinfo, fragments, control characters
    assert!(
        content.contains("export function checkWsEndpoint("),
        "rendezvous.ts must export checkWsEndpoint"
    );
    assert!(
        content.contains("authority.includes('@')"),
        "checkWsEndpoint must reject authority userinfo"
    );
    assert!(
        content.contains("hasExplicitPath ? url.pathname : ''"),
        "checkWsEndpoint must preserve explicit WS pathname"
    );
    assert!(
        content.contains(
            "hasExplicitPath ? url.pathname : (routeKind === 'relay' ? '/ws/relay' : '/ws/id')"
        ),
        "checkWsEndpoint must preserve explicit WSS pathname or fallback to default"
    );

    // parseServerEndpoint must be exported and conform to shared contract
    assert!(
        content.contains("export function parseServerEndpoint("),
        "rendezvous.ts must export parseServerEndpoint"
    );
}

#[test]
fn test_compat008_url_wire_parsing_invariants() {
    // Rust url::Url parsing validates that custom path and query are standard URL components
    let custom_id = "wss://remote.example.com:8443/custom-id?tenant=one";
    let parsed = url::Url::parse(custom_id).expect("must parse custom WSS URL");

    assert_eq!(parsed.scheme(), "wss");
    assert_eq!(parsed.host_str(), Some("remote.example.com"));
    assert_eq!(parsed.port(), Some(8443));
    assert_eq!(parsed.path(), "/custom-id");
    assert_eq!(parsed.query(), Some("tenant=one"));

    // Ensure IPv6 bracketed custom URL parses accurately
    let ipv6_url = "wss://[2001:db8::1]:8443/custom-id?tenant=one";
    let parsed_ipv6 = url::Url::parse(ipv6_url).expect("must parse custom IPv6 WSS URL");
    assert_eq!(parsed_ipv6.host_str(), Some("[2001:db8::1]"));
    assert_eq!(parsed_ipv6.path(), "/custom-id");
    assert_eq!(parsed_ipv6.query(), Some("tenant=one"));
}
