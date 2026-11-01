use camellia_remote::{
    capability::CapabilityVault,
    common::get_api_access_token,
    flutter_ffi::{
        main_account_logout, main_consume_capability_handle, main_create_capability_handle,
    },
};
use camellia_remote_protocol::config::LocalConfig;
use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Barrier,
    },
    thread,
    time::Duration,
};

#[test]
fn test_stress_capability_vault_100_threads_single_winner() {
    let vault = Arc::new(CapabilityVault::new());

    // Run 100 rounds of 100 threads contending for a single handle
    for round in 0..100 {
        let canary_secret = format!("CANARY_SECRET_ROUND_{round}");
        let handle = vault.create_capability("peer_target_100", &canary_secret);

        let barrier = Arc::new(Barrier::new(100));
        let success_count = Arc::new(AtomicUsize::new(0));
        let failure_count = Arc::new(AtomicUsize::new(0));

        let mut handles = Vec::with_capacity(100);

        for _ in 0..100 {
            let v = Arc::clone(&vault);
            let b = Arc::clone(&barrier);
            let sc = Arc::clone(&success_count);
            let fc = Arc::clone(&failure_count);
            let h = handle.clone();
            let expected_secret = canary_secret.clone();

            handles.push(thread::spawn(move || {
                b.wait(); // Synchronize all 100 threads to fire simultaneously
                let res = v.consume_capability("peer_target_100", &h);
                match res {
                    Some(s) => {
                        assert_eq!(s.as_str(), expected_secret);
                        sc.fetch_add(1, Ordering::SeqCst);
                    }
                    None => {
                        fc.fetch_add(1, Ordering::SeqCst);
                    }
                }
            }));
        }

        for th in handles {
            th.join().expect("Thread joined successfully");
        }

        assert_eq!(
            success_count.load(Ordering::SeqCst),
            1,
            "Round {round}: Exactly one thread must successfully consume capability"
        );
        assert_eq!(
            failure_count.load(Ordering::SeqCst),
            99,
            "Round {round}: Exactly 99 threads must fail to consume capability"
        );
    }
}

#[test]
fn test_stress_ffi_global_capability_handles_100_threads() {
    for round in 0..50 {
        let canary = format!("GLOBAL_CANARY_FFI_{round}");
        let handle = main_create_capability_handle("peer_ffi_100".to_string(), canary.clone());

        let barrier = Arc::new(Barrier::new(100));
        let success_count = Arc::new(AtomicUsize::new(0));
        let failure_count = Arc::new(AtomicUsize::new(0));

        let mut threads = Vec::with_capacity(100);

        for _ in 0..100 {
            let b = Arc::clone(&barrier);
            let sc = Arc::clone(&success_count);
            let fc = Arc::clone(&failure_count);
            let h = handle.clone();
            let exp = canary.clone();

            threads.push(thread::spawn(move || {
                b.wait();
                let retrieved = main_consume_capability_handle("peer_ffi_100".to_string(), h);
                if retrieved == exp {
                    sc.fetch_add(1, Ordering::SeqCst);
                } else if retrieved.is_empty() {
                    fc.fetch_add(1, Ordering::SeqCst);
                } else {
                    panic!("Unexpected secret returned: {retrieved}");
                }
            }));
        }

        for th in threads {
            th.join().expect("Thread join");
        }

        assert_eq!(
            success_count.load(Ordering::SeqCst),
            1,
            "FFI round {round}: Exactly 1 thread must succeed"
        );
        assert_eq!(
            failure_count.load(Ordering::SeqCst),
            99,
            "FFI round {round}: Exactly 99 threads must fail with empty string"
        );
    }
}

#[test]
fn test_stress_capability_vault_parallel_100_distinct_peers() {
    let vault = Arc::new(CapabilityVault::new());
    let mut handles = Vec::new();

    for i in 0..100 {
        let peer_id = format!("peer_distinct_{i}");
        let secret = format!("secret_for_{i}");
        let handle = vault.create_capability(&peer_id, &secret);
        handles.push((peer_id, secret, handle));
    }

    let barrier = Arc::new(Barrier::new(100));
    let mut threads = Vec::new();

    for (peer_id, secret, handle) in handles.clone() {
        let v = Arc::clone(&vault);
        let b = Arc::clone(&barrier);

        threads.push(thread::spawn(move || {
            b.wait();
            let res = v.consume_capability(&peer_id, &handle);
            assert_eq!(
                res.as_deref().map(|s| s.as_str()),
                Some(secret.as_str()),
                "Each peer must successfully consume its own handle"
            );
        }));
    }

    for th in threads {
        th.join().expect("Join thread");
    }

    // Second round: all 100 handles must now be invalid
    for (peer_id, _, handle) in handles {
        let replay = vault.consume_capability(&peer_id, &handle);
        assert!(replay.is_none(), "All handles must be single-use only");
    }
}

#[test]
fn test_stress_capability_vault_peer_mismatch_and_fail_closed() {
    let vault = CapabilityVault::new();

    // 1. Regular mismatch
    let handle = vault.create_capability("victim_peer", "VICTIM_SECRET");
    let breach_attempt = vault.consume_capability("attacker_peer", &handle);
    assert!(breach_attempt.is_none(), "Adversary must receive None");

    // Fail-closed verification: legitimate peer can no longer use the burned handle
    let victim_attempt = vault.consume_capability("victim_peer", &handle);
    assert!(
        victim_attempt.is_none(),
        "Compromised handle must be burned/fail-closed"
    );

    // 2. Substring & Prefix/Suffix mismatch tests
    let handle_exact = vault.create_capability("peer_12", "SECRET_12");
    assert!(vault.consume_capability("peer_1", &handle_exact).is_none());
    assert!(vault
        .consume_capability("peer_123", &handle_exact)
        .is_none());
    assert!(vault.consume_capability("peer_12", &handle_exact).is_none()); // Already burned

    // 3. Boundary peer IDs
    let handle_empty = vault.create_capability("", "SECRET_EMPTY");
    assert_eq!(
        vault
            .consume_capability("", &handle_empty)
            .as_deref()
            .map(|s| s.as_str()),
        Some("SECRET_EMPTY")
    );

    let handle_unicode = vault.create_capability("peer_🔒_🚀", "SECRET_UNICODE");
    assert!(vault
        .consume_capability("peer_🔒", &handle_unicode)
        .is_none()); // prefix rejected
    assert!(vault
        .consume_capability("peer_🔒_🚀", &handle_unicode)
        .is_none()); // burned

    let handle_null = vault.create_capability("peer\0evil", "SECRET_NULL");
    assert!(vault.consume_capability("peer", &handle_null).is_none());
}

#[test]
fn test_stress_capability_vault_ttl_expiration_and_cleanup() {
    let vault = CapabilityVault::new();

    // 1. Short TTL expiration
    let handle_short =
        vault.create_capability_with_ttl("peer_ttl", "SECRET_EXPIRING", Duration::from_millis(15));
    thread::sleep(Duration::from_millis(30));
    assert!(
        vault
            .consume_capability("peer_ttl", &handle_short)
            .is_none(),
        "Handle must expire after TTL"
    );

    // 2. Zero TTL immediate expiration
    let handle_zero =
        vault.create_capability_with_ttl("peer_zero", "SECRET_ZERO_TTL", Duration::from_millis(0));
    assert!(
        vault
            .consume_capability("peer_zero", &handle_zero)
            .is_none(),
        "Handle with zero TTL must expire immediately"
    );

    // 3. Opportunistic cleanup stress test (5,000 expired handles)
    for i in 0..5000 {
        vault.create_capability_with_ttl(
            &format!("peer_cleanup_{i}"),
            "DUMMY_SECRET",
            Duration::from_millis(1),
        );
    }
    thread::sleep(Duration::from_millis(15));

    // Creating one new capability triggers retain cleanup
    let valid_handle = vault.create_capability("peer_survivor", "VALID_SECRET");

    assert_eq!(
        vault
            .consume_capability("peer_survivor", &valid_handle)
            .as_deref()
            .map(|s| s.as_str()),
        Some("VALID_SECRET")
    );
    // After consumption, re-consuming must return None
    assert!(vault
        .consume_capability("peer_survivor", &valid_handle)
        .is_none());
}

#[test]
fn test_stress_capability_vault_malformed_handles() {
    let vault = CapabilityVault::new();

    let malformed_inputs = [
        "",
        "cap",
        "cap_",
        "CAP_",
        "cap_123",
        "cap_not_a_valid_uuid_at_all",
        "cap_../../../../etc/passwd",
        "cap_' OR '1'='1' --",
        "cap_\0\0\0",
        "cap_\n\r\t",
        "cap_   ",
        "cap_🦀_emoji_handle",
        "not_a_cap_prefix_at_all",
        "Bearer cap_1234567890",
        "cap_ffffffff-ffff-ffff-ffff-ffffffffffff", // non-existent UUID
    ];

    for input in malformed_inputs {
        let res = vault.consume_capability("any_peer", input);
        assert!(res.is_none(), "Malformed handle '{input}' must return None");
    }

    // Huge malformed handle (200,000 chars)
    let huge_handle = "cap_".to_string() + &"A".repeat(200_000);
    assert!(
        vault.consume_capability("any_peer", &huge_handle).is_none(),
        "Huge malformed handle must return None safely"
    );
}

#[test]
fn test_stress_cred004_logout_and_token_purging() {
    static TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = TEST_MUTEX.lock().unwrap();

    // 1. Establish persistent options mimicking authenticated session
    LocalConfig::set_option(
        "access_token".to_string(),
        "CANARY_TOKEN_STRESS_999".to_string(),
    );
    LocalConfig::set_option("user_info".to_string(), "{\"name\":\"tester\"}".to_string());

    assert_eq!(
        get_api_access_token().as_deref(),
        Some("CANARY_TOKEN_STRESS_999")
    );
    assert_eq!(
        LocalConfig::get_option("access_token"),
        "CANARY_TOKEN_STRESS_999"
    );
    assert!(!LocalConfig::get_option("user_info").is_empty());

    // 2. Perform main_account_logout()
    main_account_logout();

    // 3. Verify complete purging from native access token accessor and LocalConfig
    assert_eq!(
        get_api_access_token(),
        None,
        "get_api_access_token must return None after logout"
    );
    assert_eq!(
        LocalConfig::get_option("access_token"),
        "",
        "access_token option must be purged to empty string"
    );
    assert_eq!(
        LocalConfig::get_option("user_info"),
        "",
        "user_info option must be purged to empty string"
    );

    // 4. Repeated logouts must be idempotent and safe
    for _ in 0..10 {
        main_account_logout();
        assert_eq!(get_api_access_token(), None);
    }
}
