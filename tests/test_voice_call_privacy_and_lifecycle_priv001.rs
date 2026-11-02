use camellia_remote::server::voice_call_manager::{
    generate_call_id, next_voice_call_generation, VoiceCallManager,
};
use std::collections::HashSet;

#[test]
fn test_voice_call_single_owner_lifecycle() {
    let manager = VoiceCallManager::new();

    // No call active initially
    assert_eq!(manager.get_owner(), None);

    let conn_a = 101;
    let call_id_a = generate_call_id();
    let gen_a = next_voice_call_generation();

    // Register connection A as call owner
    let reg_a = manager.try_register_call(conn_a, call_id_a, gen_a);
    assert!(reg_a.is_ok());
    let owner_a = manager.get_owner().expect("Owner A should be active");
    assert_eq!(owner_a.conn_id, conn_a);
    assert_eq!(owner_a.call_id, call_id_a);
    assert_eq!(owner_a.generation, gen_a);
    assert!(manager.is_owner(conn_a));

    // Connection B attempts to start/register call while A is active -> Rejected with busy
    let conn_b = 202;
    let call_id_b = generate_call_id();
    let gen_b = next_voice_call_generation();

    let reg_b = manager.try_register_call(conn_b, call_id_b, gen_b);
    assert_eq!(reg_b, Err("busy"));
    assert!(!manager.is_owner(conn_b));

    // Connection B disconnects or tries to release call -> Ignored, A remains active owner
    assert!(!manager.release_call_if_owner(conn_b));
    let owner_still_a = manager.get_owner().expect("Owner A must remain active");
    assert_eq!(owner_still_a.conn_id, conn_a);

    // Connection A releases call -> Successfully released
    assert!(manager.release_call_if_owner(conn_a));
    assert_eq!(manager.get_owner(), None);
    assert!(!manager.is_owner(conn_a));

    // Now Connection B can successfully register
    let reg_b_second = manager.try_register_call(conn_b, call_id_b, gen_b);
    assert!(reg_b_second.is_ok());
    assert!(manager.is_owner(conn_b));

    // Cleanup
    assert!(manager.release_call_if_owner(conn_b));
    assert_eq!(manager.get_owner(), None);
}

#[test]
fn test_voice_call_id_uniqueness_and_entropy() {
    let mut ids = HashSet::new();
    let count = 2000;
    for _ in 0..count {
        let id = generate_call_id();
        assert_ne!(id, 0, "Call ID must never be zero");
        assert!(ids.insert(id), "Duplicate call ID generated: {}", id);
    }
}

#[test]
fn test_voice_call_generation_monotonicity() {
    let gen1 = next_voice_call_generation();
    let gen2 = next_voice_call_generation();
    let gen3 = next_voice_call_generation();
    assert!(gen2 > gen1, "Generations must be strictly monotonic");
    assert!(gen3 > gen2, "Generations must be strictly monotonic");
}
