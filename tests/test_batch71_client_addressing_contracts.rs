//! Contract tests for Batch 71 Client Hardening:
//! PROTO-001 — Socket Address Deserialization Fail-Closed Hardening
//!
//! Verifies:
//! - Fail-closed rejection of empty, truncated (1-6, 17 bytes), oversized (>= 19 bytes), and port 0 payloads.
//! - Behavior of `try_decode_addr` (required) and `try_decode_optional_addr` (optional).
//! - Deduplication state protection (`LAST_MSG` and `LAST_RELAY_MSG`) against malformed address pollution.
//! - Complete elimination of deprecated `AddrMangle::decode` across all client production call sites.

#![deny(warnings)]

use camellia_remote_protocol::{AddrMangle, AddressDecodeError};
use std::fs;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_proto001_fail_closed_required_addr_deserialization() {
    // 1. Valid IPv4 round-trip
    let v4 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 42)), 21116);
    let enc_v4 = AddrMangle::encode(v4);
    let dec_v4 = AddrMangle::try_decode_addr(&enc_v4).expect("valid IPv4 must decode");
    assert_eq!(dec_v4, v4);

    // 2. Valid IPv6 round-trip
    let v6 = SocketAddr::new(
        IpAddr::V6("2001:db8:85a3::8a2e:370:7334".parse::<Ipv6Addr>().unwrap()),
        21118,
    );
    let enc_v6 = AddrMangle::encode(v6);
    let dec_v6 = AddrMangle::try_decode_addr(&enc_v6).expect("valid IPv6 must decode");
    assert_eq!(dec_v6, v6);

    // 3. Empty payload -> AddressDecodeError::Empty
    assert_eq!(
        AddrMangle::try_decode_addr(&[]),
        Err(AddressDecodeError::Empty)
    );

    // 4. Truncated payloads (1 to 6 bytes) -> AddressDecodeError::Malformed
    for len in 1..=6 {
        let payload = vec![0x42u8; len];
        assert_eq!(
            AddrMangle::try_decode_addr(&payload),
            Err(AddressDecodeError::Malformed),
            "payload of length {} must be rejected as Malformed",
            len
        );
    }

    // 5. Truncated payload: 17 bytes (between valid IPv4 <= 16 and IPv6 == 18) -> Malformed
    let payload_17 = vec![0x7fu8; 17];
    assert_eq!(
        AddrMangle::try_decode_addr(&payload_17),
        Err(AddressDecodeError::Malformed),
        "17-byte payload must be rejected as Malformed"
    );

    // 6. Oversized payloads (>= 19 bytes) -> Malformed
    for len in [19, 20, 24, 32, 64, 128] {
        let payload = vec![0x55u8; len];
        assert_eq!(
            AddrMangle::try_decode_addr(&payload),
            Err(AddressDecodeError::Malformed),
            "oversized payload of length {} must be rejected as Malformed",
            len
        );
    }

    // 7. Port 0 payload (IPv6 with 16-byte IP and 2-byte port 0) -> Malformed
    let mut ipv6_port_zero = vec![0u8; 18];
    ipv6_port_zero[15] = 1; // ::1
    ipv6_port_zero[16] = 0; // port high byte
    ipv6_port_zero[17] = 0; // port low byte
    assert_eq!(
        AddrMangle::try_decode_addr(&ipv6_port_zero),
        Err(AddressDecodeError::Malformed),
        "IPv6 payload with port 0 must be rejected as Malformed"
    );
}

#[test]
fn test_proto001_fail_closed_optional_addr_deserialization() {
    // 1. Empty payload represents omitted/absent optional field -> Ok(None)
    assert_eq!(
        AddrMangle::try_decode_optional_addr(&[]),
        Ok(None),
        "empty optional payload must decode cleanly to Ok(None)"
    );

    // 2. Valid IPv4/IPv6 -> Ok(Some(addr))
    let v4 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)), 8080);
    let enc_v4 = AddrMangle::encode(v4);
    assert_eq!(
        AddrMangle::try_decode_optional_addr(&enc_v4),
        Ok(Some(v4)),
        "valid encoded IPv4 must decode to Ok(Some(v4))"
    );

    let v6 = SocketAddr::new(IpAddr::V6("::1".parse::<Ipv6Addr>().unwrap()), 9090);
    let enc_v6 = AddrMangle::encode(v6);
    assert_eq!(
        AddrMangle::try_decode_optional_addr(&enc_v6),
        Ok(Some(v6)),
        "valid encoded IPv6 must decode to Ok(Some(v6))"
    );

    // 3. Corrupted non-empty payloads -> Err(AddressDecodeError::Malformed)
    for len in 1..=6 {
        let bad_bytes = vec![0xabu8; len];
        assert_eq!(
            AddrMangle::try_decode_optional_addr(&bad_bytes),
            Err(AddressDecodeError::Malformed),
            "corrupted optional bytes of length {} must fail closed",
            len
        );
    }

    // 17-byte payload
    assert_eq!(
        AddrMangle::try_decode_optional_addr(&[0xff; 17]),
        Err(AddressDecodeError::Malformed),
        "17-byte optional payload must fail closed"
    );

    // >= 19 bytes
    for len in [19, 20, 32] {
        assert_eq!(
            AddrMangle::try_decode_optional_addr(&vec![0xee; len]),
            Err(AddressDecodeError::Malformed),
            "oversized optional bytes of length {} must fail closed",
            len
        );
    }

    // Port 0 optional payload
    let mut ipv6_port_zero = vec![0u8; 18];
    ipv6_port_zero[0] = 0x20; // 2000::
    assert_eq!(
        AddrMangle::try_decode_optional_addr(&ipv6_port_zero),
        Err(AddressDecodeError::Malformed),
        "optional IPv6 payload with port 0 must fail closed"
    );
}

#[test]
fn test_proto001_deduplication_state_resilience() {
    // Simulates the exact state protection pattern used in rendezvous_mediator.rs:
    // LAST_MSG / LAST_RELAY_MSG: Mutex<(SocketAddr, Instant)>
    // A malformed message MUST NOT update or corrupt the deduplication state.

    struct DeduplicationState {
        last_seen: (SocketAddr, Instant),
    }

    impl DeduplicationState {
        fn new(initial_addr: SocketAddr) -> Self {
            Self {
                last_seen: (initial_addr, Instant::now() - Duration::from_secs(10)),
            }
        }

        /// Process incoming message bytes under the fail-closed PROTO-001 pattern.
        /// Returns Ok(true) if processed, Ok(false) if deduplicated, Err on decode failure.
        fn handle_message(&mut self, raw_addr_bytes: &[u8]) -> Result<bool, AddressDecodeError> {
            // STEP 1: Decode fail-closed BEFORE mutating state
            let addr = AddrMangle::try_decode_addr(raw_addr_bytes)?;

            // STEP 2: Only reached if decoding succeeded
            let (last_addr, last_time) = self.last_seen;
            self.last_seen = (addr, Instant::now());

            if last_addr == addr && last_time.elapsed().as_millis() < 100 {
                return Ok(false); // skipped duplicate
            }
            Ok(true) // accepted fresh message
        }
    }

    let initial_peer: SocketAddr = "192.168.1.1:21116".parse().unwrap();
    let mut state = DeduplicationState::new(initial_peer);
    let original_time = state.last_seen.1;

    // 1. Send malformed payloads -> must fail with error and preserve original state
    let malformed_cases: Vec<Vec<u8>> = vec![
        vec![],         // Empty
        vec![0x01],     // Truncated (1 byte)
        vec![0x02; 6],  // Truncated (6 bytes)
        vec![0x03; 17], // Truncated (17 bytes)
        vec![0x04; 19], // Oversized (19 bytes)
        vec![0x05; 32], // Oversized (32 bytes)
        vec![0; 18],    // Port 0 (18 bytes)
    ];

    for malformed in malformed_cases {
        let result = state.handle_message(&malformed);
        assert!(
            result.is_err(),
            "malformed payload must fail decoding before state mutation"
        );
        // State must remain uncorrupted (NOT replaced with [::]:0 or corrupted timestamp)
        assert_eq!(
            state.last_seen.0, initial_peer,
            "deduplication socket_addr must not be mutated on decode failure"
        );
        assert_eq!(
            state.last_seen.1, original_time,
            "deduplication timestamp must not be updated on decode failure"
        );
    }

    // 2. Send valid message from Peer B -> state successfully updates
    let peer_b: SocketAddr = "10.0.0.2:21118".parse().unwrap();
    let enc_b = AddrMangle::encode(peer_b);
    let result = state
        .handle_message(&enc_b)
        .expect("valid message must succeed");
    assert!(result, "fresh message must be accepted");
    assert_eq!(state.last_seen.0, peer_b);
    let _time_b = state.last_seen.1;

    // 3. Send duplicate from Peer B within 100ms -> accepted as duplicate (returns false)
    let dup_result = state
        .handle_message(&enc_b)
        .expect("valid duplicate must succeed");
    assert!(!dup_result, "immediate duplicate must be skipped");
    assert_eq!(state.last_seen.0, peer_b);
    let time_after_dup = state.last_seen.1;

    // 4. Send another malformed message -> state remains Peer B, not corrupted
    assert!(state.handle_message(&[0x99; 5]).is_err());
    assert_eq!(
        state.last_seen.0, peer_b,
        "peer_b state must be preserved after rejected malformed message"
    );
    assert_eq!(
        state.last_seen.1, time_after_dup,
        "timestamp must not be overwritten by malformed message"
    );
}

#[test]
fn test_proto001_production_call_sites_structural_hardening() {
    let root = get_client_root();
    let client_rs_path = root.join("src/client.rs");
    let mediator_rs_path = root.join("src/rendezvous_mediator.rs");

    assert!(client_rs_path.exists(), "src/client.rs must exist");
    assert!(
        mediator_rs_path.exists(),
        "src/rendezvous_mediator.rs must exist"
    );

    let client_rs = fs::read_to_string(&client_rs_path).expect("read src/client.rs");
    let mediator_rs =
        fs::read_to_string(&mediator_rs_path).expect("read src/rendezvous_mediator.rs");

    // ZERO occurrences of deprecated AddrMangle::decode across both files
    assert!(
        !client_rs.contains("AddrMangle::decode("),
        "src/client.rs must NOT call deprecated AddrMangle::decode"
    );
    assert!(
        !mediator_rs.contains("AddrMangle::decode("),
        "src/rendezvous_mediator.rs must NOT call deprecated AddrMangle::decode"
    );

    // src/client.rs must call try_decode_addr and try_decode_optional_addr
    assert!(
        client_rs.contains("AddrMangle::try_decode_addr(&ph.socket_addr)"),
        "src/client.rs must call try_decode_addr for punch hole socket_addr"
    );
    assert!(
        client_rs.contains("AddrMangle::try_decode_optional_addr(&ph.socket_addr_v6)"),
        "src/client.rs must call try_decode_optional_addr for punch hole socket_addr_v6"
    );
    assert!(
        client_rs.contains("AddrMangle::try_decode_optional_addr(&rr.socket_addr_v6)"),
        "src/client.rs must call try_decode_optional_addr for relay socket_addr_v6"
    );

    // src/rendezvous_mediator.rs must call try_decode_addr and try_decode_optional_addr
    assert!(
        mediator_rs.contains("AddrMangle::try_decode_addr(&rr.socket_addr)"),
        "src/rendezvous_mediator.rs must call try_decode_addr in handle_request_relay"
    );
    assert!(
        mediator_rs.contains("AddrMangle::try_decode_addr(&socket_addr)"),
        "src/rendezvous_mediator.rs must call try_decode_addr in create_relay"
    );
    assert!(
        mediator_rs.contains("AddrMangle::try_decode_addr(&fla.socket_addr)"),
        "src/rendezvous_mediator.rs must call try_decode_addr in handle_intranet"
    );
    assert!(
        mediator_rs.contains("AddrMangle::try_decode_addr(&ph.socket_addr)"),
        "src/rendezvous_mediator.rs must call try_decode_addr in handle_punch_hole"
    );
    assert!(
        mediator_rs.contains("AddrMangle::try_decode_optional_addr("),
        "src/rendezvous_mediator.rs must call try_decode_optional_addr for IPv6"
    );

    // Deduplication state guard ordering: try_decode_addr must appear BEFORE LAST_RELAY_MSG.lock()
    let rr_decode_pos = mediator_rs
        .find("AddrMangle::try_decode_addr(&rr.socket_addr)")
        .expect("must find rr try_decode_addr");
    let rr_lock_pos = mediator_rs
        .find("LAST_RELAY_MSG.lock()")
        .expect("must find LAST_RELAY_MSG.lock()");
    assert!(
        rr_decode_pos < rr_lock_pos,
        "try_decode_addr must be executed before LAST_RELAY_MSG is locked/updated"
    );

    // Deduplication state guard ordering: try_decode_addr must appear BEFORE LAST_MSG.lock() in handle_intranet
    let intranet_decode_pos = mediator_rs
        .find("AddrMangle::try_decode_addr(&fla.socket_addr)")
        .expect("must find fla try_decode_addr");
    let intranet_lock_pos = mediator_rs
        .find("LAST_MSG.lock()")
        .expect("must find LAST_MSG.lock()");
    assert!(
        intranet_decode_pos < intranet_lock_pos,
        "try_decode_addr must be executed before LAST_MSG is locked/updated in handle_intranet"
    );

    // No raw byte logging in error/warn messages
    assert!(
        !mediator_rs.contains("log::error!(\"{:?}\", rr.socket_addr"),
        "must not log raw bytes"
    );
    assert!(
        !mediator_rs.contains("log::error!(\"{:?}\", ph.socket_addr"),
        "must not log raw bytes"
    );
}
