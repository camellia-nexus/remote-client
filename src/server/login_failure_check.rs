use crate::AlarmAuditType;
use camellia_remote_protocol::get_time;
#[cfg(target_os = "windows")]
use camellia_remote_protocol::tokio::sync::{Mutex as TokioMutex, OwnedMutexGuard};
use std::sync::Arc;
use std::sync::Mutex;

const OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET_MS: i64 = 120 * 60 * 1_000;
const OS_CREDENTIAL_LOGIN_BACKOFF_BASE_SECONDS: i64 = 15;
const OS_CREDENTIAL_LOGIN_BACKOFF_MAX_SECONDS: i64 = 30 * 60;

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub(crate) enum FailureScope {
    Default,
    TerminalOsLogin,
}

pub(crate) struct OsCredentialPolicyDecision {
    pub allowed: bool,
    pub login_error: Option<String>,
    pub audit: Option<AlarmAuditType>,
}

#[derive(Copy, Clone, Debug, Default)]
struct OsCredentialFailureState {
    total_failures: i32,
    backoff_until_ms: Option<i64>,
    last_failure_ms: Option<i64>,
}

lazy_static::lazy_static! {
    static ref OS_CREDENTIAL_LOGIN_FAILURE_STATE: Mutex<OsCredentialFailureState> =
        Mutex::new(OsCredentialFailureState::default());
}

#[cfg(target_os = "windows")]
lazy_static::lazy_static! {
    static ref OS_CREDENTIAL_LOGIN_MUTEX: Arc<TokioMutex<()>> = Arc::new(TokioMutex::new(()));
}

fn is_os_credential_scope(scope: FailureScope) -> bool {
    matches!(scope, FailureScope::TerminalOsLogin)
}

fn state_for_os_credential_scope(
    scope: FailureScope,
) -> Option<&'static Mutex<OsCredentialFailureState>> {
    if is_os_credential_scope(scope) {
        Some(&OS_CREDENTIAL_LOGIN_FAILURE_STATE)
    } else {
        None
    }
}

fn backoff_audit_type_for_scope(scope: FailureScope) -> Option<AlarmAuditType> {
    match scope {
        FailureScope::TerminalOsLogin => Some(AlarmAuditType::TerminalOsLoginBackoff),
        FailureScope::Default => None,
    }
}

fn os_credential_login_backoff_seconds(total_failures: i32) -> i64 {
    if total_failures <= 2 {
        return 0;
    }
    let exp = (total_failures - 3).min(7);
    let seconds = OS_CREDENTIAL_LOGIN_BACKOFF_BASE_SECONDS * (1_i64 << exp);
    seconds.min(OS_CREDENTIAL_LOGIN_BACKOFF_MAX_SECONDS)
}

fn normalize_backoff(state: &mut OsCredentialFailureState, now_ms: i64) {
    if let Some(until_ms) = state.backoff_until_ms {
        if until_ms <= now_ms {
            state.backoff_until_ms = None;
        }
    }
}

fn reset_totals_on_idle(state: &mut OsCredentialFailureState, now_ms: i64) {
    if let Some(last_ms) = state.last_failure_ms {
        if now_ms.saturating_sub(last_ms) >= OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET_MS {
            state.total_failures = 0;
            state.backoff_until_ms = None;
            state.last_failure_ms = None;
        }
    }
}

fn allow_decision() -> OsCredentialPolicyDecision {
    OsCredentialPolicyDecision {
        allowed: true,
        login_error: None,
        audit: None,
    }
}

fn block_decision(
    login_error: String,
    alarm_type: Option<AlarmAuditType>,
) -> OsCredentialPolicyDecision {
    OsCredentialPolicyDecision {
        allowed: false,
        login_error: Some(login_error),
        audit: alarm_type,
    }
}

pub(crate) fn evaluate_os_credential_policy(
    scope: FailureScope,
    now_ms: i64,
) -> OsCredentialPolicyDecision {
    if !is_os_credential_scope(scope) {
        return allow_decision();
    }
    let Some(state_mutex) = state_for_os_credential_scope(scope) else {
        return allow_decision();
    };
    let mut state = state_mutex.lock().unwrap();
    reset_totals_on_idle(&mut state, now_ms);
    normalize_backoff(&mut state, now_ms);

    if let Some(until_ms) = state.backoff_until_ms {
        let remaining_ms = (until_ms - now_ms).max(0);
        let remaining_seconds = ((remaining_ms + 999) / 1_000).max(1);
        let seconds_label = if remaining_seconds == 1 {
            "second"
        } else {
            "seconds"
        };
        block_decision(
            format!(
                "Please try again in {} {}.",
                remaining_seconds, seconds_label
            ),
            backoff_audit_type_for_scope(scope),
        )
    } else {
        allow_decision()
    }
}

pub(crate) fn record_os_credential_failure(scope: FailureScope) {
    if !is_os_credential_scope(scope) {
        return;
    }
    let Some(state_mutex) = state_for_os_credential_scope(scope) else {
        return;
    };
    let mut state = state_mutex.lock().unwrap();
    let now_ms = get_time();
    reset_totals_on_idle(&mut state, now_ms);
    normalize_backoff(&mut state, now_ms);
    state.total_failures = state.total_failures.saturating_add(1);
    state.last_failure_ms = Some(now_ms);
    let backoff_seconds = os_credential_login_backoff_seconds(state.total_failures);
    if backoff_seconds > 0 {
        state.backoff_until_ms = Some(now_ms + backoff_seconds * 1_000);
    }
}

#[cfg(target_os = "windows")]
pub(crate) fn try_acquire_os_credential_login_gate() -> Result<OwnedMutexGuard<()>, ()> {
    OS_CREDENTIAL_LOGIN_MUTEX
        .clone()
        .try_lock_owned()
        .map_err(|_| ())
}

// ============================================================================
// AUTH-003 & RES-010: Bounded Login Rate Limiter & Atomic Admission Reservation
// ============================================================================

pub const MAX_RATE_LIMIT_ENTRIES: usize = 4_096;
pub const MAX_IN_FLIGHT_PER_IP: u32 = 2;
pub const MAX_FAILURES_PER_MINUTE: u32 = 6;
pub const MAX_TOTAL_FAILURES_LOCKOUT: u32 = 30;
pub const LOCKOUT_COOLDOWN_MS: i64 = 15 * 60 * 1_000; // 15-minute temporary lockout
pub const TOTAL_IDLE_RESET_MS: i64 = 120 * 60 * 1_000; // 2-hour idle counter decay

pub const IPV6_PREFIX_64_LIMIT: u32 = 60;
pub const IPV6_PREFIX_56_LIMIT: u32 = 80;
pub const IPV6_PREFIX_48_LIMIT: u32 = 100;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RateLimitKey {
    V4(std::net::Ipv4Addr),
    V6(std::net::Ipv6Addr),
    V6Prefix64(u64),
    V6Prefix56(u64),
    V6Prefix48(u64),
}

impl RateLimitKey {
    pub fn keys_for_addr(addr: std::net::IpAddr) -> Vec<RateLimitKey> {
        match addr {
            std::net::IpAddr::V4(v4) => vec![RateLimitKey::V4(v4)],
            std::net::IpAddr::V6(v6) => {
                let segments = v6.segments();
                let seg0 = ((segments[0] as u64) << 48)
                    | ((segments[1] as u64) << 32)
                    | ((segments[2] as u64) << 16)
                    | (segments[3] as u64);
                let p64 = seg0;
                let p56 = seg0 & 0xffff_ffff_ffff_ff00;
                let p48 = seg0 & 0xffff_ffff_ffff_0000;
                vec![
                    RateLimitKey::V6(v6),
                    RateLimitKey::V6Prefix64(p64),
                    RateLimitKey::V6Prefix56(p56),
                    RateLimitKey::V6Prefix48(p48),
                ]
            }
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct RateLimitBucket {
    pub in_flight: u32,
    pub window_minute: i32,
    pub minute_failures: u32,
    pub total_failures: u32,
    pub last_attempt_ms: i64,
    pub locked_until_ms: Option<i64>,
}

impl RateLimitBucket {
    pub fn new(now_ms: i64) -> Self {
        Self {
            in_flight: 0,
            window_minute: (now_ms / 60_000) as i32,
            minute_failures: 0,
            total_failures: 0,
            last_attempt_ms: now_ms,
            locked_until_ms: None,
        }
    }

    pub fn normalize(&mut self, now_ms: i64) {
        if now_ms.saturating_sub(self.last_attempt_ms) >= TOTAL_IDLE_RESET_MS {
            self.minute_failures = 0;
            self.total_failures = 0;
            self.locked_until_ms = None;
        }
        let current_minute = (now_ms / 60_000) as i32;
        if self.window_minute != current_minute {
            self.window_minute = current_minute;
            self.minute_failures = 0;
        }
        if let Some(until) = self.locked_until_ms {
            if now_ms >= until {
                self.locked_until_ms = None;
                self.total_failures = 0;
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct LoginAdmissionDecision {
    pub allowed: bool,
    pub login_error: Option<String>,
    pub audit: Option<AlarmAuditType>,
}

pub struct LoginRateLimiter {
    map: std::collections::HashMap<RateLimitKey, RateLimitBucket>,
}

impl Default for LoginRateLimiter {
    fn default() -> Self {
        Self {
            map: std::collections::HashMap::with_capacity(128),
        }
    }
}

impl LoginRateLimiter {
    pub fn new() -> Self {
        Self::default()
    }

    fn prune_if_needed(&mut self, now_ms: i64) {
        if self.map.len() >= MAX_RATE_LIMIT_ENTRIES {
            self.map.retain(|_, b| {
                b.in_flight > 0 || now_ms.saturating_sub(b.last_attempt_ms) < TOTAL_IDLE_RESET_MS
            });
            if self.map.len() >= MAX_RATE_LIMIT_ENTRIES {
                let mut removable: Vec<(RateLimitKey, i64)> = self
                    .map
                    .iter()
                    .filter(|(_, b)| b.in_flight == 0)
                    .map(|(&k, b)| (k, b.last_attempt_ms))
                    .collect();
                removable.sort_by_key(|(_, ts)| *ts);
                for (k, _) in removable.into_iter().take(256) {
                    self.map.remove(&k);
                }
            }
        }
    }

    pub fn check_and_reserve(
        &mut self,
        addr: std::net::IpAddr,
        now_ms: i64,
        category: usize, // 0 for primary password, 1 for 2fa
    ) -> (LoginAdmissionDecision, Option<LoginAdmissionPermit>) {
        self.prune_if_needed(now_ms);

        let keys = RateLimitKey::keys_for_addr(addr);

        // 1. Check direct IP limits
        let direct_key = keys[0];
        let direct_bucket = self
            .map
            .entry(direct_key)
            .or_insert_with(|| RateLimitBucket::new(now_ms));
        direct_bucket.normalize(now_ms);

        if let Some(until) = direct_bucket.locked_until_ms {
            if now_ms < until {
                return (
                    LoginAdmissionDecision {
                        allowed: false,
                        login_error: Some("Too many wrong attempts".to_string()),
                        audit: Some(AlarmAuditType::ExceedThirtyAttempts),
                    },
                    None,
                );
            }
        }

        if direct_bucket.in_flight >= MAX_IN_FLIGHT_PER_IP {
            return (
                LoginAdmissionDecision {
                    allowed: false,
                    login_error: Some("Please try 1 minute later".to_string()),
                    audit: Some(AlarmAuditType::SixAttemptsWithinOneMinute),
                },
                None,
            );
        }

        if direct_bucket.minute_failures + direct_bucket.in_flight >= MAX_FAILURES_PER_MINUTE {
            return (
                LoginAdmissionDecision {
                    allowed: false,
                    login_error: Some("Please try 1 minute later".to_string()),
                    audit: Some(AlarmAuditType::SixAttemptsWithinOneMinute),
                },
                None,
            );
        }

        if direct_bucket.total_failures >= MAX_TOTAL_FAILURES_LOCKOUT {
            direct_bucket.locked_until_ms = Some(now_ms + LOCKOUT_COOLDOWN_MS);
            return (
                LoginAdmissionDecision {
                    allowed: false,
                    login_error: Some("Too many wrong attempts".to_string()),
                    audit: Some(AlarmAuditType::ExceedThirtyAttempts),
                },
                None,
            );
        }

        // 2. Check IPv6 prefix limits if applicable
        if keys.len() > 1 {
            for &key in &keys[1..] {
                let bucket = self
                    .map
                    .entry(key)
                    .or_insert_with(|| RateLimitBucket::new(now_ms));
                bucket.normalize(now_ms);
                let (thresh, prefix_num) = match key {
                    RateLimitKey::V6Prefix64(_) => (IPV6_PREFIX_64_LIMIT, 64),
                    RateLimitKey::V6Prefix56(_) => (IPV6_PREFIX_56_LIMIT, 56),
                    RateLimitKey::V6Prefix48(_) => (IPV6_PREFIX_48_LIMIT, 48),
                    _ => continue,
                };
                if bucket.total_failures >= thresh {
                    return (
                        LoginAdmissionDecision {
                            allowed: false,
                            login_error: Some(format!(
                                "Too many wrong attempts for IPv6 prefix /{}",
                                prefix_num
                            )),
                            audit: Some(AlarmAuditType::ExceedIPv6PrefixAttempts),
                        },
                        None,
                    );
                }
            }
        }

        // 3. Atomically reserve in-flight permits across all keys
        for &key in &keys {
            if let Some(bucket) = self.map.get_mut(&key) {
                bucket.in_flight = bucket.in_flight.saturating_add(1);
                bucket.last_attempt_ms = now_ms;
            }
        }

        let permit = LoginAdmissionPermit {
            keys,
            category,
            completed: false,
        };

        (
            LoginAdmissionDecision {
                allowed: true,
                login_error: None,
                audit: None,
            },
            Some(permit),
        )
    }

    pub fn complete_attempt(
        &mut self,
        keys: &[RateLimitKey],
        category: usize,
        success: bool,
        now_ms: i64,
    ) {
        let _ = category;
        for (idx, &key) in keys.iter().enumerate() {
            if let Some(bucket) = self.map.get_mut(&key) {
                bucket.in_flight = bucket.in_flight.saturating_sub(1);
                bucket.last_attempt_ms = now_ms;
                if success {
                    if idx == 0 {
                        // Direct IP success: clear direct failure counters
                        bucket.minute_failures = 0;
                        bucket.total_failures = 0;
                        bucket.locked_until_ms = None;
                    }
                    // Prefix counters are preserved to prevent subnet wiping attacks
                } else {
                    bucket.minute_failures = bucket.minute_failures.saturating_add(1);
                    bucket.total_failures = bucket.total_failures.saturating_add(1);
                    if idx == 0 && bucket.total_failures >= MAX_TOTAL_FAILURES_LOCKOUT {
                        bucket.locked_until_ms = Some(now_ms + LOCKOUT_COOLDOWN_MS);
                    }
                }
            }
        }
    }

    pub fn release_in_flight(&mut self, keys: &[RateLimitKey]) {
        for &key in keys {
            if let Some(bucket) = self.map.get_mut(&key) {
                bucket.in_flight = bucket.in_flight.saturating_sub(1);
            }
        }
    }
}

lazy_static::lazy_static! {
    pub static ref GLOBAL_LOGIN_RATE_LIMITER: Arc<Mutex<[LoginRateLimiter; 2]>> =
        Arc::new(Mutex::new([LoginRateLimiter::new(), LoginRateLimiter::new()]));
}

pub struct LoginAdmissionPermit {
    keys: Vec<RateLimitKey>,
    category: usize,
    completed: bool,
}

impl LoginAdmissionPermit {
    pub fn complete(&mut self, success: bool) {
        if !self.completed {
            self.completed = true;
            let now_ms = get_time();
            if let Ok(mut lock) = GLOBAL_LOGIN_RATE_LIMITER.lock() {
                lock[self.category].complete_attempt(&self.keys, self.category, success, now_ms);
            }
        }
    }
}

impl Drop for LoginAdmissionPermit {
    fn drop(&mut self) {
        if !self.completed {
            self.completed = true;
            if let Ok(mut lock) = GLOBAL_LOGIN_RATE_LIMITER.lock() {
                lock[self.category].release_in_flight(&self.keys);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST_MUTEX: Mutex<()> = Mutex::new(());

    fn clear_os_credential_failure_state(scope: FailureScope) {
        if let Some(state_mutex) = state_for_os_credential_scope(scope) {
            *state_mutex.lock().unwrap() = OsCredentialFailureState::default();
        }
    }

    #[test]
    fn os_credential_policy_prioritizes_backoff() {
        let _guard = TEST_MUTEX.lock().unwrap();
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
        let now_ms = get_time();
        for _ in 0..3 {
            record_os_credential_failure(FailureScope::TerminalOsLogin);
        }
        let decision = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, now_ms);
        assert!(!decision.allowed);
        assert!(decision.login_error.is_some());
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
    }

    #[test]
    fn os_credential_policy_idle_window_resets_total_counter() {
        let _guard = TEST_MUTEX.lock().unwrap();
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
        for _ in 0..13 {
            record_os_credential_failure(FailureScope::TerminalOsLogin);
        }
        let blocked = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, get_time());
        assert!(!blocked.allowed);

        let after_failures_ms = get_time();
        let after_idle_ms = after_failures_ms + OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET_MS + 1_000;
        let allowed = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, after_idle_ms);
        assert!(allowed.allowed);
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
    }

    #[test]
    fn os_credential_policy_audits_every_backoff_block() {
        let _guard = TEST_MUTEX.lock().unwrap();
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);

        for _ in 0..3 {
            record_os_credential_failure(FailureScope::TerminalOsLogin);
        }
        let now_ms = get_time();
        let first = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, now_ms);
        let second = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, now_ms + 1_000);
        assert!(!first.allowed);
        assert!(!second.allowed);
        assert!(first.audit.is_some());
        assert!(second.audit.is_some());

        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
    }

    #[test]
    fn login_rate_limiter_enforces_in_flight_concurrency_quota() {
        let mut limiter = LoginRateLimiter::new();
        let ip: std::net::IpAddr = "192.168.1.100".parse().unwrap();
        let now = 100_000_000;

        let (d1, mut p1) = limiter.check_and_reserve(ip, now, 0);
        assert!(d1.allowed);
        assert!(p1.is_some());

        let (d2, p2) = limiter.check_and_reserve(ip, now, 0);
        assert!(d2.allowed);
        assert!(p2.is_some());

        // Third concurrent in-flight attempt must be blocked
        let (d3, p3) = limiter.check_and_reserve(ip, now, 0);
        assert!(!d3.allowed);
        assert!(p3.is_none());

        // Releasing p1 releases in-flight slot
        let permit1 = p1.as_mut().unwrap();
        limiter.release_in_flight(&permit1.keys);
        permit1.completed = true;

        let (d4, p4) = limiter.check_and_reserve(ip, now, 0);
        assert!(d4.allowed);
        assert!(p4.is_some());
    }

    #[test]
    fn login_rate_limiter_lockout_cooldown_recovers_after_15_minutes() {
        let mut limiter = LoginRateLimiter::new();
        let ip: std::net::IpAddr = "10.0.0.5".parse().unwrap();
        let mut now = 1_000_000;

        for _ in 0..30 {
            let (d, p) = limiter.check_and_reserve(ip, now, 0);
            assert!(d.allowed);
            if let Some(mut permit) = p {
                limiter.complete_attempt(&permit.keys, 0, false, now);
                permit.completed = true;
            }
            // Advance by 1 minute to avoid hitting per-minute burst rate limit
            now += 60_000;
        }

        // 31st attempt must be blocked by 30-attempt threshold
        let (d_blocked, _) = limiter.check_and_reserve(ip, now, 0);
        assert!(!d_blocked.allowed);
        assert_eq!(
            d_blocked.login_error.as_deref(),
            Some("Too many wrong attempts")
        );

        // After 15 minutes + 1ms, lockout is lifted
        now += LOCKOUT_COOLDOWN_MS + 1;
        let (d_recovered, p_recovered) = limiter.check_and_reserve(ip, now, 0);
        assert!(d_recovered.allowed);
        assert!(p_recovered.is_some());
    }

    #[test]
    fn login_rate_limiter_ipv6_prefix_accounting_is_isolated() {
        let mut limiter = LoginRateLimiter::new();
        let ip1: std::net::IpAddr = "2001:db8:abcd:0012::1".parse().unwrap();
        let ip2: std::net::IpAddr = "2001:db8:abcd:0012::2".parse().unwrap();
        let now = 1_000_000;

        // Fail from ip1
        let (_, p1) = limiter.check_and_reserve(ip1, now, 0);
        if let Some(mut permit) = p1 {
            limiter.complete_attempt(&permit.keys, 0, false, now);
            permit.completed = true;
        }

        // Login succeeds from ip2
        let (_, p2) = limiter.check_and_reserve(ip2, now, 0);
        if let Some(mut permit) = p2 {
            limiter.complete_attempt(&permit.keys, 0, true, now);
            permit.completed = true;
        }

        // Check that prefix counters were not wiped by ip2's success
        let keys1 = RateLimitKey::keys_for_addr(ip1);
        let prefix64 = keys1[1];
        let bucket = limiter.map.get(&prefix64).unwrap();
        assert_eq!(bucket.total_failures, 1);
    }
}
