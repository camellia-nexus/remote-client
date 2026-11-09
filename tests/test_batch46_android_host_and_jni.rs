use scrap::frame_raw::{
    FrameRaw, MAX_AUDIO_FRAME_BYTES, MAX_AUDIO_FRAME_TIMEOUT, MAX_VIDEO_FRAME_BYTES,
    MAX_VIDEO_FRAME_TIMEOUT,
};
use std::time::Duration;

#[test]
fn test_frame_raw_disabled_by_default() {
    let mut frame = FrameRaw::new("test_video", MAX_VIDEO_FRAME_TIMEOUT, MAX_VIDEO_FRAME_BYTES);
    assert!(!frame.is_enabled());
    assert_eq!(frame.len(), 0);
    assert!(frame.is_empty());

    // Update when disabled should be a no-op
    let data = vec![1, 2, 3, 4];
    frame.update(&data);
    assert_eq!(frame.len(), 0);
    assert_eq!(frame.current_generation(), 0);

    let mut dst = Vec::new();
    let mut last = Vec::new();
    assert!(frame.take(&mut dst, &mut last).is_none());
}

#[test]
fn test_frame_raw_copy_before_return_semantics() {
    let mut frame = FrameRaw::new("test_video", MAX_VIDEO_FRAME_TIMEOUT, MAX_VIDEO_FRAME_BYTES);
    frame.set_enable(true);
    assert!(frame.is_enabled());
    assert_eq!(frame.current_generation(), 1);

    // Provide a source slice
    let mut src = vec![10, 20, 30, 40, 50];
    frame.update(&src);
    assert_eq!(frame.len(), 5);
    assert_eq!(frame.current_generation(), 2);

    // Mutate source slice after update - internal buffer MUST remain unchanged (no dangling pointer or shared reference)
    src[0] = 99;
    src[1] = 88;

    let mut dst = Vec::new();
    let mut last = Vec::new();
    let res = frame.take(&mut dst, &mut last);
    assert!(res.is_some());
    assert_eq!(dst, vec![10, 20, 30, 40, 50]); // Source mutation did NOT affect copied data
    assert_eq!(last, vec![10, 20, 30, 40, 50]); // last was updated

    // Second take without new update MUST return None (no duplicate frame delivery)
    let mut dst2 = Vec::new();
    assert!(frame.take(&mut dst2, &mut last).is_none());
    assert!(dst2.is_empty());
}

#[test]
fn test_frame_raw_budget_enforcement() {
    let max_budget = 1024; // 1 KiB
    let mut frame = FrameRaw::new("test_bounded", Duration::from_secs(1), max_budget);
    frame.set_enable(true);

    // Frame within budget succeeds
    let valid_data = vec![42u8; 1000];
    frame.update(&valid_data);
    assert_eq!(frame.len(), 1000);

    let mut dst = Vec::new();
    let mut last = Vec::new();
    assert!(frame.take(&mut dst, &mut last).is_some());
    assert_eq!(dst.len(), 1000);

    // Frame exceeding budget is rejected (fail-closed, drops frame)
    let over_budget_data = vec![42u8; 2048];
    frame.update(&over_budget_data);
    // Length remains what it was, but generation wasn't bumped to a new valid frame
    assert!(frame.take(&mut dst, &mut last).is_none());
}

#[test]
fn test_frame_raw_timeout_drop() {
    let mut frame = FrameRaw::new(
        "test_timeout",
        Duration::from_millis(10),
        MAX_VIDEO_FRAME_BYTES,
    );
    frame.set_enable(true);

    let data = vec![1, 2, 3];
    frame.update(&data);

    // Wait past timeout
    std::thread::sleep(Duration::from_millis(25));

    let mut dst = Vec::new();
    let mut last = Vec::new();
    assert!(frame.take(&mut dst, &mut last).is_none());
}

#[test]
fn test_frame_raw_disable_frees_memory() {
    let mut frame = FrameRaw::new("test_video", MAX_VIDEO_FRAME_TIMEOUT, MAX_VIDEO_FRAME_BYTES);
    frame.set_enable(true);

    let data = vec![0xAB; 64 * 1024]; // 64 KiB
    frame.update(&data);
    assert_eq!(frame.len(), 64 * 1024);

    // Disabling must shrink and clear
    frame.set_enable(false);
    assert_eq!(frame.len(), 0);
    assert!(!frame.is_enabled());

    let mut dst = Vec::new();
    let mut last = Vec::new();
    assert!(frame.take(&mut dst, &mut last).is_none());
}

#[test]
fn test_audio_frame_raw_lifecycle() {
    let mut frame = FrameRaw::new("test_audio", MAX_AUDIO_FRAME_TIMEOUT, MAX_AUDIO_FRAME_BYTES);
    frame.set_enable(true);
    assert!(frame.is_enabled());

    let audio_pcm = vec![12u8; 1920];
    frame.update(&audio_pcm);

    let mut dst = Vec::new();
    let mut last = Vec::new();
    assert!(frame.take(&mut dst, &mut last).is_some());
    assert_eq!(dst.len(), 1920);
}

#[test]
fn test_android_supervisor_idempotency_and_lifecycle() {
    use camellia_remote::server::android_supervisor::{
        current_generation, get_status, is_android_server_active, reset_for_test,
        start_android_server, stop_android_server, SupervisorStatus,
    };

    reset_for_test();
    assert_eq!(get_status(), SupervisorStatus::Stopped);
    assert!(!is_android_server_active());

    // First start
    let gen1 = start_android_server("".into(), "".into());
    assert!(gen1 > 0);
    assert_eq!(get_status(), SupervisorStatus::Running(gen1));
    assert!(is_android_server_active());
    assert!(camellia_remote::common::is_server_running());

    // Idempotent second start must return SAME generation without spawning duplicate runtime
    let gen2 = start_android_server("".into(), "".into());
    assert_eq!(gen1, gen2);
    assert_eq!(get_status(), SupervisorStatus::Running(gen1));

    // Stop must cleanly terminate, join, and reset active state
    stop_android_server();
    assert_eq!(get_status(), SupervisorStatus::Stopped);
    assert!(!is_android_server_active());
    assert!(!camellia_remote::common::is_server_running());

    // Starting again after stop increments generation
    let gen3 = start_android_server("".into(), "".into());
    assert!(gen3 > gen1);
    assert_eq!(current_generation(), gen3);
    assert_eq!(get_status(), SupervisorStatus::Running(gen3));
    assert!(is_android_server_active());

    // Clean up
    reset_for_test();
    assert_eq!(get_status(), SupervisorStatus::Stopped);
}
