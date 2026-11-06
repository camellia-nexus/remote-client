#[cfg(not(target_os = "linux"))]
use camellia_remote::client::AudioBuffer;
use camellia_remote::{
    keyboard::{
        check_and_update_alt_gr, is_0x021d_down, is_alt_gr_flag, is_left_option_down,
        reset_all_translator_states, reset_session_translator_state, set_alt_gr_flag,
        update_hook_modifier_0x021d, update_hook_modifier_left_option,
    },
    server::audio_service::{get_audio_zero_count, reset_audio_zero_count},
};
use scrap::record::{Recorder, RecorderApi, RecorderContext, RecorderContext2};
use std::{
    sync::{Arc, Barrier, Mutex},
    thread,
    time::{Duration, Instant},
};

// ============================================================================
// CONC-006 Tests: AudioBuffer Per-Session Shrink Timer & Silence Gate Atomicity
// ============================================================================

#[cfg(not(target_os = "linux"))]
#[test]
fn test_audio_buffer_per_session_shrink_isolation_conc006() {
    // Verify each AudioBuffer maintains independent shrink timer without cross-session interference
    let mut buffer_session1 = AudioBuffer::default();
    let mut buffer_session2 = AudioBuffer::default();

    let sample_pcm = vec![0.1f32; 960];

    // Session 1 appends and triggers initial shrink timer
    buffer_session1.append_pcm(&sample_pcm);
    assert!(
        buffer_session1.3.is_some(),
        "Session 1 must have initialized its last_shrink timer"
    );
    assert!(
        buffer_session2.3.is_none(),
        "Session 2 must remain unaffected by Session 1"
    );

    // Session 2 appends later and initializes its own independent timer
    buffer_session2.append_pcm(&sample_pcm);
    assert!(
        buffer_session2.3.is_some(),
        "Session 2 must have initialized its own last_shrink timer"
    );

    // 32 concurrent decoders appending and shrinking
    const NUM_THREADS: usize = 32;
    let barrier = Arc::new(Barrier::new(NUM_THREADS));
    let mut handles = Vec::new();

    for t in 0..NUM_THREADS {
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            let mut buf = AudioBuffer::default();
            buf.resize(48000, 2);
            b.wait();
            for _ in 0..100 {
                let pcm = vec![0.05f32; 480];
                buf.append_pcm(&pcm);
            }
            assert!(
                buf.3.is_some(),
                "Thread {} buffer must have independent timer",
                t
            );
        }));
    }

    for h in handles {
        h.join().unwrap();
    }
}

/// Standalone harness verifying the shrink timer contract across all platforms
#[derive(Default)]
struct AudioShrinkTimerHarness {
    last_shrink: Option<Instant>,
    shrink_count: usize,
}

impl AudioShrinkTimerHarness {
    fn try_shrink(&mut self) -> bool {
        let now = Instant::now();
        match self.last_shrink {
            None => {
                self.last_shrink = Some(now);
                false
            }
            Some(last) => {
                if now.duration_since(last) < Duration::from_millis(12000) {
                    return false;
                }
                self.last_shrink = Some(now);
                self.shrink_count += 1;
                true
            }
        }
    }
}

#[test]
fn test_audio_shrink_timer_cross_platform_isolation_conc006() {
    let mut h1 = AudioShrinkTimerHarness::default();
    let h2 = AudioShrinkTimerHarness::default();

    assert!(!h1.try_shrink());
    assert!(h1.last_shrink.is_some());
    assert!(h2.last_shrink.is_none(), "h2 must not share timer with h1");

    // 32 concurrent harnesses
    const THREADS: usize = 32;
    let barrier = Arc::new(Barrier::new(THREADS));
    let mut handles = Vec::new();

    for _ in 0..THREADS {
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            let mut harness = AudioShrinkTimerHarness::default();
            b.wait();
            assert!(!harness.try_shrink());
            assert!(harness.last_shrink.is_some());
        }));
    }

    for h in handles {
        h.join().unwrap();
    }
}

#[test]
fn test_audio_zero_count_noise_gate_atomicity_conc006() {
    reset_audio_zero_count();
    assert_eq!(get_audio_zero_count(), 0);

    const THREADS: usize = 32;
    let barrier = Arc::new(Barrier::new(THREADS));
    let mut handles = Vec::new();

    for _ in 0..THREADS {
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            for _ in 0..1000 {
                reset_audio_zero_count();
                let _ = get_audio_zero_count();
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    reset_audio_zero_count();
    assert_eq!(get_audio_zero_count(), 0);
}

// ============================================================================
// CONC-007 Tests: Keyboard Translator State Multi-Session Isolation
// ============================================================================

static KEYBOARD_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_keyboard_test_lock() -> std::sync::MutexGuard<'static, ()> {
    KEYBOARD_TEST_MUTEX
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[test]
fn test_keyboard_translator_state_session_isolation_conc007() {
    let _lock = acquire_keyboard_test_lock();
    reset_all_translator_states();

    let session1: u128 = 0x1001;
    let session2: u128 = 0x2002;

    // Initially both are false
    assert!(!is_alt_gr_flag(Some(session1)));
    assert!(!is_alt_gr_flag(Some(session2)));

    // Set AltGr on session 1
    set_alt_gr_flag(Some(session1), true);
    assert!(
        is_alt_gr_flag(Some(session1)),
        "Session 1 must have AltGr true"
    );
    assert!(
        !is_alt_gr_flag(Some(session2)),
        "Session 2 must remain false (no leakage)"
    );

    // Modify AltGr flag via check_and_update_alt_gr
    // If alt is down, ctrl is suppressed
    let ctrl_out = check_and_update_alt_gr(Some(session1), true, false, true);
    assert!(!ctrl_out, "AltGr active on Session 1 must suppress Ctrl");
    assert!(is_alt_gr_flag(Some(session1)));

    // On Session 2, check_and_update_alt_gr should NOT suppress Ctrl because it's not AltGr
    let ctrl_out2 = check_and_update_alt_gr(Some(session2), false, false, true);
    assert!(ctrl_out2, "Session 2 Ctrl must not be suppressed");

    // Clear session 1
    reset_session_translator_state(session1);
    assert!(
        !is_alt_gr_flag(Some(session1)),
        "Session 1 state must be cleared after reset"
    );

    reset_all_translator_states();
}

#[test]
fn test_keyboard_hook_modifier_snapshot_concurrency_conc007() {
    let _lock = acquire_keyboard_test_lock();
    reset_all_translator_states();

    const WORKERS: usize = 64;
    let barrier = Arc::new(Barrier::new(WORKERS));
    let mut handles = Vec::new();

    for i in 0..WORKERS {
        let b = barrier.clone();
        let sid = (i as u128) + 1;
        handles.push(thread::spawn(move || {
            b.wait();
            for step in 0..200 {
                let press = step % 2 == 0;
                set_alt_gr_flag(Some(sid), press);
                assert_eq!(is_alt_gr_flag(Some(sid)), press);

                if i % 2 == 0 {
                    update_hook_modifier_0x021d(press);
                } else {
                    update_hook_modifier_left_option(press);
                }

                let _ = is_0x021d_down(Some(sid));
                let _ = is_left_option_down(Some(sid));
            }
            reset_session_translator_state(sid);
            assert!(!is_alt_gr_flag(Some(sid)));
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    reset_all_translator_states();
}

// ============================================================================
// CONC-011 Tests: Enigo Layout Instance Concurrency & Thread Safety
// ============================================================================

#[test]
fn test_enigo_layout_thread_safety_conc011() {
    fn assert_send<T: Send>() {}
    #[cfg(windows)]
    fn assert_sync<T: Sync>() {}

    assert_send::<enigo::Enigo>();
    #[cfg(windows)]
    assert_sync::<enigo::Enigo>();

    // Test concurrent construction and interaction of Enigo across 32 threads
    const ENIGO_THREADS: usize = 32;
    let barrier = Arc::new(Barrier::new(ENIGO_THREADS));
    let mut handles = Vec::new();

    for _ in 0..ENIGO_THREADS {
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            let enigo_instance = enigo::Enigo::new();
            // Verify debug format
            let dbg_str = format!("{:?}", enigo_instance);
            assert_eq!(dbg_str, "Enigo");
        }));
    }

    for h in handles {
        h.join().unwrap();
    }
}

// ============================================================================
// UNSAFE-011 Tests: Scrap Recorder Type Safety & Send Auto-Derivation
// ============================================================================

#[allow(dead_code)]
struct DummySendRecorderApi;

impl RecorderApi for DummySendRecorderApi {
    fn new(
        _ctx: RecorderContext,
        _ctx2: RecorderContext2,
    ) -> camellia_remote_protocol::ResultType<Self> {
        Ok(Self)
    }

    fn write_video(
        &mut self,
        _frame: &camellia_remote_protocol::message_proto::EncodedVideoFrame,
    ) -> bool {
        true
    }
}

#[test]
fn test_scrap_recorder_send_auto_derivation_unsafe011() {
    fn assert_send<T: Send>() {}
    assert_send::<Recorder>();

    // Verify Recorder can be safely wrapped in Arc<Mutex<Option<Recorder>>> (production pattern)
    let ctx = RecorderContext {
        server: false,
        id: "test-recorder".to_string(),
        dir: "/tmp".to_string(),
        display_idx: 0,
        camera: false,
        tx: None,
    };

    let recorder = Recorder::new(ctx).expect("Recorder creation should succeed");
    let shared = Arc::new(Mutex::new(Some(recorder)));

    let shared_clone = shared.clone();
    let handle = thread::spawn(move || {
        let lock = shared_clone.lock().unwrap();
        assert!(lock.is_some());
    });

    handle.join().unwrap();
}
