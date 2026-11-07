//! Subprocess lifecycle management, session generation ownership, and zombie elimination (RES-045).

use camellia_remote_protocol::log;
use std::{
    collections::HashMap,
    io,
    process::Child,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

pub const MAX_TRACKED_CHILDREN: usize = 128;
pub const CHILD_REAP_INTERVAL: Duration = Duration::from_millis(100);

pub struct TrackedChild {
    pub child: Child,
    pub pid: u32,
    pub label: String,
    pub session_id: Option<i32>,
    pub generation: u64,
    pub spawned_at: Instant,
}

pub struct ChildSupervisorState {
    pub children: HashMap<u32, TrackedChild>,
    pub generation: u64,
    pub reaper_running: bool,
}

camellia_remote_protocol::lazy_static::lazy_static! {
    pub static ref SUPERVISOR: Arc<Mutex<ChildSupervisorState>> = Arc::new(Mutex::new(ChildSupervisorState {
        children: HashMap::new(),
        generation: 1,
        reaper_running: false,
    }));
    static ref STOP_REAPER: AtomicBool = AtomicBool::new(false);
}

/// Register a child process under the supervisor with a descriptive label and optional session ID.
/// Returns the child process PID.
pub fn register(child: Child, label: &str, session_id: Option<i32>) -> io::Result<u32> {
    let mut state = SUPERVISOR.lock().unwrap();

    // Proactively reap any exited children if capacity is tight
    if state.children.len() >= MAX_TRACKED_CHILDREN {
        reap_locked(&mut state);
    }

    if state.children.len() >= MAX_TRACKED_CHILDREN {
        return Err(io::Error::other(format!(
            "Child supervisor capacity exceeded ({}/{})",
            state.children.len(),
            MAX_TRACKED_CHILDREN
        )));
    }

    let pid = child.id();
    let gen = state.generation;

    state.children.insert(
        pid,
        TrackedChild {
            child,
            pid,
            label: label.to_string(),
            session_id,
            generation: gen,
            spawned_at: Instant::now(),
        },
    );

    log::info!(
        "Supervised child pid={} label='{}' session_id={:?} registered (total={})",
        pid,
        label,
        session_id,
        state.children.len()
    );

    // Ensure the background reaper thread is running
    if !state.reaper_running {
        state.reaper_running = true;
        STOP_REAPER.store(false, Ordering::SeqCst);
        thread::spawn(reaper_loop);
    }

    Ok(pid)
}

fn reap_locked(state: &mut ChildSupervisorState) -> usize {
    let mut reaped = Vec::new();

    for (pid, tracked) in state.children.iter_mut() {
        match tracked.child.try_wait() {
            Ok(Some(status)) => {
                log::info!(
                    "Supervised child pid={} label='{}' exited with: {:?}",
                    pid,
                    tracked.label,
                    status
                );
                reaped.push(*pid);
            }
            Ok(None) => {}
            Err(e) => {
                log::warn!(
                    "Error checking supervised child pid={} label='{}': {}",
                    pid,
                    tracked.label,
                    e
                );
                reaped.push(*pid);
            }
        }
    }

    for pid in &reaped {
        state.children.remove(pid);
    }

    reaped.len()
}

/// Reaps all exited children synchronously.
/// Returns the number of reaped processes.
pub fn reap_exited_children() -> usize {
    let mut state = SUPERVISOR.lock().unwrap();
    reap_locked(&mut state)
}

/// Terminate all children associated with a specific session ID.
/// Kills each process and waits up to `timeout` for clean exit.
pub fn terminate_session_children(session_id: i32, timeout: Duration) -> usize {
    let mut pids_to_kill = Vec::new();
    {
        let mut state = SUPERVISOR.lock().unwrap();
        reap_locked(&mut state);
        for (pid, tracked) in state.children.iter_mut() {
            if tracked.session_id == Some(session_id) {
                log::info!(
                    "Terminating session {} child pid={} label='{}'",
                    session_id,
                    pid,
                    tracked.label
                );
                let _ = tracked.child.kill();
                pids_to_kill.push(*pid);
            }
        }
    }

    if pids_to_kill.is_empty() {
        return 0;
    }

    let start = Instant::now();
    let mut terminated_count = 0;

    while start.elapsed() < timeout && !pids_to_kill.is_empty() {
        {
            let mut state = SUPERVISOR.lock().unwrap();
            pids_to_kill.retain(|pid| {
                if let Some(tracked) = state.children.get_mut(pid) {
                    match tracked.child.try_wait() {
                        Ok(Some(_)) | Err(_) => {
                            state.children.remove(pid);
                            terminated_count += 1;
                            false
                        }
                        Ok(None) => true,
                    }
                } else {
                    terminated_count += 1;
                    false
                }
            });
        }

        if !pids_to_kill.is_empty() {
            thread::sleep(Duration::from_millis(20));
        }
    }

    // Force remove any remaining
    if !pids_to_kill.is_empty() {
        let mut state = SUPERVISOR.lock().unwrap();
        for pid in pids_to_kill {
            if state.children.remove(&pid).is_some() {
                terminated_count += 1;
            }
        }
    }

    terminated_count
}

/// Terminate all supervised children with a bounded timeout.
pub fn terminate_all(timeout: Duration) -> usize {
    let mut pids = Vec::new();
    {
        let mut state = SUPERVISOR.lock().unwrap();
        for (pid, tracked) in state.children.iter_mut() {
            let _ = tracked.child.kill();
            pids.push(*pid);
        }
    }

    let start = Instant::now();
    let mut count = 0;

    while start.elapsed() < timeout && !pids.is_empty() {
        {
            let mut state = SUPERVISOR.lock().unwrap();
            pids.retain(|pid| {
                if let Some(tracked) = state.children.get_mut(pid) {
                    match tracked.child.try_wait() {
                        Ok(Some(_)) | Err(_) => {
                            state.children.remove(pid);
                            count += 1;
                            false
                        }
                        Ok(None) => true,
                    }
                } else {
                    count += 1;
                    false
                }
            });
        }

        if !pids.is_empty() {
            thread::sleep(Duration::from_millis(20));
        }
    }

    count
}

/// Returns the number of currently tracked active children.
pub fn tracked_count() -> usize {
    let state = SUPERVISOR.lock().unwrap();
    state.children.len()
}

/// Monotonically increment generation counter.
pub fn bump_generation() -> u64 {
    let mut state = SUPERVISOR.lock().unwrap();
    state.generation += 1;
    state.generation
}

fn reaper_loop() {
    while !STOP_REAPER.load(Ordering::SeqCst) {
        thread::sleep(CHILD_REAP_INTERVAL);
        let mut state = SUPERVISOR.lock().unwrap();
        reap_locked(&mut state);
        if state.children.is_empty() {
            state.reaper_running = false;
            break;
        }
    }
}

pub fn stop_reaper() {
    STOP_REAPER.store(true, Ordering::SeqCst);
}
