use camellia_remote_protocol::tokio;
use lazy_static::lazy_static;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Instant;

lazy_static! {
    static ref SUPERVISOR: Mutex<SupervisorState> = Mutex::new(SupervisorState::Stopped);
    static ref SUPERVISOR_GEN: AtomicU64 = AtomicU64::new(0);
    static ref SERVER_ACTIVE: AtomicBool = AtomicBool::new(false);
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum SupervisorStatus {
    Stopped,
    Running(u64),
}

enum SupervisorState {
    Stopped,
    Running {
        generation: u64,
        handle: Option<std::thread::JoinHandle<()>>,
    },
}

pub fn is_android_server_active() -> bool {
    SERVER_ACTIVE.load(Ordering::SeqCst)
}

pub fn current_generation() -> u64 {
    SUPERVISOR_GEN.load(Ordering::SeqCst)
}

pub fn get_status() -> SupervisorStatus {
    let state = SUPERVISOR.lock().unwrap();
    match &*state {
        SupervisorState::Stopped => SupervisorStatus::Stopped,
        SupervisorState::Running { generation, .. } => SupervisorStatus::Running(*generation),
    }
}

pub fn start_android_server(_app_dir: String, _custom_client_config: String) -> u64 {
    let mut state = SUPERVISOR.lock().unwrap();
    if let SupervisorState::Running { generation, .. } = &*state {
        camellia_remote_protocol::log::info!(
            "Android server already running with generation {}",
            generation
        );
        return *generation;
    }

    let generation = SUPERVISOR_GEN.fetch_add(1, Ordering::SeqCst) + 1;
    SERVER_ACTIVE.store(true, Ordering::SeqCst);
    crate::common::set_server_running(true);
    camellia_remote_protocol::config::Config::set_option("stop-service".into(), "".into());

    camellia_remote_protocol::log::info!("Starting Android server generation {}", generation);

    let handle = std::thread::Builder::new()
        .name(format!("android-srv-{}", generation))
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build();
            match rt {
                Ok(runtime) => {
                    runtime.block_on(async {
                        crate::server::Connection::spawn_pending_audit_replay();
                        crate::RendezvousMediator::start_all().await;
                    });
                    camellia_remote_protocol::log::info!(
                        "Android server generation {} runtime completed",
                        generation
                    );
                }
                Err(e) => {
                    camellia_remote_protocol::log::error!(
                        "Failed to build tokio runtime for Android server generation {}: {}",
                        generation,
                        e
                    );
                }
            }
            SERVER_ACTIVE.store(false, Ordering::SeqCst);
        })
        .ok();

    *state = SupervisorState::Running { generation, handle };
    generation
}

pub fn stop_android_server() {
    let mut state = SUPERVISOR.lock().unwrap();
    let handle = match std::mem::replace(&mut *state, SupervisorState::Stopped) {
        SupervisorState::Running { generation, handle } => {
            camellia_remote_protocol::log::info!(
                "Stopping Android server generation {}",
                generation
            );
            SERVER_ACTIVE.store(false, Ordering::SeqCst);
            crate::common::set_server_running(false);
            camellia_remote_protocol::config::Config::set_option("stop-service".into(), "Y".into());
            crate::RendezvousMediator::restart();
            handle
        }
        SupervisorState::Stopped => None,
    };
    drop(state);

    if let Some(h) = handle {
        let start = Instant::now();
        let _ = h.join();
        camellia_remote_protocol::log::info!(
            "Android server worker thread joined in {:?}",
            start.elapsed()
        );
    }
}

#[doc(hidden)]
pub fn reset_for_test() {
    stop_android_server();
    let mut state = SUPERVISOR.lock().unwrap();
    *state = SupervisorState::Stopped;
    SERVER_ACTIVE.store(false, Ordering::SeqCst);
}
