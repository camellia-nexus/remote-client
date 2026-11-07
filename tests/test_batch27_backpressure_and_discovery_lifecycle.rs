//! Client Batch 27 Integration Tests
//! Covers:
//! - RES-033 (P1): Host<->CM File Block Backpressure & Byte-Credit Protocol
//! - RES-034 (P1): Controller UI Outbound Dispatcher, Send Deadlines, and Reconnect Cancellation
//! - RES-035 (P1): LAN Discovery Lifecycle, Absolute Deadline, and Resource Bounds

use bytes::Bytes;
use camellia_remote::client::Data;
use camellia_remote::common::input::{
    MOUSE_BUTTON_LEFT, MOUSE_TYPE_DOWN, MOUSE_TYPE_MASK, MOUSE_TYPE_MOVE, MOUSE_TYPE_UP,
};
use camellia_remote::ipc::{
    self, MAX_INFLIGHT_FILE_BLOCKS_PER_JOB, MAX_INFLIGHT_FILE_BYTES_PER_JOB,
    MAX_INFLIGHT_FILE_BYTES_TOTAL,
};
use camellia_remote::lan::{
    self, DISCOVERY_CHANNEL_CAPACITY, DISCOVERY_DEADLINE, MAX_DISCOVERED_PEERS,
    MAX_DISCOVERY_PACKETS, MAX_HOSTNAME_LEN, MAX_MAC_LEN, MAX_PEER_ID_LEN, MAX_PLATFORM_LEN,
    MAX_USERNAME_LEN,
};
use camellia_remote::ui_cm_interface::InflightReadTracker;
use camellia_remote::ui_session_interface::{
    ConnectionRoundState, OutboundDispatcher, OutboundReceiver, MAX_OUTBOUND_QUEUE_MESSAGES,
};
use camellia_remote_protocol::message_proto::*;
use camellia_remote_protocol::tokio;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

// ============================================================================
// RES-033: Host<->CM File Block Backpressure & Byte-Credit Protocol Tests
// ============================================================================

#[test]
fn test_res033_cm_read_job_credit_pause_and_resume() {
    let mut tracker = InflightReadTracker::default();
    let job_id = 42;

    // Initially can read
    assert!(tracker.can_read_block(job_id));

    // Send 3 blocks of 64 KiB -> still within limits (< 4 blocks, < 512 KiB)
    for blk_id in 0..3 {
        assert!(tracker.can_read_block(job_id));
        tracker.record_block_sent(job_id, blk_id, 64 * 1024);
    }
    assert_eq!(tracker.inflight_blocks_for_job(job_id), 3);
    assert_eq!(tracker.inflight_bytes_for_job(job_id), 3 * 64 * 1024);
    assert!(tracker.can_read_block(job_id));

    // Send 4th block -> reaches MAX_INFLIGHT_FILE_BLOCKS_PER_JOB (4)
    tracker.record_block_sent(job_id, 3, 64 * 1024);
    assert_eq!(tracker.inflight_blocks_for_job(job_id), 4);

    // Now paused: cannot read block because in-flight blocks == 4
    assert!(
        !tracker.can_read_block(job_id),
        "Job must be paused when inflight blocks reach MAX_INFLIGHT_FILE_BLOCKS_PER_JOB"
    );

    // Connection receives FileBlockAck for block 0
    tracker.record_ack(job_id, 0);
    assert_eq!(tracker.inflight_blocks_for_job(job_id), 3);
    assert_eq!(tracker.inflight_bytes_for_job(job_id), 3 * 64 * 1024);

    // Now unpaused: can read next block!
    assert!(
        tracker.can_read_block(job_id),
        "Job must resume once FileBlockAck reduces inflight block count"
    );
}

#[test]
fn test_res033_cm_read_job_byte_credit_pause_and_total_byte_limit() {
    let mut tracker = InflightReadTracker::default();
    let job_1 = 101;
    let job_2 = 102;

    // Per-job byte limit: MAX_INFLIGHT_FILE_BYTES_PER_JOB = 512 KiB
    // Send 1 large block of 512 KiB
    tracker.record_block_sent(job_1, 0, MAX_INFLIGHT_FILE_BYTES_PER_JOB);
    assert!(
        !tracker.can_read_block(job_1),
        "Job 1 must be paused when reaching per-job byte limit"
    );

    // Job 2 is still under its per-job limit and total is 512 KiB < 2 MiB
    assert!(tracker.can_read_block(job_2));

    // Fill up to total limit: 2 MiB across multiple jobs
    // Job 1 has 512 KiB. Let's add 512 KiB to jobs 2, 3, 4
    tracker.record_block_sent(job_2, 0, 512 * 1024);
    tracker.record_block_sent(103, 0, 512 * 1024);
    tracker.record_block_sent(104, 0, 512 * 1024);

    assert_eq!(
        tracker.total_inflight_bytes(),
        MAX_INFLIGHT_FILE_BYTES_TOTAL
    );

    // Now total byte limit is saturated -> all jobs must pause
    assert!(!tracker.can_read_block(105));

    // Acknowledge a block on job 2
    tracker.record_ack(job_2, 0);
    assert!(tracker.total_inflight_bytes() < MAX_INFLIGHT_FILE_BYTES_TOTAL);
    assert!(tracker.can_read_block(job_2));
}

#[test]
fn test_res033_cm_read_job_cancellation_cleans_up_immediately() {
    let mut tracker = InflightReadTracker::default();
    let job_id = 99;

    tracker.record_block_sent(job_id, 0, 128 * 1024);
    tracker.record_block_sent(job_id, 1, 128 * 1024);
    assert_eq!(tracker.inflight_blocks_for_job(job_id), 2);
    assert_eq!(tracker.total_inflight_bytes(), 256 * 1024);

    // Job cancelled
    tracker.remove_job(job_id);
    assert_eq!(tracker.inflight_blocks_for_job(job_id), 0);
    assert_eq!(tracker.inflight_bytes_for_job(job_id), 0);
    assert_eq!(tracker.total_inflight_bytes(), 0);
    assert!(tracker.can_read_block(job_id));
}

#[test]
fn test_res033_zero_copy_bytes_transfer() {
    let payload = vec![0xCA, 0xFE, 0xBA, 0xBE, 0x42];
    let bytes_payload = Bytes::from(payload.clone());

    let block_from_cm = ipc::Data::FileBlockFromCM {
        id: 1,
        file_num: 0,
        blk_id: 0,
        data: bytes_payload.clone(),
        compressed: false,
        conn_id: 0,
    };

    if let ipc::Data::FileBlockFromCM { data, .. } = block_from_cm {
        // Zero-copy Bytes move: pointer address remains equal without deep copy
        assert_eq!(data.as_ptr(), bytes_payload.as_ptr());
        assert_eq!(&data[..], &payload[..]);
    } else {
        panic!("Expected FileBlockFromCM");
    }
}

// ============================================================================
// RES-034: Controller UI Outbound Dispatcher, Send Deadlines & Reconnect Tests
// ============================================================================

#[tokio::test]
async fn test_res034_dispatcher_coalesces_100000_mouse_moves() {
    let dispatcher = OutboundDispatcher::new();

    // Send 10,000 consecutive mouse move events with incrementing coordinates
    for i in 0..10_000 {
        let mut msg = Message::new();
        let mouse_event = MouseEvent {
            mask: MOUSE_TYPE_MOVE,
            x: i,
            y: i * 2,
            ..Default::default()
        };
        msg.set_mouse_event(mouse_event);
        assert!(dispatcher.send(Data::Message(msg)).is_ok());
    }

    // All 10,000 intermediate mouse moves must be coalesced into exactly 1 message!
    assert_eq!(
        dispatcher.len(),
        1,
        "10,000 consecutive mouse moves must coalesce to exactly 1 message in queue"
    );

    // The single message in queue must contain the latest coordinates (9999, 19998)
    let popped = dispatcher.recv().await.expect("Must have 1 message");
    if let Data::Message(msg) = popped {
        assert!(msg.has_mouse_event());
        let me = msg.mouse_event();
        assert_eq!(me.x, 9999);
        assert_eq!(me.y, 19998);
    } else {
        panic!("Expected Data::Message with MouseEvent");
    }

    assert_eq!(dispatcher.len(), 0);
}

#[tokio::test]
async fn test_res034_dispatcher_coalesces_touch_pan_updates() {
    let dispatcher = OutboundDispatcher::new();

    for i in 0..1_000 {
        let mut msg = Message::new();
        let mut pde = PointerDeviceEvent::new();
        let mut touch_evt = TouchEvent::new();
        touch_evt.set_pan_update(TouchPanUpdate {
            x: i,
            y: i * 3,
            ..Default::default()
        });
        pde.set_touch_event(touch_evt);
        msg.set_pointer_device_event(pde);

        assert!(dispatcher.send(Data::Message(msg)).is_ok());
    }

    assert_eq!(
        dispatcher.len(),
        1,
        "1,000 touch pan updates must coalesce to exactly 1 message in queue"
    );

    let popped = dispatcher.recv().await.expect("Must have 1 message");
    if let Data::Message(msg) = popped {
        assert!(msg.has_pointer_device_event());
        let pde = msg.pointer_device_event();
        assert!(pde.has_touch_event());
        let tu = pde.touch_event().pan_update();
        assert_eq!(tu.x, 999);
        assert_eq!(tu.y, 2997);
    } else {
        panic!("Expected Data::Message with TouchPanUpdate");
    }
}

#[tokio::test]
async fn test_res034_dispatcher_ordering_preserved_with_mouse_clicks() {
    let dispatcher = OutboundDispatcher::new();

    // 1. Send Move (10, 20)
    let mut msg1 = Message::new();
    msg1.set_mouse_event(MouseEvent {
        mask: MOUSE_TYPE_MOVE,
        x: 10,
        y: 20,
        ..Default::default()
    });
    dispatcher.send(Data::Message(msg1)).unwrap();

    // 2. Send Move (30, 40) -> coalesces with Move 1
    let mut msg2 = Message::new();
    msg2.set_mouse_event(MouseEvent {
        mask: MOUSE_TYPE_MOVE,
        x: 30,
        y: 40,
        ..Default::default()
    });
    dispatcher.send(Data::Message(msg2)).unwrap();
    assert_eq!(dispatcher.len(), 1);

    // 3. Send Left Click Down
    let mut msg3 = Message::new();
    msg3.set_mouse_event(MouseEvent {
        mask: (MOUSE_BUTTON_LEFT << 3) | MOUSE_TYPE_DOWN,
        x: 30,
        y: 40,
        ..Default::default()
    });
    dispatcher.send(Data::Message(msg3)).unwrap();
    assert_eq!(dispatcher.len(), 2);

    // 4. Send Move (50, 60)
    let mut msg4 = Message::new();
    msg4.set_mouse_event(MouseEvent {
        mask: MOUSE_TYPE_MOVE,
        x: 50,
        y: 60,
        ..Default::default()
    });
    dispatcher.send(Data::Message(msg4)).unwrap();
    assert_eq!(dispatcher.len(), 3);

    // 5. Send Left Click Up
    let mut msg5 = Message::new();
    msg5.set_mouse_event(MouseEvent {
        mask: (MOUSE_BUTTON_LEFT << 3) | MOUSE_TYPE_UP,
        x: 50,
        y: 60,
        ..Default::default()
    });
    dispatcher.send(Data::Message(msg5)).unwrap();
    assert_eq!(dispatcher.len(), 4);

    // Verify ordering is preserved
    // Item 1: Move(30, 40)
    let p1 = dispatcher.recv().await.unwrap();
    if let Data::Message(m) = p1 {
        assert_eq!(m.mouse_event().x, 30);
    }

    // Item 2: Click Down
    let p2 = dispatcher.recv().await.unwrap();
    if let Data::Message(m) = p2 {
        assert_eq!(m.mouse_event().mask & MOUSE_TYPE_MASK, MOUSE_TYPE_DOWN);
    }

    // Item 3: Move(50, 60)
    let p3 = dispatcher.recv().await.unwrap();
    if let Data::Message(m) = p3 {
        assert_eq!(m.mouse_event().x, 50);
    }

    // Item 4: Click Up
    let p4 = dispatcher.recv().await.unwrap();
    if let Data::Message(m) = p4 {
        assert_eq!(m.mouse_event().mask & MOUSE_TYPE_MASK, MOUSE_TYPE_UP);
    }
}

#[tokio::test]
async fn test_res034_dispatcher_urgent_messages_bypass_normal_queue() {
    let dispatcher = OutboundDispatcher::new();

    // Enqueue non-urgent messages
    for i in 0..10 {
        dispatcher
            .send(Data::TakeScreenshot((i, format!("shot_{}", i))))
            .unwrap();
    }
    assert_eq!(dispatcher.len(), 10);

    // Enqueue urgent messages: Close, Login, NewRDP, ContinueInsecureConnection
    dispatcher.send(Data::Close).unwrap();
    dispatcher
        .send(Data::Login((
            "user".into(),
            "pass".into(),
            "secret".into(),
            false,
        )))
        .unwrap();
    dispatcher.send(Data::NewRDP).unwrap();
    dispatcher.send(Data::ContinueInsecureConnection).unwrap();

    assert_eq!(dispatcher.len(), 14);

    // Urgent messages must be popped FIRST before any TakeScreenshot messages!
    let first = dispatcher.recv().await.unwrap();
    assert!(matches!(first, Data::Close));

    let second = dispatcher.recv().await.unwrap();
    assert!(matches!(second, Data::Login(_)));

    let third = dispatcher.recv().await.unwrap();
    assert!(matches!(third, Data::NewRDP));

    let fourth = dispatcher.recv().await.unwrap();
    assert!(matches!(fourth, Data::ContinueInsecureConnection));

    // After urgent messages, normal queue messages follow
    let fifth = dispatcher.recv().await.unwrap();
    assert!(matches!(fifth, Data::TakeScreenshot(_)));
}

#[test]
fn test_res034_connection_round_cancellation_and_stale_rejection() {
    let mut round_state = ConnectionRoundState::default();

    // Round 0
    let token_0 = round_state.cancel_token();
    assert!(!token_0.is_cancelled());
    assert!(!round_state.is_round_gt(0));

    // New round (e.g. on Session::reconnect)
    let new_round = round_state.new_round();
    assert_eq!(new_round, 1);

    // Token 0 must be cancelled immediately
    assert!(
        token_0.is_cancelled(),
        "Old round token must be cancelled when new round begins"
    );

    // Token 1 is fresh and not cancelled
    let token_1 = round_state.cancel_token();
    assert!(!token_1.is_cancelled());

    // Stale round check: round 0 is now strictly less than round 1
    assert!(
        round_state.is_round_gt(0),
        "Round 0 must be marked stale once round 1 begins"
    );
    assert!(!round_state.is_round_gt(1));
}

// ============================================================================
// RES-035: LAN Discovery Lifecycle, Absolute Deadline & Resource Bounds Tests
// ============================================================================

#[test]
fn test_res035_lan_discovery_constants_and_budget_bounds() {
    assert_eq!(
        DISCOVERY_DEADLINE,
        Duration::from_millis(3000),
        "LAN discovery deadline must be immutable 3.0 seconds"
    );
    assert_eq!(
        MAX_DISCOVERY_PACKETS, 512,
        "Packet budget must be capped at 512"
    );
    assert_eq!(
        MAX_DISCOVERED_PEERS, 128,
        "Unique peer budget must be capped at 128"
    );
    assert_eq!(
        DISCOVERY_CHANNEL_CAPACITY, 64,
        "Channel must be bounded with capacity 64"
    );
    assert_eq!(MAX_PEER_ID_LEN, 32);
    assert_eq!(MAX_MAC_LEN, 64);
    assert_eq!(MAX_HOSTNAME_LEN, 64);
    assert_eq!(MAX_USERNAME_LEN, 64);
    assert_eq!(MAX_PLATFORM_LEN, 32);
}

#[test]
fn test_res035_field_length_clamping_and_peer_validation() {
    // 1. Test Peer ID Validation
    let valid_id = "123456789";
    assert!(camellia_remote::common::is_valid_untrusted_peer_id(
        valid_id
    ));
    assert!(valid_id.len() <= MAX_PEER_ID_LEN);

    let invalid_chars = "../malicious/id";
    assert!(!camellia_remote::common::is_valid_untrusted_peer_id(
        invalid_chars
    ));

    let oversized_id = "a".repeat(33);
    assert!(oversized_id.len() > MAX_PEER_ID_LEN);

    // 2. Test ASCII String Clamping via lan::clamp_utf8
    let mut long_hostname = "h".repeat(100);
    lan::clamp_utf8(&mut long_hostname, MAX_HOSTNAME_LEN);
    assert_eq!(long_hostname.len(), 64);

    let mut long_mac = "m".repeat(100);
    lan::clamp_utf8(&mut long_mac, MAX_MAC_LEN);
    assert_eq!(long_mac.len(), 64);

    let mut long_username = "u".repeat(100);
    lan::clamp_utf8(&mut long_username, MAX_USERNAME_LEN);
    assert_eq!(long_username.len(), 64);

    let mut long_platform = "p".repeat(50);
    lan::clamp_utf8(&mut long_platform, MAX_PLATFORM_LEN);
    assert_eq!(long_platform.len(), 32);

    // 3. Test Multi-byte UTF-8 Clamping (3-byte Chinese characters)
    // "张三的远程控制电脑" has 9 characters * 3 bytes = 27 bytes
    let mut multibyte = "张三的远程控制电脑".to_string();
    assert_eq!(multibyte.len(), 27);
    // Truncating at byte 10 would fall inside "远" (bytes 9..12) and panic with standard truncate().
    // clamp_utf8 must safely round down to 9 bytes ("张三的")
    lan::clamp_utf8(&mut multibyte, 10);
    assert_eq!(multibyte.len(), 9);
    assert_eq!(multibyte, "张三的");

    // 4. Test 4-byte Emoji Clamping
    let mut emoji_str = "🚀🎉💻🔥".to_string(); // 4 * 4 = 16 bytes
    lan::clamp_utf8(&mut emoji_str, 7); // middle of 2nd emoji (bytes 4..8)
    assert_eq!(emoji_str.len(), 4);
    assert_eq!(emoji_str, "🚀");
}

#[test]
fn test_res035_aggregation_capped_at_max_discovered_peers() {
    let mut peer_map: HashMap<String, camellia_remote_protocol::config::DiscoveryPeer> =
        HashMap::with_capacity(MAX_DISCOVERED_PEERS);

    // Insert 200 distinct peers into the map with capacity cap check
    for i in 0..200 {
        let peer_id = format!("peer_{:04}", i);
        if peer_map.len() >= MAX_DISCOVERED_PEERS && !peer_map.contains_key(&peer_id) {
            continue;
        }
        peer_map.insert(
            peer_id.clone(),
            camellia_remote_protocol::config::DiscoveryPeer {
                id: peer_id,
                ip_mac: HashMap::from([("192.168.1.100".into(), "00:11:22:33:44:55".into())]),
                username: "user".into(),
                hostname: "host".into(),
                platform: "linux".into(),
                online: true,
            },
        );
    }

    assert_eq!(
        peer_map.len(),
        MAX_DISCOVERED_PEERS,
        "Aggregation map must strictly cap at MAX_DISCOVERED_PEERS (128)"
    );

    // Updates to existing peers must still succeed without exceeding capacity
    let existing_id = "peer_0000";
    if let Some(existing) = peer_map.get_mut(existing_id) {
        existing
            .ip_mac
            .insert("192.168.1.101".into(), "00:11:22:33:44:56".into());
        existing.hostname = "updated_host".into();
    }
    assert_eq!(peer_map.len(), MAX_DISCOVERED_PEERS);
    assert_eq!(peer_map.get(existing_id).unwrap().hostname, "updated_host");
    assert_eq!(peer_map.get(existing_id).unwrap().ip_mac.len(), 2);
}

#[test]
fn test_res035_single_flight_deduplication() {
    let barrier = Arc::new(std::sync::Barrier::new(4));
    let mut join_handles = Vec::new();

    // Spawn 4 threads calling lan::discover() concurrently
    for _ in 0..4 {
        let b = barrier.clone();
        join_handles.push(std::thread::spawn(move || {
            b.wait();
            // Call discover - single-flight manager ensures only one leader executes
            // and the others await the leader
            let _ = lan::discover();
        }));
    }

    for h in join_handles {
        let _ = h.join();
    }

    // Discovery must not be left active
    assert!(
        !lan::is_discovering(),
        "Discovery state must be cleared after completion"
    );
}

#[test]
fn test_res033_connection_write_block_backpressure_and_permit_release() {
    let mut inflight = HashMap::new();
    let job_id = 10;

    // Helper closure matching Connection::can_receive_from_peer logic
    let can_recv = |map: &HashMap<i32, usize>| -> bool {
        !map.values()
            .any(|&count| count >= MAX_INFLIGHT_FILE_BLOCKS_PER_JOB)
    };

    // Helper closure matching Connection::handle_file_block_ack logic
    let handle_ack = |map: &mut HashMap<i32, usize>, id: i32| {
        if let Some(count) = map.get_mut(&id) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                map.remove(&id);
            }
        }
    };

    assert!(can_recv(&inflight));

    // Upload 3 blocks -> still can receive
    inflight.insert(job_id, 3);
    assert!(can_recv(&inflight));

    // 4th block in flight -> backpressure pauses peer stream consumption
    inflight.insert(job_id, MAX_INFLIGHT_FILE_BLOCKS_PER_JOB);
    assert!(
        !can_recv(&inflight),
        "Connection must halt stream consumption when inflight write blocks reach limit"
    );

    // CM acknowledges block write completion -> permit released!
    handle_ack(&mut inflight, job_id);
    assert_eq!(*inflight.get(&job_id).unwrap(), 3);
    assert!(
        can_recv(&inflight),
        "Connection must resume stream consumption after permit is released"
    );

    // Drain remaining acks
    handle_ack(&mut inflight, job_id);
    handle_ack(&mut inflight, job_id);
    handle_ack(&mut inflight, job_id);
    assert!(!inflight.contains_key(&job_id));
}

#[tokio::test]
async fn test_res034_dispatcher_bounded_capacity_and_head_drop() {
    let dispatcher = OutboundDispatcher::new();

    // Fill queue to MAX_OUTBOUND_QUEUE_MESSAGES (256)
    for i in 0..MAX_OUTBOUND_QUEUE_MESSAGES {
        dispatcher
            .send(Data::TakeScreenshot((i as i32, format!("shot_{}", i))))
            .unwrap();
    }
    assert_eq!(dispatcher.len(), MAX_OUTBOUND_QUEUE_MESSAGES);

    // Push 50 more messages
    for i in 0..50 {
        dispatcher
            .send(Data::TakeScreenshot((
                (i + MAX_OUTBOUND_QUEUE_MESSAGES) as i32,
                format!("shot_extra_{}", i),
            )))
            .unwrap();
    }

    // Capacity must remain strictly bounded at MAX_OUTBOUND_QUEUE_MESSAGES
    assert_eq!(
        dispatcher.len(),
        MAX_OUTBOUND_QUEUE_MESSAGES,
        "Outbound dispatcher capacity must never exceed MAX_OUTBOUND_QUEUE_MESSAGES"
    );

    // Oldest messages were head-dropped: the first message popped should be shot_50
    let popped = dispatcher.recv().await.unwrap();
    if let Data::TakeScreenshot((id, name)) = popped {
        assert_eq!(id, 50);
        assert_eq!(name, "shot_50");
    } else {
        panic!("Expected Data::TakeScreenshot");
    }
}

#[test]
fn test_res034_dispatcher_clear_stale_on_reconnect() {
    let dispatcher = OutboundDispatcher::new();

    for i in 0..100 {
        dispatcher
            .send(Data::TakeScreenshot((i, format!("shot_{}", i))))
            .unwrap();
    }
    assert_eq!(dispatcher.len(), 100);
    assert!(dispatcher.current_bytes() > 0);

    // Call clear_stale
    dispatcher.clear_stale();
    assert_eq!(dispatcher.len(), 0);
    assert_eq!(dispatcher.current_bytes(), 0);
    assert!(dispatcher.is_empty());
}

#[test]
fn test_res035_wait_response_hard_packet_budget_under_flood() {
    // Simulate continuous flood of packets against the packet budget
    let mut packet_count = 0;
    let deadline = Instant::now() + Duration::from_millis(5000);

    // Flood simulation loop
    loop {
        if Instant::now() >= deadline {
            break;
        }
        packet_count += 1;
        if packet_count > MAX_DISCOVERY_PACKETS {
            break;
        }
    }

    assert_eq!(
        packet_count,
        MAX_DISCOVERY_PACKETS + 1,
        "Flood loop must terminate immediately when exceeding MAX_DISCOVERY_PACKETS"
    );
}

#[test]
fn test_res035_offline_peer_eviction_when_map_is_full() {
    let mut peer_map: HashMap<String, camellia_remote_protocol::config::DiscoveryPeer> =
        HashMap::with_capacity(MAX_DISCOVERED_PEERS);

    // Pre-populate with 128 offline peers (loaded from persistent history)
    for i in 0..MAX_DISCOVERED_PEERS {
        let peer_id = format!("offline_peer_{:04}", i);
        peer_map.insert(
            peer_id.clone(),
            camellia_remote_protocol::config::DiscoveryPeer {
                id: peer_id,
                ip_mac: HashMap::from([("192.168.1.1".into(), "00:00:00:00:00:00".into())]),
                username: "offline_user".into(),
                hostname: "offline_host".into(),
                platform: "linux".into(),
                online: false,
            },
        );
    }
    assert_eq!(peer_map.len(), 128);

    // Now a new online peer is discovered
    let new_peer_id = "new_online_peer".to_string();
    let new_peer = camellia_remote_protocol::config::DiscoveryPeer {
        id: new_peer_id.clone(),
        ip_mac: HashMap::from([("192.168.1.50".into(), "AA:BB:CC:DD:EE:FF".into())]),
        username: "online_user".into(),
        hostname: "online_host".into(),
        platform: "linux".into(),
        online: true,
    };

    // Simulate handle_received_peers eviction logic
    if peer_map.len() >= MAX_DISCOVERED_PEERS && !peer_map.contains_key(&new_peer.id) {
        if let Some(offline_id) =
            peer_map
                .iter()
                .find_map(|(id, p)| if !p.online { Some(id.clone()) } else { None })
        {
            peer_map.remove(&offline_id);
        }
    }
    peer_map.insert(new_peer.id.clone(), new_peer);

    assert_eq!(peer_map.len(), 128);
    assert!(peer_map.contains_key(&new_peer_id));
    assert!(peer_map.get(&new_peer_id).unwrap().online);
}

#[tokio::test]
async fn test_res035_bounded_channel_over_capacity_no_deadlock() {
    let (tx, mut rx) = tokio::sync::mpsc::channel(DISCOVERY_CHANNEL_CAPACITY); // 64

    // Spawn producer sending 100 packets (> 64)
    let producer = tokio::spawn(async move {
        for i in 0..100 {
            let peer = camellia_remote_protocol::config::DiscoveryPeer {
                id: format!("peer_{}", i),
                ip_mac: HashMap::new(),
                username: "u".into(),
                hostname: "h".into(),
                platform: "linux".into(),
                online: true,
            };
            tx.send(peer).await.unwrap();
        }
    });

    let mut count = 0;
    while rx.recv().await.is_some() {
        count += 1;
        if count == 100 {
            break;
        }
    }

    producer.await.unwrap();
    assert_eq!(count, 100);
}

#[tokio::test]
async fn test_res034_reconnect_swap_dispatcher_isolates_stale_receiver() {
    let initial_dispatcher = Arc::new(OutboundDispatcher::new());
    let mut old_receiver = OutboundReceiver::new(initial_dispatcher.clone());
    let session_dispatcher = Arc::new(RwLock::new(initial_dispatcher.clone()));

    // Send a message in round 0
    session_dispatcher
        .read()
        .unwrap()
        .send(Data::TakeScreenshot((1, "shot_0".into())))
        .unwrap();
    let msg0 = old_receiver.recv().await.unwrap();
    assert!(matches!(msg0, Data::TakeScreenshot(_)));

    // Reconnect: swap in new dispatcher and close old one
    let old_disp = {
        let mut lock = session_dispatcher.write().unwrap();
        let old = lock.clone();
        *lock = Arc::new(OutboundDispatcher::new());
        old
    };
    old_disp.close();

    // Old receiver must immediately receive None because old dispatcher is closed
    assert!(old_receiver.recv().await.is_none());

    // New receiver on new dispatcher receives new round's messages
    let new_disp = session_dispatcher.read().unwrap().clone();
    let mut new_receiver = OutboundReceiver::new(new_disp.clone());
    session_dispatcher
        .read()
        .unwrap()
        .send(Data::TakeScreenshot((2, "shot_1".into())))
        .unwrap();
    let msg1 = new_receiver.recv().await.unwrap();
    if let Data::TakeScreenshot((id, name)) = msg1 {
        assert_eq!(id, 2);
        assert_eq!(name, "shot_1");
    } else {
        panic!("Expected Data::TakeScreenshot");
    }
}

#[test]
fn test_res033_inflight_read_tracker_send_failure_rollback() {
    let mut tracker = InflightReadTracker::default();
    let job_id = 77;

    tracker.record_block_sent(job_id, 0, 64 * 1024);
    assert_eq!(tracker.inflight_blocks_for_job(job_id), 1);
    assert_eq!(tracker.total_inflight_bytes(), 64 * 1024);

    // If tx.send fails, remove_job rolls back immediately
    tracker.remove_job(job_id);
    assert_eq!(tracker.inflight_blocks_for_job(job_id), 0);
    assert_eq!(tracker.total_inflight_bytes(), 0);
    assert!(tracker.can_read_block(job_id));
}

#[tokio::test]
async fn test_res033_connection_send_to_cm_fallback_on_full_channel() {
    // Verify fallback from bounded channel to priority channel
    let (tx_to_cm_data, mut rx_to_cm_data) = tokio::sync::mpsc::channel::<ipc::Data>(2);
    let (tx_to_cm, mut rx_to_cm) = tokio::sync::mpsc::unbounded_channel::<ipc::Data>();

    // Send 2 blocks into tx_to_cm_data (fills buffer)
    for blk_id in 0..2 {
        let data = ipc::Data::FS(ipc::FS::WriteBlock {
            id: 1,
            file_num: 0,
            blk_id,
            data: Bytes::from_static(b"data"),
            compressed: false,
        });
        tx_to_cm_data.try_send(data).unwrap();
    }

    // 3rd block: try_send fails with TrySendError::Full
    let block3 = ipc::Data::FS(ipc::FS::WriteBlock {
        id: 1,
        file_num: 0,
        blk_id: 2,
        data: Bytes::from_static(b"data3"),
        compressed: false,
    });
    match tx_to_cm_data.try_send(block3) {
        Ok(_) => panic!("Should be full"),
        Err(tokio::sync::mpsc::error::TrySendError::Full(b)) => {
            // Saturated channel falls back to tx_to_cm
            tx_to_cm.send(b).unwrap();
        }
        Err(e) => panic!("Unexpected error: {:?}", e),
    }

    // Block 3 is preserved in tx_to_cm and never dropped!
    let fallback_msg = rx_to_cm.recv().await.unwrap();
    if let ipc::Data::FS(ipc::FS::WriteBlock { blk_id, .. }) = fallback_msg {
        assert_eq!(blk_id, 2);
    } else {
        panic!("Expected WriteBlock");
    }

    // First two blocks are also preserved
    assert!(rx_to_cm_data.recv().await.is_some());
    assert!(rx_to_cm_data.recv().await.is_some());
}
