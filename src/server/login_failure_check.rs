use crate::AlarmAuditType;
#[cfg(target_os = "windows")]
use camellia_remote_protocol::tokio::sync::{Mutex as TokioMutex, OwnedMutexGuard};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET: Duration = Duration::from_secs(120 * 60);
const OS_CREDENTIAL_LOGIN_BACKOFF_BASE_SECONDS: u64 = 15;
const OS_CREDENTIAL_LOGIN_BACKOFF_MAX_SECONDS: u64 = 30 * 60;

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum FailureScope {
    Default,
    TerminalOsLogin,
}

pub struct OsCredentialPolicyDecision {
    pub allowed: bool,
    pub login_error: Option<String>,
    pub audit: Option<AlarmAuditType>,
}

#[derive(Copy, Clone, Debug, Default)]
struct OsCredentialFailureState {
    total_failures: i32,
    backoff_until: Option<Instant>,
    last_failure: Option<Instant>,
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

fn os_credential_login_backoff_seconds(total_failures: i32) -> u64 {
    if total_failures <= 2 {
        return 0;
    }
    let exp = (total_failures - 3).min(7) as u32;
    let seconds = OS_CREDENTIAL_LOGIN_BACKOFF_BASE_SECONDS.saturating_mul(1_u64 << exp);
    seconds.min(OS_CREDENTIAL_LOGIN_BACKOFF_MAX_SECONDS)
}

fn normalize_backoff(state: &mut OsCredentialFailureState, now: Instant) {
    if let Some(until) = state.backoff_until {
        if now >= until {
            state.backoff_until = None;
        }
    }
}

fn reset_totals_on_idle(state: &mut OsCredentialFailureState, now: Instant) {
    if let Some(last) = state.last_failure {
        if now.saturating_duration_since(last) >= OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET {
            state.total_failures = 0;
            state.backoff_until = None;
            state.last_failure = None;
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

pub fn evaluate_os_credential_policy(scope: FailureScope) -> OsCredentialPolicyDecision {
    evaluate_os_credential_policy_at(scope, Instant::now())
}

pub fn evaluate_os_credential_policy_at(
    scope: FailureScope,
    now: Instant,
) -> OsCredentialPolicyDecision {
    if !is_os_credential_scope(scope) {
        return allow_decision();
    }
    let Some(state_mutex) = state_for_os_credential_scope(scope) else {
        return allow_decision();
    };
    let mut state = state_mutex.lock().unwrap();
    reset_totals_on_idle(&mut state, now);
    normalize_backoff(&mut state, now);

    if let Some(until) = state.backoff_until {
        if now < until {
            let remaining = until.saturating_duration_since(now);
            let remaining_seconds = remaining.as_millis().div_ceil(1_000).max(1);
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
            state.backoff_until = None;
            allow_decision()
        }
    } else {
        allow_decision()
    }
}

pub fn record_os_credential_failure(scope: FailureScope) {
    record_os_credential_failure_at(scope, Instant::now());
}

pub fn record_os_credential_failure_at(scope: FailureScope, now: Instant) {
    if !is_os_credential_scope(scope) {
        return;
    }
    let Some(state_mutex) = state_for_os_credential_scope(scope) else {
        return;
    };
    let mut state = state_mutex.lock().unwrap();
    reset_totals_on_idle(&mut state, now);
    normalize_backoff(&mut state, now);
    state.total_failures = state.total_failures.saturating_add(1);
    state.last_failure = Some(now);
    let backoff_seconds = os_credential_login_backoff_seconds(state.total_failures);
    if backoff_seconds > 0 {
        state.backoff_until = Some(now + Duration::from_secs(backoff_seconds));
    }
}

pub fn reset_os_credential_failure_state() {
    if let Some(state_mutex) = state_for_os_credential_scope(FailureScope::TerminalOsLogin) {
        if let Ok(mut state) = state_mutex.lock() {
            *state = OsCredentialFailureState::default();
        }
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
// AUTH-003, RES-010, AUTH-024: Monotonic Login Rate Limiter & Atomic Reservation
// ============================================================================

pub const MAX_RATE_LIMIT_ENTRIES: usize = 4_096;
pub const MAX_IN_FLIGHT_PER_IP: u32 = 2;
pub const MAX_FAILURES_PER_MINUTE: u32 = 6;
pub const MAX_TOTAL_FAILURES_LOCKOUT: u32 = 30;
pub const LOCKOUT_COOLDOWN: Duration = Duration::from_secs(15 * 60);
pub const TOTAL_IDLE_RESET: Duration = Duration::from_secs(120 * 60);
pub const RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);

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

#[derive(Clone, Debug)]
pub struct RateLimitBucket {
    pub in_flight: u32,
    pub recent_failures: Vec<Instant>,
    pub total_failures: u32,
    pub last_attempt: Instant,
    pub locked_until: Option<Instant>,
}

impl RateLimitBucket {
    pub fn new(now: Instant) -> Self {
        Self {
            in_flight: 0,
            recent_failures: Vec::with_capacity(8),
            total_failures: 0,
            last_attempt: now,
            locked_until: None,
        }
    }

    pub fn minute_failures(&self) -> u32 {
        self.recent_failures.len() as u32
    }

    pub fn normalize(&mut self, now: Instant) {
        if now.saturating_duration_since(self.last_attempt) >= TOTAL_IDLE_RESET {
            self.recent_failures.clear();
            self.total_failures = 0;
            self.locked_until = None;
        }
        self.recent_failures
            .retain(|&t| now.saturating_duration_since(t) < RATE_LIMIT_WINDOW);
        if let Some(until) = self.locked_until {
            if now >= until {
                self.locked_until = None;
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
    pub(crate) map: std::collections::HashMap<RateLimitKey, RateLimitBucket>,
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

    fn prune_if_needed(&mut self, now: Instant) {
        if self.map.len() >= MAX_RATE_LIMIT_ENTRIES {
            self.map.retain(|_, b| {
                b.in_flight > 0 || now.saturating_duration_since(b.last_attempt) < TOTAL_IDLE_RESET
            });
            if self.map.len() >= MAX_RATE_LIMIT_ENTRIES {
                let mut removable: Vec<(RateLimitKey, Instant)> = self
                    .map
                    .iter()
                    .filter(|(_, b)| b.in_flight == 0)
                    .map(|(&k, b)| (k, b.last_attempt))
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
        category: usize,
    ) -> (LoginAdmissionDecision, Option<LoginAdmissionPermit>) {
        self.check_and_reserve_at(addr, Instant::now(), category)
    }

    pub fn check_and_reserve_at(
        &mut self,
        addr: std::net::IpAddr,
        now: Instant,
        category: usize, // 0 for primary password, 1 for 2fa
    ) -> (LoginAdmissionDecision, Option<LoginAdmissionPermit>) {
        self.prune_if_needed(now);

        let keys = RateLimitKey::keys_for_addr(addr);

        // 1. Check direct IP limits
        let direct_key = keys[0];
        let direct_bucket = self
            .map
            .entry(direct_key)
            .or_insert_with(|| RateLimitBucket::new(now));
        direct_bucket.normalize(now);

        if let Some(until) = direct_bucket.locked_until {
            if now < until {
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

        if direct_bucket.minute_failures() + direct_bucket.in_flight >= MAX_FAILURES_PER_MINUTE {
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
            direct_bucket.locked_until = Some(now + LOCKOUT_COOLDOWN);
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
                    .or_insert_with(|| RateLimitBucket::new(now));
                bucket.normalize(now);
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
                bucket.last_attempt = now;
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

    pub fn complete_attempt_at(
        &mut self,
        keys: &[RateLimitKey],
        category: usize,
        success: bool,
        now: Instant,
    ) {
        let _ = category;
        for (idx, &key) in keys.iter().enumerate() {
            if let Some(bucket) = self.map.get_mut(&key) {
                bucket.in_flight = bucket.in_flight.saturating_sub(1);
                bucket.last_attempt = now;
                if success {
                    if idx == 0 {
                        // Direct IP success: clear direct failure counters
                        bucket.recent_failures.clear();
                        bucket.total_failures = 0;
                        bucket.locked_until = None;
                    }
                    // Prefix counters are preserved to prevent subnet wiping attacks
                } else {
                    bucket.recent_failures.push(now);
                    bucket.total_failures = bucket.total_failures.saturating_add(1);
                    if idx == 0 && bucket.total_failures >= MAX_TOTAL_FAILURES_LOCKOUT {
                        bucket.locked_until = Some(now + LOCKOUT_COOLDOWN);
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

pub fn reset_global_login_rate_limiter() {
    if let Ok(mut lock) = GLOBAL_LOGIN_RATE_LIMITER.lock() {
        *lock = [LoginRateLimiter::new(), LoginRateLimiter::new()];
    }
}

pub fn reset_login_failure_state() {
    reset_os_credential_failure_state();
    reset_global_login_rate_limiter();
}

pub struct LoginAdmissionPermit {
    pub keys: Vec<RateLimitKey>,
    pub category: usize,
    pub completed: bool,
}

impl LoginAdmissionPermit {
    pub fn complete(&mut self, success: bool) {
        if !self.completed {
            self.completed = true;
            let now = Instant::now();
            if let Ok(mut lock) = GLOBAL_LOGIN_RATE_LIMITER.lock() {
                lock[self.category].complete_attempt_at(&self.keys, self.category, success, now);
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
        let now = Instant::now();
        for _ in 0..3 {
            record_os_credential_failure_at(FailureScope::TerminalOsLogin, now);
        }
        let decision = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, now);
        assert!(!decision.allowed);
        assert!(decision.login_error.is_some());
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
    }

    #[test]
    fn os_credential_policy_idle_window_resets_total_counter() {
        let _guard = TEST_MUTEX.lock().unwrap();
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
        let start = Instant::now();
        for _ in 0..13 {
            record_os_credential_failure_at(FailureScope::TerminalOsLogin, start);
        }
        let blocked = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, start);
        assert!(!blocked.allowed);

        let after_idle = start + OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET + Duration::from_secs(1);
        let allowed = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, after_idle);
        assert!(allowed.allowed);
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
    }

    #[test]
    fn os_credential_policy_audits_every_backoff_block() {
        let _guard = TEST_MUTEX.lock().unwrap();
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
        let now = Instant::now();

        for _ in 0..3 {
            record_os_credential_failure_at(FailureScope::TerminalOsLogin, now);
        }
        let first = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, now);
        let second = evaluate_os_credential_policy_at(
            FailureScope::TerminalOsLogin,
            now + Duration::from_secs(1),
        );
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
        let now = Instant::now();

        let (d1, mut p1) = limiter.check_and_reserve_at(ip, now, 0);
        assert!(d1.allowed);
        assert!(p1.is_some());

        let (d2, p2) = limiter.check_and_reserve_at(ip, now, 0);
        assert!(d2.allowed);
        assert!(p2.is_some());

        // Third concurrent in-flight attempt must be blocked
        let (d3, p3) = limiter.check_and_reserve_at(ip, now, 0);
        assert!(!d3.allowed);
        assert!(p3.is_none());

        // Releasing p1 releases in-flight slot
        let permit1 = p1.as_mut().unwrap();
        limiter.release_in_flight(&permit1.keys);
        permit1.completed = true;

        let (d4, p4) = limiter.check_and_reserve_at(ip, now, 0);
        assert!(d4.allowed);
        assert!(p4.is_some());
    }

    #[test]
    fn login_rate_limiter_lockout_cooldown_recovers_after_15_minutes() {
        let mut limiter = LoginRateLimiter::new();
        let ip: std::net::IpAddr = "10.0.0.5".parse().unwrap();
        let mut now = Instant::now();

        for _ in 0..30 {
            let (d, p) = limiter.check_and_reserve_at(ip, now, 0);
            assert!(d.allowed);
            if let Some(mut permit) = p {
                limiter.complete_attempt_at(&permit.keys, 0, false, now);
                permit.completed = true;
            }
            // Advance by 1 minute to avoid hitting per-minute burst rate limit
            now += Duration::from_secs(61);
        }

        // 31st attempt must be blocked by 30-attempt threshold
        let (d_blocked, _) = limiter.check_and_reserve_at(ip, now, 0);
        assert!(!d_blocked.allowed);
        assert_eq!(
            d_blocked.login_error.as_deref(),
            Some("Too many wrong attempts")
        );

        // After 15 minutes + 1s, lockout is lifted
        now += LOCKOUT_COOLDOWN + Duration::from_secs(1);
        let (d_recovered, p_recovered) = limiter.check_and_reserve_at(ip, now, 0);
        assert!(d_recovered.allowed);
        assert!(p_recovered.is_some());
    }

    #[test]
    fn login_rate_limiter_ipv6_prefix_accounting_is_isolated() {
        let mut limiter = LoginRateLimiter::new();
        let ip1: std::net::IpAddr = "2001:db8:abcd:0012::1".parse().unwrap();
        let ip2: std::net::IpAddr = "2001:db8:abcd:0012::2".parse().unwrap();
        let now = Instant::now();

        // Fail from ip1
        let (_, p1) = limiter.check_and_reserve_at(ip1, now, 0);
        if let Some(mut permit) = p1 {
            limiter.complete_attempt_at(&permit.keys, 0, false, now);
            permit.completed = true;
        }

        // Login succeeds from ip2
        let (_, p2) = limiter.check_and_reserve_at(ip2, now, 0);
        if let Some(mut permit) = p2 {
            limiter.complete_attempt_at(&permit.keys, 0, true, now);
            permit.completed = true;
        }

        // Check that prefix counters were not wiped by ip2's success
        let keys1 = RateLimitKey::keys_for_addr(ip1);
        let prefix64 = keys1[1];
        let bucket = limiter.map.get(&prefix64).unwrap();
        assert_eq!(bucket.total_failures, 1);
    }
}
