use crate::ui_interface::get_option;
#[cfg(windows)]
use crate::{
    display_service,
    ipc::{connect, Data},
    platform::is_installed,
};
#[cfg(windows)]
use camellia_remote_protocol::tokio;
use camellia_remote_protocol::{
    anyhow::anyhow, bail, lazy_static, log, tokio::sync::oneshot, ResultType,
};
use serde_derive::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, RwLock,
    },
    time::Duration,
};

pub mod journal;
pub use journal::{
    clear_durable_journal, load_durable_journal, save_durable_journal, DisplaySnapshot,
    JournalItemState, JournalPhase, PhysicalDisplayJournalEntry, PrivacyRecoveryJournal,
    RegistryJournalEntry, VirtualDisplayJournalEntry, CONFIG_KEY_PRIVACY_JOURNAL,
};

#[cfg(windows)]
pub mod win_exclude_from_capture;
#[cfg(windows)]
pub mod win_input;
#[cfg(windows)]
pub mod win_mag;
#[cfg(windows)]
pub mod win_topmost_window;

#[cfg(target_os = "macos")]
pub mod macos;

#[cfg(windows)]
pub mod win_virtual_display;
#[cfg(windows)]
pub use win_virtual_display::restore_reg_connectivity;

pub const INVALID_PRIVACY_MODE_CONN_ID: i32 = 0;
pub const OCCUPIED: &str = "Privacy occupied by another one.";
pub const TURN_OFF_OTHER_ID: &str = "Failed to turn off privacy mode that belongs to someone else.";
pub const NO_PHYSICAL_DISPLAYS: &str = "no_need_privacy_mode_no_physical_displays_tip";

pub const PRIVACY_MODE_IMPL_WIN_MAG: &str = "privacy_mode_impl_mag";
pub const PRIVACY_MODE_IMPL_WIN_EXCLUDE_FROM_CAPTURE: &str =
    "privacy_mode_impl_exclude_from_capture";
pub const PRIVACY_MODE_IMPL_WIN_VIRTUAL_DISPLAY: &str = "privacy_mode_impl_virtual_display";

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "t", content = "c")]
pub enum PrivacyModeState {
    OffSucceeded,
    OffByPeer,
    OffUnknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrivacyOwner {
    pub conn_id: i32,
    pub generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrivacyRequestId {
    pub owner: PrivacyOwner,
    pub seq: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrivacyTransactionState {
    Idle,
    Activating { request_id: PrivacyRequestId },
    Active { owner: PrivacyOwner },
    Restoring { owner: Option<PrivacyOwner> },
    UnknownRestoring { owner: Option<PrivacyOwner> },
}

pub struct PrivacyTransactionSupervisor {
    state: RwLock<PrivacyTransactionState>,
    seq_counter: AtomicU64,
    current_cancel_token: Mutex<Option<Arc<AtomicBool>>>,
}

impl PrivacyTransactionSupervisor {
    pub fn new() -> Self {
        Self {
            state: RwLock::new(PrivacyTransactionState::Idle),
            seq_counter: AtomicU64::new(1),
            current_cancel_token: Mutex::new(None),
        }
    }

    pub fn get_state(&self) -> PrivacyTransactionState {
        self.state.read().unwrap().clone()
    }

    pub fn begin_activation(
        &self,
        owner: PrivacyOwner,
    ) -> ResultType<(PrivacyRequestId, Arc<AtomicBool>)> {
        let mut state_lock = self.state.write().unwrap();
        match &*state_lock {
            PrivacyTransactionState::Active { owner: cur_owner } => {
                if *cur_owner == owner {
                    return Ok((
                        PrivacyRequestId {
                            owner,
                            seq: self.seq_counter.load(Ordering::SeqCst),
                        },
                        Arc::new(AtomicBool::new(false)),
                    ));
                } else {
                    bail!(OCCUPIED);
                }
            }
            PrivacyTransactionState::Activating { request_id } => {
                if request_id.owner.conn_id == owner.conn_id {
                    // Retry from same connection: signal cancellation on preceding attempt
                    if let Some(token) = self.current_cancel_token.lock().unwrap().as_ref() {
                        token.store(true, Ordering::SeqCst);
                    }
                } else {
                    bail!(OCCUPIED);
                }
            }
            PrivacyTransactionState::Restoring { .. }
            | PrivacyTransactionState::UnknownRestoring { .. } => {
                bail!("Privacy mode is currently restoring system state. Please retry shortly.");
            }
            PrivacyTransactionState::Idle => {}
        }

        let seq = self.seq_counter.fetch_add(1, Ordering::SeqCst);
        let request_id = PrivacyRequestId { owner, seq };
        let cancel_token = Arc::new(AtomicBool::new(false));

        *self.current_cancel_token.lock().unwrap() = Some(cancel_token.clone());
        *state_lock = PrivacyTransactionState::Activating { request_id };

        Ok((request_id, cancel_token))
    }

    pub fn commit_active(
        &self,
        request_id: PrivacyRequestId,
        cancel_token: &AtomicBool,
    ) -> ResultType<()> {
        if cancel_token.load(Ordering::SeqCst) {
            bail!("Transaction was cancelled; cannot commit active state");
        }
        let mut state_lock = self.state.write().unwrap();
        match *state_lock {
            PrivacyTransactionState::Activating {
                request_id: cur_req,
            } if cur_req == request_id => {
                *state_lock = PrivacyTransactionState::Active {
                    owner: request_id.owner,
                };
                *self.current_cancel_token.lock().unwrap() = None;
                Ok(())
            }
            _ => {
                bail!("Transaction generation or state mismatch; active state rejected");
            }
        }
    }

    pub fn abort_activation(&self, request_id: PrivacyRequestId) {
        let mut state_lock = self.state.write().unwrap();
        if let PrivacyTransactionState::Activating {
            request_id: cur_req,
        } = *state_lock
        {
            if cur_req == request_id {
                *state_lock = PrivacyTransactionState::Idle;
                *self.current_cancel_token.lock().unwrap() = None;
            }
        }
    }

    pub async fn handle_timeout(
        &self,
        request_id: PrivacyRequestId,
        cancel_token: Arc<AtomicBool>,
        grace_period: Duration,
        done_rx: &mut oneshot::Receiver<Option<ResultType<bool>>>,
    ) -> Option<ResultType<bool>> {
        cancel_token.store(true, Ordering::SeqCst);

        // Wait bounded grace period for worker to acknowledge cancellation and rollback
        match camellia_remote_protocol::tokio::time::timeout(grace_period, done_rx).await {
            Ok(Ok(_)) => {
                self.abort_activation(request_id);
                Some(Err(anyhow!(
                    "Privacy activation timed out; system state restored"
                )))
            }
            _ => {
                // Hard timeout: worker is stuck in kernel/driver syscall
                let mut state_lock = self.state.write().unwrap();
                *state_lock = PrivacyTransactionState::UnknownRestoring {
                    owner: Some(request_id.owner),
                };
                Some(Err(anyhow!(
                    "Privacy activation timed out; state unknown, background recovery scheduled"
                )))
            }
        }
    }

    pub fn turn_off_or_abort_for_owner(&self, owner: PrivacyOwner) -> bool {
        let mut state_lock = self.state.write().unwrap();
        match *state_lock {
            PrivacyTransactionState::Activating { request_id }
                if owner.conn_id == INVALID_PRIVACY_MODE_CONN_ID
                    || request_id.owner.conn_id == owner.conn_id =>
            {
                if let Some(token) = self.current_cancel_token.lock().unwrap().as_ref() {
                    token.store(true, Ordering::SeqCst);
                }
                *self.current_cancel_token.lock().unwrap() = None;
                *state_lock = PrivacyTransactionState::Idle;
                true
            }
            PrivacyTransactionState::Active {
                owner: active_owner,
            } if owner.conn_id == INVALID_PRIVACY_MODE_CONN_ID
                || active_owner.conn_id == owner.conn_id =>
            {
                *self.current_cancel_token.lock().unwrap() = None;
                *state_lock = PrivacyTransactionState::Idle;
                true
            }
            PrivacyTransactionState::Restoring {
                owner: ref opt_owner,
            }
            | PrivacyTransactionState::UnknownRestoring {
                owner: ref opt_owner,
            } if owner.conn_id == INVALID_PRIVACY_MODE_CONN_ID
                || opt_owner
                    .map(|o| o.conn_id == owner.conn_id)
                    .unwrap_or(true) =>
            {
                if let Some(token) = self.current_cancel_token.lock().unwrap().as_ref() {
                    token.store(true, Ordering::SeqCst);
                }
                *self.current_cancel_token.lock().unwrap() = None;
                *state_lock = PrivacyTransactionState::Idle;
                true
            }
            _ => false,
        }
    }

    pub fn force_reset_to_idle(&self) {
        if let Some(token) = self.current_cancel_token.lock().unwrap().take() {
            token.store(true, Ordering::SeqCst);
        }
        let mut state_lock = self.state.write().unwrap();
        *state_lock = PrivacyTransactionState::Idle;
    }

    pub fn get_active_owner(&self) -> Option<PrivacyOwner> {
        let state_lock = self.state.read().unwrap();
        match *state_lock {
            PrivacyTransactionState::Active { owner } => Some(owner),
            _ => None,
        }
    }
}

impl Default for PrivacyTransactionSupervisor {
    fn default() -> Self {
        Self::new()
    }
}

pub trait PrivacyMode: Sync + Send {
    fn is_async_privacy_mode(&self) -> bool;

    fn init(&self) -> ResultType<()>;
    fn clear(&mut self);
    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool>;
    fn turn_off_privacy(&mut self, conn_id: i32, state: Option<PrivacyModeState>)
        -> ResultType<()>;

    fn pre_conn_id(&self) -> i32;

    fn get_impl_key(&self) -> &str;

    fn turn_on_privacy_with_token(
        &mut self,
        conn_id: i32,
        _generation: u64,
        _cancel_token: Option<&AtomicBool>,
    ) -> ResultType<bool> {
        self.turn_on_privacy(conn_id)
    }

    #[inline]
    fn check_on_conn_id(&self, conn_id: i32) -> ResultType<bool> {
        let pre_conn_id = self.pre_conn_id();
        if pre_conn_id == conn_id {
            return Ok(true);
        }
        if pre_conn_id != INVALID_PRIVACY_MODE_CONN_ID {
            bail!(OCCUPIED);
        }
        Ok(false)
    }

    #[inline]
    fn check_off_conn_id(&self, conn_id: i32) -> ResultType<()> {
        let pre_conn_id = self.pre_conn_id();
        if pre_conn_id != INVALID_PRIVACY_MODE_CONN_ID
            && conn_id != INVALID_PRIVACY_MODE_CONN_ID
            && pre_conn_id != conn_id
        {
            bail!(TURN_OFF_OTHER_ID)
        }
        Ok(())
    }
}

lazy_static::lazy_static! {
    pub static ref SUPERVISOR: Arc<PrivacyTransactionSupervisor> =
        Arc::new(PrivacyTransactionSupervisor::new());

    pub static ref DEFAULT_PRIVACY_MODE_IMPL: String = {
        #[cfg(windows)]
        {
            if win_exclude_from_capture::is_supported() {
                PRIVACY_MODE_IMPL_WIN_EXCLUDE_FROM_CAPTURE
            } else {
                if display_service::is_privacy_mode_mag_supported() {
                    PRIVACY_MODE_IMPL_WIN_MAG
                } else {
                    if is_installed() {
                        PRIVACY_MODE_IMPL_WIN_VIRTUAL_DISPLAY
                    } else {
                        ""
                    }
                }
            }.to_owned()
        }
        #[cfg(not(windows))]
        {
            #[cfg(target_os = "macos")]
            {
                macos::PRIVACY_MODE_IMPL.to_owned()
            }
            #[cfg(not(target_os = "macos"))]
            {
                "".to_owned()
            }
        }
    };

    static ref PRIVACY_MODE: Arc<Mutex<Option<Box<dyn PrivacyMode>>>> = {
        let mut cur_impl = get_option("privacy-mode-impl-key");
        if !get_supported_privacy_mode_impl().iter().any(|(k, _)| k == &cur_impl) {
            cur_impl = DEFAULT_PRIVACY_MODE_IMPL.to_owned();
        }

        let privacy_mode = PRIVACY_MODE_CREATOR
            .lock()
            .unwrap()
            .get(&(&cur_impl as &str))
            .map(|creator| creator(&cur_impl));
        Arc::new(Mutex::new(privacy_mode))
    };
}

pub type PrivacyModeCreator = fn(impl_key: &str) -> Box<dyn PrivacyMode>;
lazy_static::lazy_static! {
    static ref PRIVACY_MODE_CREATOR: Arc<Mutex<HashMap<&'static str, PrivacyModeCreator>>> = {
        #[cfg(not(windows))]
        // Only the macOS-gated block below mutates the map on non-Windows targets.
        #[cfg_attr(not(target_os = "macos"), allow(unused_mut))]
        let mut map: HashMap<&'static str, PrivacyModeCreator> = HashMap::new();
        #[cfg(target_os = "macos")]
        {
            map.insert(macos::PRIVACY_MODE_IMPL, |impl_key: &str| {
                Box::new(macos::PrivacyModeImpl::new(impl_key))
            });
        }
        #[cfg(windows)]
        let mut map: HashMap<&'static str, PrivacyModeCreator> = HashMap::new();
        #[cfg(windows)]
        {
            if win_exclude_from_capture::is_supported() {
                map.insert(win_exclude_from_capture::PRIVACY_MODE_IMPL, |impl_key: &str| {
                    Box::new(win_exclude_from_capture::PrivacyModeImpl::new(impl_key))
                });
            } else {
                map.insert(win_mag::PRIVACY_MODE_IMPL, |impl_key: &str| {
                    Box::new(win_mag::PrivacyModeImpl::new(impl_key))
                });
            }

            map.insert(win_virtual_display::PRIVACY_MODE_IMPL, |impl_key: &str| {
                    Box::new(win_virtual_display::PrivacyModeImpl::new(impl_key))
                });
        }
        Arc::new(Mutex::new(map))
    };
}

#[inline]
pub fn init() -> Option<ResultType<()>> {
    Some(PRIVACY_MODE.lock().unwrap().as_ref()?.init())
}

#[inline]
pub fn clear() -> Option<()> {
    PRIVACY_MODE.lock().unwrap().as_mut()?.clear();
    Some(())
}

#[inline]
pub fn switch(impl_key: &str) {
    let mut privacy_mode_lock = PRIVACY_MODE.lock().unwrap();
    if let Some(privacy_mode) = privacy_mode_lock.as_ref() {
        if privacy_mode.get_impl_key() == impl_key {
            return;
        }
    }

    if let Some(creator) = PRIVACY_MODE_CREATOR.lock().unwrap().get(impl_key) {
        *privacy_mode_lock = Some(creator(impl_key));
    }
}

fn get_supported_impl(impl_key: &str) -> String {
    let supported_impls = get_supported_privacy_mode_impl();
    if supported_impls.iter().any(|(k, _)| k == &impl_key) {
        return impl_key.to_owned();
    };
    let mut cur_impl = get_option("privacy-mode-impl-key");
    if !get_supported_privacy_mode_impl()
        .iter()
        .any(|(k, _)| k == &cur_impl)
    {
        cur_impl = DEFAULT_PRIVACY_MODE_IMPL.to_owned();
    }
    cur_impl
}

pub async fn turn_on_privacy(impl_key: &str, conn_id: i32) -> Option<ResultType<bool>> {
    turn_on_privacy_with_owner(
        impl_key,
        PrivacyOwner {
            conn_id,
            generation: 0,
        },
    )
    .await
}

pub async fn turn_on_privacy_with_owner(
    impl_key: &str,
    owner: PrivacyOwner,
) -> Option<ResultType<bool>> {
    if is_async_privacy_mode() {
        turn_on_privacy_async_with_owner(impl_key.to_string(), owner).await
    } else {
        turn_on_privacy_sync_with_owner(impl_key, owner)
    }
}

#[inline]
fn is_async_privacy_mode() -> bool {
    PRIVACY_MODE
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|m| m.is_async_privacy_mode())
}

#[inline]
async fn turn_on_privacy_async_with_owner(
    impl_key: String,
    owner: PrivacyOwner,
) -> Option<ResultType<bool>> {
    let (request_id, cancel_token) = match SUPERVISOR.begin_activation(owner) {
        Ok(pair) => pair,
        Err(e) => return Some(Err(e)),
    };

    let (tx, rx) = oneshot::channel();
    let token_clone = cancel_token.clone();
    let req_owner = owner;
    let key = impl_key.clone();

    std::thread::spawn(move || {
        let res = turn_on_privacy_sync_with_token(&key, req_owner, &token_clone);
        let _ = tx.send(res);
    });

    let mut rx = rx;
    // Wait at most 7.5 seconds for the result.
    match camellia_remote_protocol::tokio::time::timeout(Duration::from_millis(7500), &mut rx).await
    {
        Ok(res) => match res {
            Ok(worker_res) => match worker_res {
                Some(Ok(success)) => {
                    if success {
                        if let Err(e) = SUPERVISOR.commit_active(request_id, &cancel_token) {
                            log::error!("Supervisor rejected active commit: {}", e);
                            let _ = turn_off_privacy(owner.conn_id, None);
                            return Some(Err(e));
                        }
                    } else {
                        SUPERVISOR.abort_activation(request_id);
                    }
                    Some(Ok(success))
                }
                Some(Err(e)) => {
                    SUPERVISOR.abort_activation(request_id);
                    Some(Err(e))
                }
                None => {
                    SUPERVISOR.abort_activation(request_id);
                    None
                }
            },
            Err(e) => {
                SUPERVISOR.abort_activation(request_id);
                Some(Err(anyhow!(e.to_string())))
            }
        },
        Err(_) => {
            // 7.5s Timeout exceeded: activate supervisor bounded compensation
            SUPERVISOR
                .handle_timeout(
                    request_id,
                    cancel_token,
                    Duration::from_millis(1500),
                    &mut rx,
                )
                .await
        }
    }
}

fn turn_on_privacy_sync_with_owner(
    impl_key: &str,
    owner: PrivacyOwner,
) -> Option<ResultType<bool>> {
    let (request_id, cancel_token) = match SUPERVISOR.begin_activation(owner) {
        Ok(pair) => pair,
        Err(e) => return Some(Err(e)),
    };

    let res = turn_on_privacy_sync_with_token(impl_key, owner, &cancel_token);
    match &res {
        Some(Ok(true)) => {
            if let Err(e) = SUPERVISOR.commit_active(request_id, &cancel_token) {
                log::error!("Supervisor rejected active commit: {}", e);
                let _ = turn_off_privacy(owner.conn_id, None);
                return Some(Err(e));
            }
        }
        _ => {
            SUPERVISOR.abort_activation(request_id);
        }
    }
    res
}

fn turn_on_privacy_sync_with_token(
    impl_key: &str,
    owner: PrivacyOwner,
    cancel_token: &AtomicBool,
) -> Option<ResultType<bool>> {
    if cancel_token.load(Ordering::SeqCst) {
        return Some(Err(anyhow!(
            "Privacy activation cancelled before lock acquisition"
        )));
    }

    let mut privacy_mode_lock = PRIVACY_MODE.lock().unwrap();

    if cancel_token.load(Ordering::SeqCst) {
        return Some(Err(anyhow!(
            "Privacy activation cancelled after lock acquisition"
        )));
    }

    let impl_key = get_supported_impl(impl_key);
    let mut cur_impl_key = "".to_string();
    if let Some(privacy_mode) = privacy_mode_lock.as_ref() {
        cur_impl_key = privacy_mode.get_impl_key().to_string();
        let check_on_conn_id = privacy_mode.check_on_conn_id(owner.conn_id);
        match check_on_conn_id.as_ref() {
            Ok(true) => {
                if cur_impl_key == impl_key {
                    return Some(Ok(true));
                }
            }
            Err(_) => return Some(check_on_conn_id),
            _ => {}
        }
    }

    if cur_impl_key != impl_key {
        if let Some(creator) = PRIVACY_MODE_CREATOR
            .lock()
            .unwrap()
            .get(&(&impl_key as &str))
        {
            if let Some(privacy_mode) = privacy_mode_lock.as_mut() {
                privacy_mode.clear();
            }

            *privacy_mode_lock = Some(creator(&impl_key));
        } else {
            return Some(Err(anyhow!("Unsupported privacy mode: {}", impl_key)));
        }
    }

    Some(privacy_mode_lock.as_mut()?.turn_on_privacy_with_token(
        owner.conn_id,
        owner.generation,
        Some(cancel_token),
    ))
}

#[inline]
pub fn turn_off_privacy(conn_id: i32, state: Option<PrivacyModeState>) -> Option<ResultType<()>> {
    SUPERVISOR.turn_off_or_abort_for_owner(PrivacyOwner {
        conn_id,
        generation: 0,
    });
    Some(
        PRIVACY_MODE
            .lock()
            .unwrap()
            .as_mut()?
            .turn_off_privacy(conn_id, state),
    )
}

pub async fn abort_or_turn_off_bounded(owner: PrivacyOwner, deadline: Duration) -> bool {
    let was_tracked = SUPERVISOR.turn_off_or_abort_for_owner(owner);
    let (tx, rx) = oneshot::channel();
    std::thread::spawn(move || {
        let res = turn_off_privacy(owner.conn_id, None);
        let _ = tx.send(res);
    });

    match camellia_remote_protocol::tokio::time::timeout(deadline, rx).await {
        Ok(Ok(res)) => {
            log::debug!(
                "Bounded teardown completed for owner {:?}: {:?}",
                owner,
                res
            );
            true
        }
        Ok(Err(e)) => {
            log::warn!(
                "Teardown channel closed unexpectedly for owner {:?}: {}",
                owner,
                e
            );
            was_tracked
        }
        Err(_) => {
            log::warn!(
                "Teardown timed out after {:?} for owner {:?}",
                deadline,
                owner
            );
            was_tracked
        }
    }
}

#[inline]
pub fn check_on_conn_id(conn_id: i32) -> Option<ResultType<bool>> {
    Some(
        PRIVACY_MODE
            .lock()
            .unwrap()
            .as_ref()?
            .check_on_conn_id(conn_id),
    )
}

#[cfg(windows)]
#[tokio::main(flavor = "current_thread")]
async fn set_privacy_mode_state(
    conn_id: i32,
    state: PrivacyModeState,
    impl_key: String,
    ms_timeout: u64,
) -> ResultType<()> {
    let mut c = connect(ms_timeout, "_cm").await?;
    c.send(&Data::PrivacyModeState((conn_id, state, impl_key)))
        .await
}

pub fn get_supported_privacy_mode_impl() -> Vec<(&'static str, &'static str)> {
    #[cfg(target_os = "windows")]
    {
        let mut vec_impls = Vec::new();

        if win_exclude_from_capture::is_supported() {
            vec_impls.push((
                PRIVACY_MODE_IMPL_WIN_EXCLUDE_FROM_CAPTURE,
                "privacy_mode_impl_mag_tip",
            ));
        } else {
            if display_service::is_privacy_mode_mag_supported() {
                vec_impls.push((PRIVACY_MODE_IMPL_WIN_MAG, "privacy_mode_impl_mag_tip"));
            }
        }

        if is_installed() && crate::platform::windows::is_self_service_running() {
            vec_impls.push((
                PRIVACY_MODE_IMPL_WIN_VIRTUAL_DISPLAY,
                "privacy_mode_impl_virtual_display_tip",
            ));
        }

        vec_impls
    }
    #[cfg(target_os = "macos")]
    {
        vec![(macos::PRIVACY_MODE_IMPL, "privacy_mode_impl_macos_tip")]
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    {
        Vec::new()
    }
}

#[inline]
pub fn get_cur_impl_key() -> Option<String> {
    PRIVACY_MODE
        .lock()
        .unwrap()
        .as_ref()
        .map(|pm| pm.get_impl_key().to_owned())
}

#[inline]
pub fn is_current_privacy_mode_impl(impl_key: &str) -> bool {
    PRIVACY_MODE
        .lock()
        .unwrap()
        .as_ref()
        .map(|pm| pm.get_impl_key() == impl_key)
        .unwrap_or(false)
}

#[inline]
#[cfg(not(windows))]
pub fn check_privacy_mode_err(
    _privacy_mode_id: i32,
    _display_idx: usize,
    _timeout_millis: u64,
) -> String {
    "".to_owned()
}

#[inline]
#[cfg(windows)]
pub fn check_privacy_mode_err(
    privacy_mode_id: i32,
    display_idx: usize,
    timeout_millis: u64,
) -> String {
    if is_current_privacy_mode_impl(PRIVACY_MODE_IMPL_WIN_MAG) {
        crate::video_service::test_create_capturer(privacy_mode_id, display_idx, timeout_millis)
    } else {
        "".to_owned()
    }
}

#[inline]
pub fn is_privacy_mode_supported() -> bool {
    !DEFAULT_PRIVACY_MODE_IMPL.is_empty()
}

#[inline]
pub fn get_privacy_mode_conn_id() -> Option<i32> {
    if let Some(owner) = SUPERVISOR.get_active_owner() {
        Some(owner.conn_id)
    } else {
        PRIVACY_MODE
            .lock()
            .unwrap()
            .as_ref()
            .map(|pm| pm.pre_conn_id())
    }
}

#[inline]
pub fn is_in_privacy_mode() -> bool {
    if SUPERVISOR.get_active_owner().is_some() {
        return true;
    }
    PRIVACY_MODE
        .lock()
        .unwrap()
        .as_ref()
        .map(|pm| pm.pre_conn_id() != INVALID_PRIVACY_MODE_CONN_ID)
        .unwrap_or(false)
}

#[cfg(windows)]
pub fn recover_privacy_mode_on_startup() {
    if let Some(mut journal) = journal::load_durable_journal() {
        if journal.has_pending_or_applied() {
            log::info!(
                "Found lingering privacy journal on startup; restoring display & registry state..."
            );
            if let Err(e) = journal::restore_from_journal(&mut journal, true) {
                log::error!(
                    "Startup recovery from privacy journal encountered errors: {}",
                    e
                );
            }
        }
    }
    restore_reg_connectivity(true, false);
}

#[cfg(not(windows))]
pub fn recover_privacy_mode_on_startup() {}

#[cfg(windows)]
pub fn recover_privacy_mode_cli() -> ResultType<()> {
    let mut errors = Vec::new();
    if let Some(mut journal) = journal::load_durable_journal() {
        if let Err(e) = journal::restore_from_journal(&mut journal, true) {
            errors.push(format!("Journal recovery error: {}", e));
        }
    }
    restore_reg_connectivity(true, true);
    if errors.is_empty() {
        Ok(())
    } else {
        bail!("Privacy recovery errors: {}", errors.join("; "))
    }
}

#[cfg(not(windows))]
pub fn recover_privacy_mode_cli() -> ResultType<()> {
    Ok(())
}
