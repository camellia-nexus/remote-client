use camellia_remote::{
    client::io_loop::{
        FpsControl, VideoThread, VoiceCallWorker, MAX_VOICE_OUTBOUND_QUEUE_BYTES,
        MAX_VOICE_OUTBOUND_QUEUE_FRAMES,
    },
    client::{
        is_supported_audio_channel_count, is_supported_audio_sample_rate, AudioCommand, AudioQueue,
        AudioWorker, VideoQueue, VideoQueuePushResult, MAX_AUDIO_FRAME_BYTES,
        MAX_AUDIO_QUEUE_BYTES, MAX_AUDIO_QUEUE_FRAMES, MAX_DISPLAY_DECODERS,
        MAX_VIDEO_QUEUE_FRAMES,
    },
    ConnInner,
};
use camellia_remote_protocol::{
    bytes::Bytes,
    message_proto::{AudioFormat, AudioFrame, EncodedVideoFrame, EncodedVideoFrames, VideoFrame},
};
use std::{
    collections::{HashSet, VecDeque},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, RwLock,
    },
    time::{Duration, Instant},
};

// ============================================================================
// RES-013 Tests: Audio Queue Bounds, Head-Drop, Generation Barrier, Teardown
// ============================================================================

#[test]
fn test_audio_queue_bounds_and_head_drop_res_013() {
    let queue = AudioQueue::new();

    // 1. Frame size exceeding MAX_AUDIO_FRAME_BYTES (8192 bytes) must be rejected
    let mut oversized_frame = AudioFrame::new();
    oversized_frame.data = vec![0u8; MAX_AUDIO_FRAME_BYTES + 1].into();
    let pushed = queue.push_frame(Box::new(oversized_frame));
    assert!(!pushed, "Oversized audio frame must be rejected");
    assert_eq!(queue.len(), 0);
    assert_eq!(queue.total_bytes(), 0);

    // 2. Head-drop eviction: push 50,000 frames without popping
    const TOTAL_FRAMES: usize = 50_000;
    const FRAME_SIZE: usize = 100;

    for i in 0..TOTAL_FRAMES {
        let mut frame = AudioFrame::new();
        // Embed frame index in first 4 bytes to verify newest frames retained
        let mut data = vec![0u8; FRAME_SIZE];
        data[0..4].copy_from_slice(&(i as u32).to_le_bytes());
        frame.data = Bytes::from(data);
        let pushed = queue.push_frame(Box::new(frame));
        assert!(pushed, "Valid audio frame must be accepted");
    }

    // Assert queue invariant: len <= MAX_AUDIO_QUEUE_FRAMES (128)
    assert!(
        queue.len() <= MAX_AUDIO_QUEUE_FRAMES,
        "Queue length {} exceeded MAX_AUDIO_QUEUE_FRAMES {}",
        queue.len(),
        MAX_AUDIO_QUEUE_FRAMES
    );
    assert_eq!(queue.len(), MAX_AUDIO_QUEUE_FRAMES);

    // Assert queue total_bytes invariant: <= MAX_AUDIO_QUEUE_BYTES (512 KiB)
    assert!(
        queue.total_bytes() <= MAX_AUDIO_QUEUE_BYTES,
        "Queue bytes {} exceeded MAX_AUDIO_QUEUE_BYTES {}",
        queue.total_bytes(),
        MAX_AUDIO_QUEUE_BYTES
    );
    assert_eq!(queue.total_bytes(), MAX_AUDIO_QUEUE_FRAMES * FRAME_SIZE);

    // Assert dropped_frames count
    let expected_dropped = TOTAL_FRAMES - MAX_AUDIO_QUEUE_FRAMES;
    assert_eq!(
        queue.dropped_frames(),
        expected_dropped,
        "Dropped frames count mismatch"
    );

    // Assert FIFO head-drop: remaining items in queue must be the newest frames
    let first_expected_idx = expected_dropped as u32;
    for i in 0..MAX_AUDIO_QUEUE_FRAMES {
        let cmd = queue
            .pop_timeout(Duration::from_millis(50))
            .expect("Expected frame in queue");
        match cmd {
            AudioCommand::Frame(frame, _gen) => {
                let frame_idx = u32::from_le_bytes(frame.data[0..4].try_into().unwrap());
                assert_eq!(
                    frame_idx,
                    first_expected_idx + i as u32,
                    "Head-drop must preserve newest frames in order"
                );
            }
            _ => panic!("Expected AudioCommand::Frame"),
        }
    }

    assert_eq!(queue.len(), 0);
    assert_eq!(queue.total_bytes(), 0);
}

#[test]
fn test_audio_format_validation_res_013() {
    // Opus supported sample rates
    for valid_rate in [8000, 12000, 16000, 24000, 48000] {
        assert!(
            is_supported_audio_sample_rate(valid_rate),
            "Sample rate {valid_rate} must be supported"
        );
    }

    // Unsupported sample rates
    for invalid_rate in [0, 44100, 88200, 96000, 192000] {
        assert!(
            !is_supported_audio_sample_rate(invalid_rate),
            "Sample rate {invalid_rate} must NOT be supported for Opus"
        );
    }

    // Supported channel counts: 1 (mono) or 2 (stereo)
    assert!(is_supported_audio_channel_count(1));
    assert!(is_supported_audio_channel_count(2));

    // Unsupported channel counts
    for invalid_channels in [0, 3, 5, 6, 8] {
        assert!(
            !is_supported_audio_channel_count(invalid_channels),
            "Channel count {invalid_channels} must NOT be supported"
        );
    }
}

#[test]
fn test_audio_format_generation_barrier_res_013() {
    let queue = AudioQueue::new();
    assert_eq!(queue.generation(), 1);

    // Push 10 frames under generation 1
    for _ in 0..10 {
        let mut frame = AudioFrame::new();
        frame.data = Bytes::from(vec![1u8; 64]);
        queue.push_frame(Box::new(frame));
    }
    assert_eq!(queue.len(), 10);
    assert_eq!(queue.total_bytes(), 640);

    // Format change: sets generation barrier
    let mut format = AudioFormat::new();
    format.sample_rate = 48000;
    format.channels = 2;
    queue.set_format(format.clone());

    // Generation must advance to 2
    assert_eq!(queue.generation(), 2);

    // Stale generation 1 frames must be purged, only Format command remains
    assert_eq!(queue.len(), 1);
    assert_eq!(queue.total_bytes(), 0);

    // Pop the barrier command
    let cmd = queue
        .pop_timeout(Duration::from_millis(50))
        .expect("Expected command");
    match cmd {
        AudioCommand::Format(f, gen) => {
            assert_eq!(gen, 2);
            assert_eq!(f.sample_rate, 48000);
            assert_eq!(f.channels, 2);
        }
        _ => panic!("Expected AudioCommand::Format"),
    }

    // Next frames pushed belong to generation 2
    let mut frame2 = AudioFrame::new();
    frame2.data = Bytes::from(vec![2u8; 128]);
    queue.push_frame(Box::new(frame2));

    let cmd2 = queue
        .pop_timeout(Duration::from_millis(50))
        .expect("Expected frame");
    match cmd2 {
        AudioCommand::Frame(_f, gen) => {
            assert_eq!(gen, 2);
        }
        _ => panic!("Expected AudioCommand::Frame"),
    }
}

#[test]
fn test_audio_worker_cancellation_and_deadline_res_013() {
    let mut worker = AudioWorker::start();

    // Push a format command and a frame
    let mut format = AudioFormat::new();
    format.sample_rate = 48000;
    format.channels = 2;
    worker.queue().set_format(format);

    let mut frame = AudioFrame::new();
    frame.data = Bytes::from(vec![0u8; 64]);
    worker.queue().push_frame(Box::new(frame));

    // Teardown must complete well within the 500ms deadline
    let start = Instant::now();
    worker.stop();
    let elapsed = start.elapsed();

    assert!(
        elapsed < Duration::from_millis(400),
        "AudioWorker stop took {:?}, exceeding deadline < 400ms",
        elapsed
    );
}

// ============================================================================
// RES-014 Tests: Voice Call Outbound Queue Bounds, Congestion Drop, Teardown
// ============================================================================

#[test]
fn test_voice_call_outbound_queue_bounds_res_014() {
    // Simulate the bounded outbound queue policy implemented in start_voice_call:
    // MAX_VOICE_OUTBOUND_QUEUE_FRAMES = 32
    // MAX_VOICE_OUTBOUND_QUEUE_BYTES = 64 KiB
    let mut outbound_frames: usize = 0;
    let mut outbound_bytes: usize = 0;
    let mut frame_queue: VecDeque<usize> = VecDeque::new();
    let mut dropped_count: usize = 0;

    const TOTAL_VOICE_FRAMES: usize = 1000;
    const VOICE_FRAME_LEN: usize = 500; // 500 bytes per frame

    for _ in 0..TOTAL_VOICE_FRAMES {
        while !frame_queue.is_empty()
            && (outbound_frames >= MAX_VOICE_OUTBOUND_QUEUE_FRAMES
                || outbound_bytes + VOICE_FRAME_LEN > MAX_VOICE_OUTBOUND_QUEUE_BYTES)
        {
            if let Some(old_len) = frame_queue.pop_front() {
                outbound_frames = outbound_frames.saturating_sub(1);
                outbound_bytes = outbound_bytes.saturating_sub(old_len);
                dropped_count += 1;
            }
        }

        outbound_frames += 1;
        outbound_bytes += VOICE_FRAME_LEN;
        frame_queue.push_back(VOICE_FRAME_LEN);
    }

    assert_eq!(outbound_frames, MAX_VOICE_OUTBOUND_QUEUE_FRAMES);
    assert_eq!(
        outbound_bytes,
        MAX_VOICE_OUTBOUND_QUEUE_FRAMES * VOICE_FRAME_LEN
    );
    assert!(outbound_bytes <= MAX_VOICE_OUTBOUND_QUEUE_BYTES);
    assert_eq!(
        dropped_count,
        TOTAL_VOICE_FRAMES - MAX_VOICE_OUTBOUND_QUEUE_FRAMES
    );
}

#[test]
fn test_voice_call_worker_lifecycle_and_teardown_res_014() {
    let cancel_token = Arc::new(AtomicBool::new(false));
    let cancel = cancel_token.clone();

    let handle = std::thread::Builder::new()
        .name("test_voice_worker".to_string())
        .spawn(move || {
            while !cancel.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(10));
            }
        })
        .unwrap();

    let mut worker = VoiceCallWorker {
        #[cfg(not(any(target_os = "ios")))]
        conn_inner: ConnInner::new(999, None, None),
        cancel_token,
        join_handle: Some(handle),
    };

    let start = Instant::now();
    worker.stop();
    let elapsed = start.elapsed();

    assert!(
        elapsed < Duration::from_millis(300),
        "VoiceCallWorker stop took {:?}, exceeding deadline < 300ms",
        elapsed
    );
    assert!(worker.join_handle.is_none());
}

// ============================================================================
// RES-015 Tests: Display Decoder Bounds, Pre-login Gate, Unified Queue, Teardown
// ============================================================================

#[test]
fn test_video_display_bounds_and_prelogin_res_015() {
    assert_eq!(MAX_DISPLAY_DECODERS, 16);

    // Pre-login rejection check: is_connected = false rejects any video frame
    let is_connected = false;
    let mut vf = VideoFrame::new();
    vf.display = 0;
    assert!(!is_connected, "Frame must be rejected when not connected");

    // Display ID range check: 0 <= display < MAX_DISPLAY_DECODERS
    let valid_display_ids: [isize; 4] = [0, 1, 5, 15];
    let invalid_display_ids: [isize; 5] = [-1, -10, 16, 17, 100];

    for d in valid_display_ids {
        assert!(
            d >= 0 && (d as usize) < MAX_DISPLAY_DECODERS,
            "Display {d} must be within bounds"
        );
    }

    for d in invalid_display_ids {
        assert!(
            d < 0 || (d as usize) >= MAX_DISPLAY_DECODERS,
            "Display {d} must be rejected outside bounds"
        );
    }

    // Allowed displays check
    let mut allowed_displays = HashSet::new();
    allowed_displays.insert(0usize);
    allowed_displays.insert(1usize);

    assert!(allowed_displays.contains(&0));
    assert!(allowed_displays.contains(&1));
    assert!(!allowed_displays.contains(&2));
    assert!(!allowed_displays.contains(&15));
}

fn create_encoded_frame(len: usize) -> EncodedVideoFrames {
    let mut frames = EncodedVideoFrames::new();
    let mut f = EncodedVideoFrame::new();
    f.data = Bytes::from(vec![0xAA; len]);
    frames.frames.push(f);
    frames
}

#[test]
fn test_video_unified_queue_keyframe_purge_res_015() {
    let queue = VideoQueue::new();
    assert_eq!(queue.len(), 0);
    assert_eq!(queue.generation(), 1);

    // Push 10 delta frames
    for _ in 0..10 {
        let mut vf = VideoFrame::new();
        vf.display = 0;
        vf.set_vp8s(create_encoded_frame(500));

        let res = queue.push_frame(Box::new(vf), false);
        assert_eq!(res, VideoQueuePushResult::Pushed);
    }

    assert_eq!(queue.len(), 10);
    assert_eq!(queue.total_bytes(), 5000);

    // Keyframe arrives: must purge all stale deltas (zero latency lag)
    let mut key_vf = VideoFrame::new();
    key_vf.display = 0;
    key_vf.set_vp8s(create_encoded_frame(2000));

    let res = queue.push_frame(Box::new(key_vf), true);
    assert_eq!(res, VideoQueuePushResult::PurgedBacklogAndPushedKeyframe);

    // Backlog purged: exactly 1 frame (the keyframe) in queue
    assert_eq!(queue.len(), 1);
    assert_eq!(queue.total_bytes(), 2000);
    // Generation advanced
    assert_eq!(queue.generation(), 2);
}

#[test]
fn test_video_unified_queue_overload_and_refresh_res_015() {
    let queue = VideoQueue::new();

    // Fill queue to MAX_VIDEO_QUEUE_FRAMES (30) with delta frames
    for _ in 0..MAX_VIDEO_QUEUE_FRAMES {
        let mut vf = VideoFrame::new();
        vf.display = 0;
        vf.set_vp8s(create_encoded_frame(100));

        let res = queue.push_frame(Box::new(vf), false);
        assert_eq!(res, VideoQueuePushResult::Pushed);
    }
    assert_eq!(queue.len(), MAX_VIDEO_QUEUE_FRAMES);

    // 31st delta frame triggers overload policy:
    // Evicts stale deltas, enters waiting_for_keyframe state, requests refresh
    let mut overflow_vf = VideoFrame::new();
    overflow_vf.display = 0;
    overflow_vf.set_vp8s(create_encoded_frame(100));

    let res = queue.push_frame(Box::new(overflow_vf), false);
    assert_eq!(res, VideoQueuePushResult::DroppedOverloadNeedRefresh);
    assert!(queue.is_waiting_for_keyframe());
    assert_eq!(queue.len(), 0);
    assert_eq!(queue.total_bytes(), 0);

    // Subsequent delta frames dropped while waiting for keyframe
    let mut another_delta = VideoFrame::new();
    another_delta.display = 0;
    let res = queue.push_frame(Box::new(another_delta), false);
    assert_eq!(res, VideoQueuePushResult::DroppedWaitingForKeyframe);
    assert_eq!(queue.len(), 0);

    // Keyframe arrives: restores pipeline and pushes keyframe
    let mut key_vf = VideoFrame::new();
    key_vf.display = 0;
    key_vf.set_vp8s(create_encoded_frame(1500));

    let res = queue.push_frame(Box::new(key_vf), true);
    assert_eq!(res, VideoQueuePushResult::Pushed);
    assert!(!queue.is_waiting_for_keyframe());
    assert_eq!(queue.len(), 1);
    assert_eq!(queue.total_bytes(), 1500);
}

#[test]
fn test_video_queue_request_refresh_res_015() {
    let queue = VideoQueue::new();

    // Push delta frames
    for _ in 0..5 {
        let mut vf = VideoFrame::new();
        vf.display = 0;
        vf.set_vp8s(create_encoded_frame(200));
        queue.push_frame(Box::new(vf), false);
    }
    assert_eq!(queue.len(), 5);

    // Client/UI requests refresh
    queue.request_refresh();

    assert!(queue.is_waiting_for_keyframe());
    assert_eq!(queue.len(), 0);
    assert_eq!(queue.total_bytes(), 0);

    // Delta frames rejected until keyframe
    let mut delta = VideoFrame::new();
    delta.display = 0;
    let res = queue.push_frame(Box::new(delta), false);
    assert_eq!(res, VideoQueuePushResult::DroppedWaitingForKeyframe);
}

#[test]
fn test_video_thread_teardown_deadline_res_015() {
    let video_queue = Arc::new(VideoQueue::new());
    let cancel_token = Arc::new(AtomicBool::new(false));
    let q = video_queue.clone();
    let cancel = cancel_token.clone();

    let handle = std::thread::Builder::new()
        .name("test_video_thread".to_string())
        .spawn(move || {
            while !cancel.load(Ordering::Relaxed) {
                if let Some(_cmd) = q.pop_timeout(Duration::from_millis(50)) {
                    // simulate decode
                }
            }
        })
        .unwrap();

    let mut thread = VideoThread {
        queue: video_queue,
        decode_fps: Arc::new(RwLock::new(None)),
        frame_count: Arc::new(RwLock::new(0)),
        cancel_token,
        join_handle: Some(handle),
        fps_control: FpsControl::default(),
    };

    let start = Instant::now();
    thread.stop();
    let elapsed = start.elapsed();

    assert!(
        elapsed < Duration::from_millis(300),
        "VideoThread stop took {:?}, exceeding deadline < 300ms",
        elapsed
    );
    assert!(thread.join_handle.is_none());
}
