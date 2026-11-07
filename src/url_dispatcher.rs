//! Bounded URL and reopen event dispatcher with single-flight fallback GUI supervision (RES-044).
//!
//! Prevents unbounded OS thread creation, Tokio runtime proliferation, and duplicate fallback GUI
//! process spawning when multiple URLs or rapid reopen/dock clicks arrive.

use camellia_remote_protocol::log;
use std::{
    collections::VecDeque,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

pub const MAX_URL_LEN: usize = 4096;
pub const MAX_URL_QUEUE_CAPACITY: usize = 16;
pub const REOPEN_DEBOUNCE_DURATION: Duration = Duration::from_millis(800);
pub const FALLBACK_COOLDOWN_DURATION: Duration = Duration::from_secs(5);

struct DispatcherInner {
    queue: VecDeque<String>,
    last_reopen: Option<Instant>,
    last_fallback_spawn: Option<Instant>,
    worker_running: bool,
    generation: u64,
}

struct UrlDispatcher {
    state: Mutex<DispatcherInner>,
    cvar: Condvar,
    stop_worker: AtomicBool,
}

camellia_remote_protocol::lazy_static::lazy_static! {
    static ref DISPATCHER: Arc<UrlDispatcher> = Arc::new(UrlDispatcher {
        state: Mutex::new(DispatcherInner {
            queue: VecDeque::new(),
            last_reopen: None,
            last_fallback_spawn: None,
            worker_running: false,
            generation: 1,
        }),
        cvar: Condvar::new(),
        stop_worker: AtomicBool::new(false),
    });
}

/// Enqueue a URL for dispatching.
/// Returns `true` if accepted, `false` if rejected (e.g. over length or queue full).
pub fn enqueue_url(url: String) -> bool {
    if url.len() > MAX_URL_LEN {
        log::warn!(
            "Rejecting URL exceeding maximum length bound ({} > {})",
            url.len(),
            MAX_URL_LEN
        );
        return false;
    }

    let dispatcher = &DISPATCHER;
    let mut state = dispatcher.state.lock().unwrap();

    // If empty URL (reopen signal), apply debounce
    if url.is_empty() {
        if let Some(last) = state.last_reopen {
            if last.elapsed() < REOPEN_DEBOUNCE_DURATION {
                log::debug!("Debouncing rapid reopen / dock click event");
                return true;
            }
        }
        state.last_reopen = Some(Instant::now());
    }

    if state.queue.len() >= MAX_URL_QUEUE_CAPACITY {
        log::warn!(
            "URL dispatcher queue is full ({}/{}), dropping URL",
            state.queue.len(),
            MAX_URL_QUEUE_CAPACITY
        );
        return false;
    }

    state.queue.push_back(url);
    ensure_worker_running(&mut state, dispatcher);
    dispatcher.cvar.notify_one();
    true
}

/// Enqueue a dock icon click / reopen event.
/// Deduplicates rapid clicks within `REOPEN_DEBOUNCE_DURATION`.
pub fn enqueue_reopen() -> bool {
    enqueue_url(String::new())
}

/// Helper matching legacy `crate::handle_url_scheme` interface.
pub fn handle_url_scheme(url: String) {
    enqueue_url(url);
}

/// Returns the number of items currently pending in the dispatcher queue.
pub fn queue_len() -> usize {
    let state = DISPATCHER.state.lock().unwrap();
    state.queue.len()
}

/// Clears all pending URLs from the dispatcher queue.
pub fn clear_queue() {
    let mut state = DISPATCHER.state.lock().unwrap();
    state.queue.clear();
}

/// Monotonically increment dispatcher generation.
pub fn bump_generation() -> u64 {
    let mut state = DISPATCHER.state.lock().unwrap();
    state.generation += 1;
    state.generation
}

fn ensure_worker_running(state: &mut DispatcherInner, dispatcher: &Arc<UrlDispatcher>) {
    if !state.worker_running {
        state.worker_running = true;
        dispatcher.stop_worker.store(false, Ordering::SeqCst);
        let d = dispatcher.clone();
        thread::Builder::new()
            .name("url_dispatcher".to_string())
            .spawn(move || worker_loop(d))
            .ok();
    }
}

fn worker_loop(dispatcher: Arc<UrlDispatcher>) {
    log::info!("URL dispatcher background worker started");

    loop {
        let url = {
            let mut state = dispatcher.state.lock().unwrap();
            while state.queue.is_empty() && !dispatcher.stop_worker.load(Ordering::SeqCst) {
                // Wait with a 30-second idle timeout to exit gracefully when inactive
                let (next_state, timeout_result) = dispatcher
                    .cvar
                    .wait_timeout(state, Duration::from_secs(30))
                    .unwrap();
                state = next_state;
                if timeout_result.timed_out() && state.queue.is_empty() {
                    state.worker_running = false;
                    log::info!("URL dispatcher worker idle timeout, shutting down worker");
                    return;
                }
            }

            if dispatcher.stop_worker.load(Ordering::SeqCst) && state.queue.is_empty() {
                state.worker_running = false;
                log::info!("URL dispatcher worker stopped");
                return;
            }

            state.queue.pop_front()
        };

        if let Some(url) = url {
            process_url(url, &dispatcher);
        }
    }
}

fn process_url(url: String, dispatcher: &Arc<UrlDispatcher>) {
    #[cfg(not(target_os = "ios"))]
    {
        // 1. Try to send the URL to an existing Flutter GUI instance via IPC
        let send_res = crate::ipc::send_url_scheme(url.clone());
        if let Err(err) = send_res {
            log::debug!(
                "Failed to deliver URL via IPC: {}. Evaluating fallback GUI spawn.",
                err
            );

            // 2. Fallback: single-flight spawn of a new GUI process if cooldown elapsed
            let mut state = dispatcher.state.lock().unwrap();
            let should_spawn = match state.last_fallback_spawn {
                Some(last) => last.elapsed() >= FALLBACK_COOLDOWN_DURATION,
                None => true,
            };

            if should_spawn {
                state.last_fallback_spawn = Some(Instant::now());
                drop(state);

                log::info!("Spawning supervised fallback GUI process for URL scheme");
                let args = if url.is_empty() { vec![] } else { vec![url] };

                if let Err(e) = crate::common::run_me_supervised(args, "url_fallback_gui", None) {
                    log::error!("Failed to spawn fallback GUI process: {}", e);
                } else {
                    // Brief pause to allow the fallback GUI process to initialize IPC listener
                    thread::sleep(Duration::from_millis(500));
                }
            } else {
                log::warn!("Fallback GUI spawn suppressed due to active cooldown window");
            }
        }
    }
}
