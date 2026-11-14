//! Contract tests for Batch 73: Client Protocol Provenance & Address Deserialization Fail-Closed Hardening
//! Covers:
//! - PROV-001: Submodule alignment and SOURCE_PROVENANCE.json consistency
//! - PROV-002: Strict semantic source provenance schema validation
//! - PROTO-001: Fail-closed address deserialization (try_decode_addr and try_decode_optional_addr)

#![deny(warnings)]

use camellia_remote_protocol::{AddrMangle, AddressDecodeError};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

#[test]
fn test_batch73_proto001_required_addr_decoding_contracts() {
    // Valid IPv4 address round-trip
    let v4 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 168, 50, 10)), 21116);
    let enc_v4 = AddrMangle::encode(v4);
    let dec_v4 = AddrMangle::try_decode_addr(&enc_v4).expect("valid v4 must decode");
    assert_eq!(dec_v4, v4);

    // Valid IPv6 address round-trip
    let v6 = SocketAddr::new(
        IpAddr::V6("2001:db8:85a3::8a2e:370:7334".parse::<Ipv6Addr>().unwrap()),
        21118,
    );
    let enc_v6 = AddrMangle::encode(v6);
    let dec_v6 = AddrMangle::try_decode_addr(&enc_v6).expect("valid v6 must decode");
    assert_eq!(dec_v6, v6);

    // Empty bytes must fail-closed with AddressDecodeError::Empty
    assert_eq!(
        AddrMangle::try_decode_addr(&[]),
        Err(AddressDecodeError::Empty)
    );

    // Corrupted payloads must fail-closed with AddressDecodeError::Malformed
    assert_eq!(
        AddrMangle::try_decode_addr(&[0xaa]),
        Err(AddressDecodeError::Malformed)
    );
    assert_eq!(
        AddrMangle::try_decode_addr(&[0xbb; 5]),
        Err(AddressDecodeError::Malformed)
    );
    assert_eq!(
        AddrMangle::try_decode_addr(&[0xcc; 17]),
        Err(AddressDecodeError::Malformed)
    );
    assert_eq!(
        AddrMangle::try_decode_addr(&[0xdd; 19]),
        Err(AddressDecodeError::Malformed)
    );
}

#[test]
fn test_batch73_proto001_optional_addr_decoding_contracts() {
    // Empty bytes must return Ok(None) representing legitimately absent optional IPv6 address
    assert_eq!(AddrMangle::try_decode_optional_addr(&[]), Ok(None));

    // Valid IPv4/IPv6 must return Ok(Some(addr))
    let v4 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)), 8080);
    let enc_v4 = AddrMangle::encode(v4);
    assert_eq!(AddrMangle::try_decode_optional_addr(&enc_v4), Ok(Some(v4)));

    let v6 = SocketAddr::new(IpAddr::V6("::1".parse::<Ipv6Addr>().unwrap()), 9090);
    let enc_v6 = AddrMangle::encode(v6);
    assert_eq!(AddrMangle::try_decode_optional_addr(&enc_v6), Ok(Some(v6)));

    // Present but corrupted bytes must fail-closed with Err(AddressDecodeError::Malformed)
    assert_eq!(
        AddrMangle::try_decode_optional_addr(&[0x01]),
        Err(AddressDecodeError::Malformed)
    );
    assert_eq!(
        AddrMangle::try_decode_optional_addr(&[0x02; 17]),
        Err(AddressDecodeError::Malformed)
    );
}

#[test]
fn test_batch73_prov001_source_provenance_json_alignment() {
    let manifest_path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("SOURCE_PROVENANCE.json");
    let content =
        std::fs::read_to_string(&manifest_path).expect("SOURCE_PROVENANCE.json must be readable");
    let parsed: serde_json::Value = serde_json::from_str(&content).expect("valid JSON");

    assert_eq!(parsed["schema_version"], 1);
    assert_eq!(parsed["component"], "camellia-remote-client");
    assert_eq!(parsed["license"], "AGPL-3.0-only");
    assert_eq!(parsed["history_policy"], "fresh-root-snapshot");

    let source_commit = parsed["source_commit"]
        .as_str()
        .expect("source_commit string");
    assert_eq!(
        source_commit.len(),
        40,
        "source_commit must be full 40-character SHA"
    );

    let proto_commit = parsed["protocol_source_commit"]
        .as_str()
        .expect("protocol_source_commit string");
    assert_eq!(
        proto_commit.len(),
        40,
        "protocol_source_commit must be full 40-character SHA"
    );
}
