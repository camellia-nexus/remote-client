// Action authorization and remote input gate
// AUTH-005: Protect against unauthorized remote actions and fail-open state modification

use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    LazyLock, Mutex,
};
use std::time::{Duration, Instant};

use camellia_remote_protocol::{get_time, log};

/// Threshold within which remote input is considered recent and active.
pub const REMOTE_INPUT_RECENCY_THRESHOLD: Duration = Duration::from_millis(1000);
/// Maximum lifetime for an issued action token before expiration.
pub const ACTION_TOKEN_EXPIRATION: Duration = Duration::from_secs(10);

static NEXT_ACTION_ID: AtomicU64 = AtomicU64::new(1);

/// Generate a unique, monotonically increasing action ID.
pub fn next_action_id() -> i64 {
    NEXT_ACTION_ID.fetch_add(1, Ordering::Relaxed) as i64
}

#[derive(Debug, Clone, Copy)]
pub struct ConnectionInputState {
    pub last_mouse_move: Option<Instant>,
    pub last_click: Option<Instant>,
}

#[derive(Debug, Clone)]
pub struct ActionToken {
    pub conn_id: i32,
    pub page_generation: i64,
    pub created_at: Instant,
}

struct ActionGateState {
    connections: HashMap<i32, ConnectionInputState>,
    last_global_remote_input: Option<Instant>,
    pending_actions: HashMap<i64, ActionToken>,
}

static ACTION_GATE: LazyLock<Mutex<ActionGateState>> = LazyLock::new(|| {
    Mutex::new(ActionGateState {
        connections: HashMap::new(),
        last_global_remote_input: None,
        pending_actions: HashMap::new(),
    })
});

/// Create an authoritative, single-use action token bound to a connection and page generation.
pub fn create_action_token(conn_id: i32, page_generation: i64) -> i64 {
    let action_id = next_action_id();
    let mut state = match ACTION_GATE.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    // Purge expired tokens
    state
        .pending_actions
        .retain(|_, token| token.created_at.elapsed() < ACTION_TOKEN_EXPIRATION);
    state.pending_actions.insert(
        action_id,
        ActionToken {
            conn_id,
            page_generation,
            created_at: Instant::now(),
        },
    );
    action_id
}

/// Record remote pointer or click input from a specific connection.
pub fn record_remote_input(conn_id: i32, is_click: bool) {
    let now = Instant::now();
    let mut state = match ACTION_GATE.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    state.last_global_remote_input = Some(now);
    let entry = state
        .connections
        .entry(conn_id)
        .or_insert(ConnectionInputState {
            last_mouse_move: None,
            last_click: None,
        });
    if is_click {
        entry.last_click = Some(now);
    } else {
        entry.last_mouse_move = Some(now);
    }
}

/// Clean up state for a closed or dropped connection.
pub fn clean_connection(conn_id: i32) {
    let mut state = match ACTION_GATE.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    state.connections.remove(&conn_id);
    state
        .pending_actions
        .retain(|_, token| token.conn_id != conn_id);
}

/// Reset all action gate state (used in testing).
pub fn reset_action_gate_for_test() {
    let mut state = match ACTION_GATE.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    state.connections.clear();
    state.pending_actions.clear();
    state.last_global_remote_input = None;
    #[cfg(not(any(target_os = "ios")))]
    {
        crate::server::MOUSE_MOVE_TIME.store(0, Ordering::SeqCst);
        crate::server::CLICK_TIME.store(0, Ordering::SeqCst);
    }
}

/// Check if any remote input has been received globally within the given duration.
pub fn is_global_remote_input_recent(threshold: Duration) -> bool {
    let state = match ACTION_GATE.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    state
        .last_global_remote_input
        .map(|t| t.elapsed() < threshold)
        .unwrap_or(false)
}

/// Check if remote input has been received for a specific connection within the given duration.
pub fn is_connection_remote_input_recent(conn_id: i32, threshold: Duration) -> bool {
    let state = match ACTION_GATE.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    if let Some(entry) = state.connections.get(&conn_id) {
        let click_recent = entry
            .last_click
            .map(|t| t.elapsed() < threshold)
            .unwrap_or(false);
        let move_recent = entry
            .last_mouse_move
            .map(|t| t.elapsed() < threshold)
            .unwrap_or(false);
        click_recent || move_recent
    } else {
        state
            .last_global_remote_input
            .map(|t| t.elapsed() < threshold)
            .unwrap_or(false)
    }
}

/// Authoritative check for Connection Manager actions (e.g. Elevate, Accept, permission switch).
/// Returns true only if the action is affirmatively authorized.
/// Any missing connection, disconnected state, unissued/consumed action ID, generation mismatch,
/// or recent remote input results in false (fail closed).
pub fn authorize_cm_action(
    conn_id: i32,
    action: &str,
    action_id: i64,
    page_generation: i64,
) -> bool {
    // If local config explicitly allows remote CM modification:
    if crate::common::get_local_option("allow-remote-cm-modification") == "Y" {
        return true;
    }

    // Authoritative action token verification (single-use, bound to conn_id and generation)
    let token = {
        let mut state = match ACTION_GATE.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        state.pending_actions.remove(&action_id)
    };

    let token = match token {
        Some(t) => t,
        None => {
            log::warn!(
                "CM action '{}' rejected: action_id {} is invalid, unissued, or already consumed",
                action,
                action_id
            );
            return false;
        }
    };

    if token.conn_id != conn_id {
        log::warn!(
            "CM action '{}' rejected: conn_id mismatch for action_id {} (token={}, param={})",
            action,
            action_id,
            token.conn_id,
            conn_id
        );
        return false;
    }

    if token.page_generation != page_generation {
        log::warn!(
            "CM action '{}' rejected: generation mismatch for action_id {} (token={}, param={})",
            action,
            action_id,
            token.page_generation,
            page_generation
        );
        return false;
    }

    if token.created_at.elapsed() > ACTION_TOKEN_EXPIRATION {
        log::warn!(
            "CM action '{}' rejected: action_id {} has expired",
            action,
            action_id
        );
        return false;
    }

    // Verify connection existence in CM using encapsulated helper
    if !crate::ui_cm_interface::is_client_valid(conn_id) {
        log::warn!(
            "CM action '{}' (action_id={}, gen={}) rejected: connection {} is invalid or disconnected",
            action,
            action_id,
            page_generation,
            conn_id
        );
        return false;
    }

    // Fail-closed check: if remote input was detected within the recency threshold, block!
    if is_connection_remote_input_recent(conn_id, REMOTE_INPUT_RECENCY_THRESHOLD) {
        log::warn!(
            "CM action '{}' (action_id={}, gen={}) blocked by authoritative action gate: remote input active on conn {}",
            action,
            action_id,
            page_generation,
            conn_id
        );
        return false;
    }

    log::info!(
        "CM action '{}' (action_id={}, gen={}) authorized by native action gate for conn {}",
        action,
        action_id,
        page_generation,
        conn_id
    );
    true
}

/// Authoritative check for protected pages/widgets (e.g. Settings, Home page).
/// Returns true if pointer input SHOULD BE BLOCKED (i.e. remote input active).
/// Fails closed: on ambiguity or active remote input, returns true.
pub fn check_pointer_source_authoritative(_action_id: i64) -> bool {
    // If local configuration explicitly allows remote config modification, don't block:
    if crate::common::get_local_option("allow-remote-config-modification") == "Y" {
        return false;
    }

    // If any global remote input is recent within threshold, block!
    if is_global_remote_input_recent(REMOTE_INPUT_RECENCY_THRESHOLD) {
        return true;
    }

    #[cfg(not(any(target_os = "ios")))]
    {
        // Also check legacy MOUSE_MOVE_TIME / CLICK_TIME for cross-service IPC synchronization
        let last_mouse = crate::server::MOUSE_MOVE_TIME.load(Ordering::SeqCst);
        let last_click = crate::server::CLICK_TIME.load(Ordering::SeqCst);
        let now_ms = get_time();
        let threshold_ms = REMOTE_INPUT_RECENCY_THRESHOLD.as_millis() as i64;

        if (last_mouse > 0 && (now_ms - last_mouse).abs() < threshold_ms)
            || (last_click > 0 && (now_ms - last_click).abs() < threshold_ms)
        {
            return true;
        }
    }

    false
}
