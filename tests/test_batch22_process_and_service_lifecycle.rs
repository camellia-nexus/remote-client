// Client Batch 22 Process & Service Lifecycle Safety Tests
// Target Items:
// 1. UNSAFE-008 (P2): Linux GTK sudo PTY master dual fd owner
// 2. RES-038 (P2): Clipboard listener unbounded queue and coalescing subscriber model
// 3. RES-043 (P2): Cursor position worker single-flight and generation fencing

use camellia_remote::clipboard::clipboard_listener::clipboard_channel;
use camellia_remote::server::input_service::{
    get_cursor_record_generation, get_last_cursor_pos, is_cursor_record_running,
    stop_record_cursor_pos_force, try_start_record_cursor_pos, try_stop_record_cursor_pos,
    update_last_cursor_pos, CursorRecordSupervisor, INVALID_CURSOR_POS,
};
use clipboard_master::CallbackResult;
#[cfg(target_os = "linux")]
use std::fs::File;
#[cfg(target_os = "linux")]
use std::io::{Read, Write};
#[cfg(target_os = "linux")]
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Barrier, Mutex};
use std::thread;
use std::time::{Duration, Instant};

// Global serial lock to avoid parallel test races on process-global cursor statics
static CURSOR_TEST_MUTEX: Mutex<()> = Mutex::new(());

// =========================================================================
// 1. UNSAFE-008: Linux GTK Sudo PTY Master Single Ownership Tests
// =========================================================================

#[test]
#[cfg(target_os = "linux")]
fn test_gtk_sudo_pty_master_single_owner() {
    use nix::unistd::pipe;

    // Create a real pipe to obtain valid OwnedFd instances
    let (read_fd, write_fd) = pipe().expect("pipe creation should succeed");
    let raw_read_fd = read_fd.as_raw_fd();
    let raw_write_fd = write_fd.as_raw_fd();

    // Verify initial file descriptors are valid
    assert!(unsafe { nix::libc::fcntl(raw_read_fd, nix::libc::F_GETFD) } >= 0);
    assert!(unsafe { nix::libc::fcntl(raw_write_fd, nix::libc::F_GETFD) } >= 0);

    // Transfer single ownership of read_fd into File via master_to_file
    let mut file = camellia_remote::platform::gtk_sudo::master_to_file(read_fd);
    assert_eq!(file.as_raw_fd(), raw_read_fd);

    // Write data via write_fd and read from transferred file
    let mut write_file = File::from(write_fd);
    write_file
        .write_all(b"single ownership transfer test")
        .expect("write to pipe should succeed");
    drop(write_file); // Closes write end

    let mut content = Vec::new();
    file.read_to_end(&mut content)
        .expect("read from transferred file should succeed");
    assert_eq!(&content, b"single ownership transfer test");

    // Drop file (the sole owner of raw_read_fd)
    drop(file);

    // Verify descriptor has been closed exactly once and is no longer valid (EBADF)
    let getfd_res = unsafe { nix::libc::fcntl(raw_read_fd, nix::libc::F_GETFD) };
    assert_eq!(
        getfd_res, -1,
        "read_fd should be closed after single owner File is dropped"
    );
    let errno = std::io::Error::last_os_error().raw_os_error();
    assert_eq!(errno, Some(nix::libc::EBADF));
}

// =========================================================================
// 2. RES-038: Clipboard Listener Coalescing & Preemption Tests
// =========================================================================

#[test]
fn test_clipboard_listener_coalescing() {
    let (tx, rx) = clipboard_channel();

    // Rapidly send 10,000 Next notifications
    for _ in 0..10_000 {
        tx.send(CallbackResult::Next)
            .expect("send should succeed while open");
    }

    // First receive must yield Next
    let res = rx.recv_timeout(Duration::from_millis(100));
    assert!(
        matches!(res, Ok(CallbackResult::Next)),
        "Expected Ok(CallbackResult::Next)"
    );

    // Second receive must time out because all 9,999 subsequent Nexts were coalesced!
    let res2 = rx.recv_timeout(Duration::from_millis(50));
    assert!(
        matches!(res2, Err(RecvTimeoutError::Timeout)),
        "Coalesced queue should be empty after single consumption"
    );

    // Another batch of 10,000 Nexts must again coalesce to exactly 1 event
    for _ in 0..10_000 {
        tx.send(CallbackResult::Next)
            .expect("send should succeed while open");
    }

    let res3 = rx.recv_timeout(Duration::from_millis(100));
    assert!(matches!(res3, Ok(CallbackResult::Next)));

    let res4 = rx.recv_timeout(Duration::from_millis(50));
    assert!(matches!(res4, Err(RecvTimeoutError::Timeout)));
}

#[test]
fn test_clipboard_listener_stop_preemption() {
    // 1. Stop preempts pending Next
    let (tx, rx) = clipboard_channel();
    tx.send(CallbackResult::Next).unwrap();
    tx.send(CallbackResult::Stop).unwrap();
    assert!(
        tx.send(CallbackResult::Next).is_err(),
        "send after Stop must be rejected"
    );

    let res = rx.recv_timeout(Duration::from_millis(100));
    assert!(
        matches!(res, Ok(CallbackResult::Stop)),
        "Stop notification must preempt pending Next notification"
    );
    // After Stop, subsequent recv must be Disconnected, NEVER a ghost Next
    let res_after = rx.recv_timeout(Duration::from_millis(50));
    assert!(
        matches!(res_after, Err(RecvTimeoutError::Disconnected)),
        "Channel must report Disconnected after Stop, without delivering ghost Next"
    );

    // 2. StopWithError preempts pending Next
    let (tx2, rx2) = clipboard_channel();
    for _ in 0..500 {
        tx2.send(CallbackResult::Next).unwrap();
    }
    tx2.send(CallbackResult::StopWithError(std::io::Error::new(
        std::io::ErrorKind::ConnectionReset,
        "preemption test error",
    )))
    .unwrap();

    let res2 = rx2.recv_timeout(Duration::from_millis(100));
    match res2 {
        Ok(CallbackResult::StopWithError(err)) => {
            assert_eq!(err.kind(), std::io::ErrorKind::ConnectionReset);
            assert_eq!(err.to_string(), "preemption test error");
        }
        _ => panic!("Expected StopWithError"),
    }
    let res2_after = rx2.recv_timeout(Duration::from_millis(50));
    assert!(
        matches!(res2_after, Err(RecvTimeoutError::Disconnected)),
        "Channel must report Disconnected after StopWithError"
    );

    // 3. Threaded wake-up preemption
    let (tx3, rx3) = clipboard_channel();
    let rx3 = Arc::new(rx3);
    let rx3_clone = rx3.clone();

    let join_handle = thread::spawn(move || {
        let start = Instant::now();
        let res = rx3_clone.recv_timeout(Duration::from_secs(5));
        (matches!(res, Ok(CallbackResult::Stop)), start.elapsed())
    });

    // Ensure the thread is waiting
    thread::sleep(Duration::from_millis(50));
    tx3.send(CallbackResult::Stop).unwrap();

    let (was_stop, elapsed) = join_handle.join().expect("receiver thread should join");
    assert!(was_stop, "Receiver must wake up with Stop");
    assert!(
        elapsed < Duration::from_secs(2),
        "Receiver must wake up immediately on Stop, elapsed: {:?}",
        elapsed
    );

    // 4. close() preempts pending Next and signals Stop followed by Disconnected
    let (tx4, rx4) = clipboard_channel();
    tx4.send(CallbackResult::Next).unwrap();
    tx4.close();
    let res4 = rx4.recv_timeout(Duration::from_millis(100));
    assert!(
        matches!(res4, Ok(CallbackResult::Stop)),
        "close() must deliver Stop"
    );
    let res4_after = rx4.recv_timeout(Duration::from_millis(50));
    assert!(
        matches!(res4_after, Err(RecvTimeoutError::Disconnected)),
        "Subsequent recv after close must be Disconnected"
    );
}

#[test]
fn test_clipboard_listener_multi_subscriber_isolation() {
    let (tx1, rx1) = clipboard_channel();
    let (tx2, rx2) = clipboard_channel();
    let (tx3, rx3) = clipboard_channel();

    // Send 100 Nexts to all three channels
    for _ in 0..100 {
        tx1.send(CallbackResult::Next).unwrap();
        tx2.send(CallbackResult::Next).unwrap();
        tx3.send(CallbackResult::Next).unwrap();
    }

    // Subscriber 1 drains its single coalesced Next
    assert!(matches!(
        rx1.recv_timeout(Duration::from_millis(100)),
        Ok(CallbackResult::Next)
    ));
    assert!(matches!(
        rx1.recv_timeout(Duration::from_millis(30)),
        Err(RecvTimeoutError::Timeout)
    ));

    // Subscriber 2 receives Stop
    tx2.send(CallbackResult::Stop).unwrap();
    assert!(matches!(
        rx2.recv_timeout(Duration::from_millis(100)),
        Ok(CallbackResult::Stop)
    ));

    // Subscriber 3 is completely unaffected and receives its coalesced Next
    assert!(matches!(
        rx3.recv_timeout(Duration::from_millis(100)),
        Ok(CallbackResult::Next)
    ));
    assert!(matches!(
        rx3.recv_timeout(Duration::from_millis(30)),
        Err(RecvTimeoutError::Timeout)
    ));

    // Disconnecting tx1 results in Disconnected on rx1
    drop(tx1);
    assert!(matches!(
        rx1.recv_timeout(Duration::from_millis(100)),
        Err(RecvTimeoutError::Disconnected)
    ));

    // Subscriber 3 still functions independently
    tx3.send(CallbackResult::Next).unwrap();
    assert!(matches!(
        rx3.recv_timeout(Duration::from_millis(100)),
        Ok(CallbackResult::Next)
    ));
}

#[test]
fn test_clipboard_listener_receiver_drop_closes_sender() {
    let (tx, rx) = clipboard_channel();
    assert!(tx.send(CallbackResult::Next).is_ok());

    // Drop receiver
    drop(rx);

    // Subsequent sends must be rejected
    assert!(tx.send(CallbackResult::Next).is_err());
}

// =========================================================================
// 3. RES-043: Cursor Position Worker Single-Flight & Generation Fencing Tests
// =========================================================================

#[test]
fn test_cursor_position_worker_single_flight() {
    // 1. Verify supervisor level single-flight guarantee
    let supervisor = Arc::new(Mutex::new(CursorRecordSupervisor::new()));
    let thread_count = 32;
    let barrier = Arc::new(Barrier::new(thread_count));
    let success_count = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::new();
    for _ in 0..thread_count {
        let sup = supervisor.clone();
        let bar = barrier.clone();
        let counter = success_count.clone();

        handles.push(thread::spawn(move || {
            bar.wait();
            if sup.lock().unwrap().start().is_some() {
                counter.fetch_add(1, Ordering::SeqCst);
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(
        success_count.load(Ordering::SeqCst),
        1,
        "Exactly 1 concurrent start call must succeed under single flight"
    );
    assert!(supervisor.lock().unwrap().is_running());

    // 2. Stopping allows a subsequent start to succeed
    let worker = supervisor.lock().unwrap().stop();
    assert!(worker.is_some());
    assert!(!supervisor.lock().unwrap().is_running());

    let second_start = supervisor.lock().unwrap().start();
    assert!(second_start.is_some());
    assert_eq!(second_start.unwrap().0, 2); // Generation incremented
    supervisor.lock().unwrap().stop();
}

#[test]
fn test_cursor_position_worker_generation_fencing() {
    let _lock = CURSOR_TEST_MUTEX.lock().unwrap();

    let mut supervisor = CursorRecordSupervisor::new();

    // Start Generation 1
    let (gen1, stop1) = supervisor.start().expect("gen 1 start should succeed");
    assert_eq!(gen1, 1);
    assert!(supervisor.is_generation_current(gen1));
    assert!(!stop1.load(Ordering::SeqCst));

    // Stop Generation 1
    let stopped = supervisor.stop().expect("stop should return active worker");
    assert!(stopped.stop_signal.load(Ordering::SeqCst));
    assert!(stop1.load(Ordering::SeqCst));

    // Rapid restart: Start Generation 2 before Gen 1 cleanup completes
    let (gen2, stop2) = supervisor.start().expect("gen 2 start should succeed");
    assert_eq!(gen2, 2);
    assert!(supervisor.is_generation_current(gen2));

    // Stale Gen 1 check must be fenced out!
    assert!(
        !supervisor.is_generation_current(gen1),
        "Stale gen 1 worker must be fenced out by generation bump"
    );
    assert!(supervisor.is_generation_current(gen2));

    // Verify coordinate clobber fencing logic
    update_last_cursor_pos(800, 600);
    assert_eq!(get_last_cursor_pos(), (800, 600));

    // Simulated worker 1 exit with generation fencing
    let worker1_can_invalidate = supervisor.is_generation_current(gen1);
    if worker1_can_invalidate {
        update_last_cursor_pos(INVALID_CURSOR_POS, INVALID_CURSOR_POS);
    }
    assert!(
        !worker1_can_invalidate,
        "Worker 1 must not be allowed to invalidate coordinates"
    );
    assert_eq!(
        get_last_cursor_pos(),
        (800, 600),
        "Stale worker 1 must NOT clobber active session coordinates"
    );

    // Simulated worker 2 exit with matching generation
    let worker2_can_invalidate = supervisor.is_generation_current(gen2);
    if worker2_can_invalidate {
        update_last_cursor_pos(INVALID_CURSOR_POS, INVALID_CURSOR_POS);
    }
    assert!(
        worker2_can_invalidate,
        "Current worker 2 must be allowed to invalidate coordinates"
    );
    assert_eq!(
        get_last_cursor_pos(),
        (INVALID_CURSOR_POS, INVALID_CURSOR_POS),
        "Matching generation must reset coordinates upon clean exit"
    );

    supervisor.stop();
    assert!(stop2.load(Ordering::SeqCst));
}

#[test]
fn test_cursor_position_global_service_lifecycle() {
    let _lock = CURSOR_TEST_MUTEX.lock().unwrap();

    stop_record_cursor_pos_force();

    let initial_gen = get_cursor_record_generation();

    // Start global service worker
    let handle1 = try_start_record_cursor_pos();
    assert!(handle1.is_some(), "First start should spawn worker");
    assert!(is_cursor_record_running());
    assert_eq!(get_cursor_record_generation(), initial_gen + 1);

    // Concurrent second start should return None (single flight)
    let handle2 = try_start_record_cursor_pos();
    assert!(handle2.is_none(), "Concurrent start must return None");
    assert_eq!(get_cursor_record_generation(), initial_gen + 1);

    // Stop service forcibly
    stop_record_cursor_pos_force();
    assert!(!is_cursor_record_running());

    // Join handle1
    if let Some(h) = handle1 {
        h.join().expect("Worker thread should terminate cleanly");
    }

    // Coordinates should be reset to INVALID_CURSOR_POS after gen exit
    assert_eq!(
        get_last_cursor_pos(),
        (INVALID_CURSOR_POS, INVALID_CURSOR_POS)
    );
}

#[test]
fn test_cursor_position_atomic_stop_with_authed_conns() {
    use camellia_remote::server::{AuthConnType, AuthedConn, SessionKey, AUTHED_CONNS};
    use camellia_remote_protocol::tokio::sync::mpsc::unbounded_channel;

    let _lock = CURSOR_TEST_MUTEX.lock().unwrap();
    stop_record_cursor_pos_force();

    // Start cursor recording
    let handle = try_start_record_cursor_pos();
    assert!(handle.is_some());
    assert!(is_cursor_record_running());

    // Inject active remote connection into AUTHED_CONNS
    let (tx, _rx) = unbounded_channel();
    let conn = AuthedConn {
        conn_id: 99999,
        conn_type: AuthConnType::Remote,
        session_key: SessionKey::new("peer1".to_string(), "sess1".to_string(), 12345),
        sender: tx,
        printer: false,
    };
    AUTHED_CONNS.lock().unwrap().push(conn);

    // try_stop_record_cursor_pos should NOT stop the worker because remote_count == 1
    try_stop_record_cursor_pos();
    assert!(
        is_cursor_record_running(),
        "Worker must not stop when active remote connection exists"
    );

    // Remove the remote connection
    AUTHED_CONNS.lock().unwrap().retain(|c| c.conn_id != 99999);

    // Now try_stop_record_cursor_pos should stop the worker
    try_stop_record_cursor_pos();
    assert!(
        !is_cursor_record_running(),
        "Worker must stop when remote_count == 0"
    );

    if let Some(h) = handle {
        h.join().unwrap();
    }
}

#[test]
fn test_cursor_position_worker_real_thread_generation_fencing() {
    let _lock = CURSOR_TEST_MUTEX.lock().unwrap();
    stop_record_cursor_pos_force();

    // 1. Start Generation 1 real thread
    let handle1 = try_start_record_cursor_pos().expect("Gen 1 must start");
    let gen1 = get_cursor_record_generation();

    // Set cursor coordinates
    update_last_cursor_pos(300, 400);
    assert_eq!(get_last_cursor_pos(), (300, 400));

    // Rapid restart: stop Gen 1 and immediately start Gen 2
    stop_record_cursor_pos_force();
    let handle2 = try_start_record_cursor_pos().expect("Gen 2 must start");
    let gen2 = get_cursor_record_generation();
    assert_eq!(gen2, gen1 + 1);

    // Set new cursor coordinates for Gen 2
    update_last_cursor_pos(500, 600);
    assert_eq!(get_last_cursor_pos(), (500, 600));

    // Wait for Gen 1 thread to exit
    handle1.join().expect("Gen 1 thread should join cleanly");

    // Coordinates must NOT be reset by Gen 1 thread exiting!
    assert_eq!(
        get_last_cursor_pos(),
        (500, 600),
        "Gen 1 worker exit must NOT clobber Gen 2 coordinates"
    );

    // Stop Gen 2
    stop_record_cursor_pos_force();
    handle2.join().expect("Gen 2 thread should join cleanly");

    // Now that current generation exited, coordinates must be reset
    assert_eq!(
        get_last_cursor_pos(),
        (INVALID_CURSOR_POS, INVALID_CURSOR_POS),
        "Current Gen 2 worker exit must reset coordinates to INVALID"
    );
}
