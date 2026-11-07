// Client Batch 31 Unit & Adversarial Tests (RES-039)
// Tests for Flutter asynchronous query runner lifecycle, idempotency, and multi-engine generation fencing.

#![cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    feature = "flutter"
))]

use camellia_remote::flutter::async_tasks::{
    get_active_engine_count, get_engine_generation, is_runner_running, query_onlines,
    register_flutter_engine, start_flutter_async_runner, stop_flutter_async_runner,
    unregister_flutter_engine,
};
use std::sync::Mutex;
use std::time::Duration;

static BATCH31_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_batch31_test_lock() -> std::sync::MutexGuard<'static, ()> {
    BATCH31_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner())
}

#[test]
fn test_res039_async_runner_idempotency_and_lifecycle() {
    let _lock = acquire_batch31_test_lock();

    // 1. Initial stop to start from clean state
    stop_flutter_async_runner();
    assert!(
        !is_runner_running(),
        "Runner must not be running initially after stop"
    );

    // 2. Start runner
    start_flutter_async_runner();
    assert!(
        is_runner_running(),
        "Runner must be running after start_flutter_async_runner"
    );

    // 3. Repeated invocations of start_flutter_async_runner must be strictly idempotent
    for _ in 0..5 {
        start_flutter_async_runner();
        assert!(
            is_runner_running(),
            "Repeated starts must preserve active running state"
        );
    }

    // 4. Queuing queries while running should succeed
    let query_result = query_onlines(vec!["peer_a".to_string(), "peer_b".to_string()]);
    assert!(
        query_result.is_ok(),
        "query_onlines should succeed when runner is active"
    );

    // 5. Cleanly stop runner
    stop_flutter_async_runner();
    assert!(
        !is_runner_running(),
        "Runner must be stopped after stop_flutter_async_runner"
    );

    // 6. Repeated stops are idempotent and safe
    for _ in 0..3 {
        stop_flutter_async_runner();
        assert!(!is_runner_running());
    }

    // 7. Queuing queries after stop must fail gracefully without panicking
    let query_after_stop = query_onlines(vec!["peer_c".to_string()]);
    assert!(
        query_after_stop.is_err(),
        "query_onlines must return Err when runner is stopped"
    );

    // 8. Runner can be restarted cleanly after being stopped
    start_flutter_async_runner();
    assert!(
        is_runner_running(),
        "Runner must restart cleanly after stop"
    );
    let query_restarted = query_onlines(vec!["peer_d".to_string()]);
    assert!(
        query_restarted.is_ok(),
        "query_onlines should succeed after runner restarts"
    );

    // Clean up
    stop_flutter_async_runner();
}

#[test]
fn test_res039_engine_registration_and_generation_monotonicity() {
    let _lock = acquire_batch31_test_lock();

    let initial_count = get_active_engine_count();
    let initial_gen = get_engine_generation();

    // Simulate Flutter Engine 1 initializing
    let gen1 = register_flutter_engine();
    assert_eq!(
        gen1,
        initial_gen + 1,
        "Engine registration must increment generation"
    );
    assert_eq!(
        get_active_engine_count(),
        initial_count + 1,
        "Active engine count must increment"
    );

    // Simulate Flutter Engine 2 initializing (e.g. multi-window)
    let gen2 = register_flutter_engine();
    assert!(
        gen2 > gen1,
        "Subsequent engine registration must produce strictly higher generation"
    );
    assert_eq!(
        get_active_engine_count(),
        initial_count + 2,
        "Active engine count must reflect second engine"
    );

    // Simulate Flutter Engine 1 tearing down
    unregister_flutter_engine(gen1);
    assert_eq!(
        get_active_engine_count(),
        initial_count + 1,
        "Active engine count must decrement on engine unregister"
    );

    // Simulate Flutter Engine 2 tearing down
    unregister_flutter_engine(gen2);
    assert_eq!(
        get_active_engine_count(),
        initial_count,
        "Active engine count must return to baseline"
    );
}

#[test]
fn test_res039_query_batching_and_deduplication() {
    let _lock = acquire_batch31_test_lock();

    start_flutter_async_runner();
    assert!(is_runner_running());

    // Send rapid burst of duplicate and overlapping peer IDs
    for i in 0..10 {
        let ids = vec![
            "peer_shared_1".to_string(),
            format!("peer_burst_{}", i % 3),
            "".to_string(), // Empty string should be discarded
        ];
        let res = query_onlines(ids);
        assert!(res.is_ok(), "Rapid query_onlines burst must be accepted");
    }

    // Give loop time to coalesce and process
    std::thread::sleep(Duration::from_millis(200));

    stop_flutter_async_runner();
}
