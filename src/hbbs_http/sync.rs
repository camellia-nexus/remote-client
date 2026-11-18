use std::{
    collections::{BTreeMap, HashMap},
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

#[cfg(not(any(target_os = "ios")))]
use crate::{ui_interface::get_builtin_option, Connection};
#[cfg(not(any(target_os = "ios")))]
use camellia_remote_protocol::tokio::sync::watch;
use camellia_remote_protocol::{
    config::{self, keys, Config, ManagedPolicy, ManagedPolicyApplyResult},
    log,
    tokio::{self, sync::broadcast, time::Instant},
};
use serde::Deserialize;
use serde_json::{json, Value};
#[cfg(not(any(target_os = "ios")))]
use std::sync::atomic::AtomicBool;

use super::HbbHttpResponse;

const TIME_HEARTBEAT: Duration = Duration::from_secs(15);
const UPLOAD_SYSINFO_TIMEOUT: Duration = Duration::from_secs(120);
const TIME_CONN: Duration = Duration::from_secs(3);
const MAX_DEVICE_LEASE_SECONDS: u64 = 60;
const MAX_HEARTBEAT_RESPONSE_BYTES: usize = 128 * 1024;
const MANAGED_INCOMING_PENDING: u8 = 0;
const MANAGED_INCOMING_ACTIVE: u8 = 1;
const MANAGED_INCOMING_REVOKED: u8 = 2;
// Managed hosts deny incoming connections before the first authoritative
// heartbeat. Explicitly unmanaged installations bypass this state in
// `incoming_connections_allowed`.
static MANAGED_INCOMING_STATE: AtomicU8 = AtomicU8::new(MANAGED_INCOMING_PENDING);
#[cfg(not(any(target_os = "ios")))]
static MANAGED_SYNC_STARTED: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Deserialize)]
struct SysinfoVersionResponse {
    sysinfo_schema_version: u64,
}

#[derive(Debug, Deserialize)]
struct SysinfoUpdatedResponse {
    sysinfo_schema_version: u64,
    updated: bool,
}

#[cfg(not(any(target_os = "ios")))]
lazy_static::lazy_static! {
    static ref SENDER : Mutex<broadcast::Sender<Vec<i32>>> = Mutex::new(start_hbbs_sync());
    static ref PRO: Arc<Mutex<bool>> = Default::default();
}

#[cfg(not(any(target_os = "ios")))]
pub fn start() {
    if !MANAGED_SYNC_STARTED.swap(true, Ordering::SeqCst) {
        MANAGED_INCOMING_STATE.store(
            if Config::no_register_device() {
                MANAGED_INCOMING_ACTIVE
            } else {
                MANAGED_INCOMING_PENDING
            },
            Ordering::SeqCst,
        );
    }
    let _sender = SENDER.lock().unwrap();
}

#[cfg(not(target_os = "ios"))]
pub fn signal_receiver() -> broadcast::Receiver<Vec<i32>> {
    SENDER.lock().unwrap().subscribe()
}

#[cfg(not(any(target_os = "ios")))]
fn start_hbbs_sync() -> broadcast::Sender<Vec<i32>> {
    let (tx, _rx) = broadcast::channel::<Vec<i32>>(16);
    std::thread::spawn(move || start_hbbs_sync_async());
    return tx;
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DeviceLease {
    version: u8,
    state: String,
    id: String,
    uuid: String,
    #[serde(default)]
    deployment_generation: Option<u64>,
    #[serde(default)]
    valid_for_seconds: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManagedPolicyEnvelope {
    version: u8,
    id: String,
    uuid: String,
    generation: u64,
    digest: String,
    config_options: BTreeMap<String, String>,
}

enum LeaseCandidate {
    Active {
        deadline: Instant,
        deployment_generation: u64,
        id: String,
        uuid: String,
        policy: ManagedPolicy,
    },
    Revoked {
        id: String,
        uuid: String,
    },
}

#[derive(Default)]
struct ManagedLeaseTracker {
    deadline: Option<Instant>,
    deployment_generation: Option<u64>,
    id: Option<String>,
    uuid: Option<String>,
}

impl ManagedLeaseTracker {
    fn candidate_from_response(
        &self,
        response: &str,
        expected_id: &str,
        expected_uuid: &str,
        now: Instant,
    ) -> Option<LeaseCandidate> {
        if response.len() > MAX_HEARTBEAT_RESPONSE_BYTES {
            return None;
        }
        let body = serde_json::from_str::<Value>(response).ok()?;
        if body.get("response_schema_version").and_then(Value::as_u64)
            != Some(super::MANAGEMENT_RESPONSE_SCHEMA_VERSION)
        {
            return None;
        }
        let lease =
            serde_json::from_value::<DeviceLease>(body.get("device_lease")?.clone()).ok()?;
        if lease.version != 1 || lease.id != expected_id || lease.uuid != expected_uuid {
            return None;
        }
        match lease.state.as_str() {
            "active" => {
                let generation = lease.deployment_generation?;
                let seconds = lease.valid_for_seconds?;
                let same_identity = self.id.as_deref() == Some(expected_id)
                    && self.uuid.as_deref() == Some(expected_uuid);
                if seconds == 0
                    || seconds > MAX_DEVICE_LEASE_SECONDS
                    || (same_identity
                        && self
                            .deployment_generation
                            .is_some_and(|current| generation < current))
                {
                    return None;
                }
                let deadline = now.checked_add(Duration::from_secs(seconds))?;
                let envelope = serde_json::from_value::<ManagedPolicyEnvelope>(
                    body.get("managed_policy")?.clone(),
                )
                .ok()?;
                if envelope.version != 1
                    || envelope.id != expected_id
                    || envelope.uuid != expected_uuid
                {
                    return None;
                }
                let policy = ManagedPolicy::from_wire(
                    envelope.id,
                    envelope.uuid,
                    envelope.generation,
                    envelope.digest,
                    envelope.config_options,
                )?;
                Some(LeaseCandidate::Active {
                    deadline,
                    deployment_generation: generation,
                    id: lease.id,
                    uuid: lease.uuid,
                    policy,
                })
            }
            "revoked"
                if lease.deployment_generation.is_none() && lease.valid_for_seconds.is_none() =>
            {
                Some(LeaseCandidate::Revoked {
                    id: lease.id,
                    uuid: lease.uuid,
                })
            }
            _ => None,
        }
    }

    fn update_from_response_with<F>(
        &mut self,
        response: &str,
        expected_id: &str,
        expected_uuid: &str,
        now: Instant,
        apply_policy: F,
    ) -> bool
    where
        F: FnOnce(ManagedPolicy) -> ManagedPolicyApplyResult,
    {
        let Some(candidate) =
            self.candidate_from_response(response, expected_id, expected_uuid, now)
        else {
            self.clear_deadline();
            log::warn!("Managed heartbeat response is invalid; incoming sessions fail closed");
            return false;
        };
        match candidate {
            LeaseCandidate::Active {
                deadline,
                deployment_generation,
                id,
                uuid,
                policy,
            } => {
                let result = apply_policy(policy);
                if !matches!(
                    result,
                    ManagedPolicyApplyResult::Applied | ManagedPolicyApplyResult::Unchanged
                ) {
                    self.clear_deadline();
                    log::error!(
                        "Managed policy was not persisted ({result:?}); incoming sessions fail closed"
                    );
                    return false;
                }
                self.deadline = Some(deadline);
                self.deployment_generation = Some(deployment_generation);
                self.id = Some(id);
                self.uuid = Some(uuid);
                true
            }
            LeaseCandidate::Revoked { id, uuid } => {
                self.deadline = None;
                if self.id.as_deref() != Some(expected_id)
                    || self.uuid.as_deref() != Some(expected_uuid)
                {
                    self.deployment_generation = None;
                }
                self.id = Some(id);
                self.uuid = Some(uuid);
                false
            }
        }
    }

    fn is_active(&self, now: Instant) -> bool {
        self.deadline.is_some_and(|deadline| deadline > now)
    }

    fn clear_for_unmanaged(&mut self) {
        self.deadline = None;
        self.deployment_generation = None;
        self.id = None;
        self.uuid = None;
    }

    fn clear_deadline(&mut self) {
        self.deadline = None;
    }
}

fn incoming_state_allows(unmanaged: bool, state: u8) -> bool {
    unmanaged || state == MANAGED_INCOMING_ACTIVE
}

fn published_incoming_state(lease_allowed: bool, unmanaged: bool) -> u8 {
    if lease_allowed || unmanaged {
        MANAGED_INCOMING_ACTIVE
    } else {
        MANAGED_INCOMING_REVOKED
    }
}

pub fn incoming_connections_allowed() -> bool {
    incoming_state_allows(
        Config::no_register_device(),
        MANAGED_INCOMING_STATE.load(Ordering::SeqCst),
    )
}

#[cfg(not(any(target_os = "ios")))]
fn publish_managed_incoming_state(allowed: bool) {
    // `register-device=N` is an explicit unmanaged deployment contract. Keep
    // the bypass at the publication boundary as well as the admission query,
    // otherwise a stale watchdog or an optional API URL could still broadcast
    // teardown to unmanaged sessions.
    let next = published_incoming_state(allowed, Config::no_register_device());
    let allowed = next == MANAGED_INCOMING_ACTIVE;
    let previous = MANAGED_INCOMING_STATE.swap(next, Ordering::SeqCst);
    if previous == next {
        return;
    }
    if !allowed {
        let connections = Connection::alive_conns();
        if !connections.is_empty() {
            if let Ok(sender) = SENDER.lock() {
                let _ = sender.send(connections);
            }
        }
        log::warn!("Managed device lease was revoked or expired; incoming sessions are closed");
    } else {
        log::info!("Managed device lease is active; incoming sessions are enabled");
    }
    crate::rendezvous_mediator::RendezvousMediator::restart();
}

#[cfg(not(any(target_os = "ios")))]
fn set_managed_lease_deadline(
    sender: &watch::Sender<Option<Instant>>,
    deadline: Option<Instant>,
) -> bool {
    if sender.send(deadline).is_ok() {
        true
    } else {
        log::error!("Managed device lease watchdog stopped; incoming sessions fail closed");
        false
    }
}

#[cfg(not(any(target_os = "ios")))]
async fn managed_lease_watchdog(mut receiver: watch::Receiver<Option<Instant>>) {
    loop {
        let deadline = *receiver.borrow_and_update();
        let Some(deadline) = deadline else {
            if receiver.changed().await.is_err() {
                return;
            }
            continue;
        };
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                let still_current = receiver
                    .borrow()
                    .as_ref()
                    .is_some_and(|current| *current == deadline);
                if still_current {
                    publish_managed_incoming_state(false);
                }
                if receiver.changed().await.is_err() {
                    return;
                }
            }
            changed = receiver.changed() => {
                if changed.is_err() {
                    return;
                }
            }
        }
    }
}

struct InfoUploaded {
    uploaded: bool,
    url: String,
    last_uploaded: Option<Instant>,
    id: String,
    username: Option<String>,
}

impl Default for InfoUploaded {
    fn default() -> Self {
        Self {
            uploaded: false,
            url: "".to_owned(),
            last_uploaded: None,
            id: "".to_owned(),
            username: None,
        }
    }
}

impl InfoUploaded {
    fn uploaded(url: String, id: String, username: String) -> Self {
        Self {
            uploaded: true,
            url,
            last_uploaded: None,
            id,
            username: Some(username),
        }
    }
}

#[cfg(not(any(target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
async fn start_hbbs_sync_async() {
    let mut interval = crate::rustdesk_interval(tokio::time::interval_at(
        Instant::now() + TIME_CONN,
        TIME_CONN,
    ));
    let mut last_sent: Option<Instant> = None;
    let mut info_uploaded = InfoUploaded::default();
    let mut sysinfo_ver = "".to_owned();
    let mut device_lease = ManagedLeaseTracker::default();
    let (lease_deadline_tx, lease_deadline_rx) = watch::channel(None::<Instant>);
    tokio::spawn(managed_lease_watchdog(lease_deadline_rx));
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let url = heartbeat_url();
                let id = Config::get_id();
                let device_uuid = crate::encode64(camellia_remote_protocol::get_uuid());
                if url.is_empty() {
                    *PRO.lock().unwrap() = false;
                    let unmanaged = Config::no_register_device();
                    if unmanaged {
                        device_lease.clear_for_unmanaged();
                    } else {
                        device_lease.clear_deadline();
                    }
                    set_managed_lease_deadline(&lease_deadline_tx, None);
                    publish_managed_incoming_state(unmanaged);
                    continue;
                }
                publish_managed_incoming_state(device_lease.is_active(Instant::now()));
                if config::option2bool("stop-service", &Config::get_option("stop-service")) {
                    continue;
                }
                let Some(auth_header) = crate::get_api_auth_header() else {
                    *PRO.lock().unwrap() = false;
                    continue;
                };
                let conns = Connection::alive_conns();
                if info_uploaded.uploaded && (url != info_uploaded.url || id != info_uploaded.id) {
                    info_uploaded.uploaded = false;
                    *PRO.lock().unwrap() = false;
                }
                // For Windows:
                // We can't skip uploading sysinfo when the username is empty, because the username may
                // always be empty before login. We also need to upload the other sysinfo info.
                //
                // https://github.com/rustdesk/rustdesk/discussions/8031
                // We still need to check the username after uploading sysinfo, because
                // 1. The username may be empty when logining in, and it can be fetched after a while.
                //    In this case, we need to upload sysinfo again.
                // 2. The username may be changed after uploading sysinfo, and we need to upload sysinfo again.
                //
                // The Windows session will switch to the last user session before the restart,
                // so it may be able to get the username before login.
                // But strangely, sometimes we can get the username before login,
                // we may not be able to get the username before login after the next restart.
                let mut v = crate::get_sysinfo();
                let sys_username = v["username"].as_str().unwrap_or_default().to_string();
                // Though the username comparison is only necessary on Windows,
                // we still keep the comparison on other platforms for consistency.
                let need_upload = (!info_uploaded.uploaded || info_uploaded.username.as_ref() != Some(&sys_username)) &&
                    info_uploaded.last_uploaded.map(|x| x.elapsed() >= UPLOAD_SYSINFO_TIMEOUT).unwrap_or(true);
                if need_upload {
                    v["version"] = json!(crate::VERSION);
                    v["id"] = json!(id);
                    v["uuid"] = json!(device_uuid);
                    let ab_name = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_NAME);
                    if !ab_name.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_NAME] = json!(ab_name);
                    }
                    let ab_tag = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_TAG);
                    if !ab_tag.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_TAG] = json!(ab_tag);
                    }
                    let ab_alias = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_ALIAS);
                    if !ab_alias.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_ALIAS] = json!(ab_alias);
                    }
                    let ab_password = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_PASSWORD);
                    if !ab_password.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_PASSWORD] = json!(ab_password);
                    }
                    let ab_note = Config::get_option(keys::OPTION_PRESET_ADDRESS_BOOK_NOTE);
                    if !ab_note.is_empty() {
                        v[keys::OPTION_PRESET_ADDRESS_BOOK_NOTE] = json!(ab_note);
                    }
                    let username = get_builtin_option(keys::OPTION_PRESET_USERNAME);
                    if !username.is_empty() {
                        v[keys::OPTION_PRESET_USERNAME] = json!(username);
                    }
                    let strategy_name = get_builtin_option(keys::OPTION_PRESET_STRATEGY_NAME);
                    if !strategy_name.is_empty() {
                        v[keys::OPTION_PRESET_STRATEGY_NAME] = json!(strategy_name);
                    }
                    let device_group_name = get_builtin_option(keys::OPTION_PRESET_DEVICE_GROUP_NAME);
                    if !device_group_name.is_empty() {
                        v[keys::OPTION_PRESET_DEVICE_GROUP_NAME] = json!(device_group_name);
                    }
                    let device_username = Config::get_option(keys::OPTION_PRESET_DEVICE_USERNAME);
                    if !device_username.is_empty() {
                        v["username"] = json!(device_username);
                    }
                    let device_name = Config::get_option(keys::OPTION_PRESET_DEVICE_NAME);
                    if !device_name.is_empty() {
                        v["hostname"] = json!(device_name);
                    }
                    let note = Config::get_option(keys::OPTION_PRESET_NOTE);
                    if !note.is_empty() {
                        v[keys::OPTION_PRESET_NOTE] = json!(note);
                    }
                    let v = v.to_string();
                    let mut hash = "".to_owned();
                    if crate::is_public(&url) {
                        use sha2::{Digest, Sha256};
                        let mut hasher = Sha256::new();
                        hasher.update(url.as_bytes());
                        hasher.update(&v.as_bytes());
                        let res = hasher.finalize();
                        use camellia_remote_protocol::base64::{engine::general_purpose::STANDARD, Engine as _};
                        hash = STANDARD.encode(&res[..]);
                        let old_hash = config::Status::get("sysinfo_hash");
                        let ver = config::Status::get("sysinfo_ver"); // sysinfo_ver is the version of sysinfo on server's side
                        if hash == old_hash {
                            let samever = match crate::post_request(url.replace("heartbeat", "sysinfo_ver"), "".to_owned(), &auth_header).await {
                                Ok(x) => match HbbHttpResponse::<SysinfoVersionResponse>::parse(&x) {
                                    Ok(HbbHttpResponse::Data(version)) if version.sysinfo_schema_version == 1 => {
                                        sysinfo_ver = version.sysinfo_schema_version.to_string();
                                        *PRO.lock().unwrap() = true;
                                        sysinfo_ver == ver
                                    }
                                    _ => false,
                                }
                                _ => {
                                    false
                                }
                            };
                            if samever {
                                info_uploaded = InfoUploaded::uploaded(url.clone(), id.clone(), sys_username);
                                log::info!("sysinfo not changed, skip upload");
                                continue;
                            }
                        }
                    }
                    match crate::post_request(url.replace("heartbeat", "sysinfo"), v, &auth_header).await {
                        Ok(x)  => {
                            match HbbHttpResponse::<SysinfoUpdatedResponse>::parse(&x) {
                                Ok(HbbHttpResponse::Data(updated))
                                    if updated.updated && updated.sysinfo_schema_version == 1 => {
                                info_uploaded = InfoUploaded::uploaded(url.clone(), id.clone(), sys_username);
                                log::info!("sysinfo updated");
                                if !hash.is_empty() {
                                    config::Status::set("sysinfo_hash", hash);
                                    config::Status::set("sysinfo_ver", sysinfo_ver.clone());
                                }
                                *PRO.lock().unwrap() = true;
                                }
                                Ok(HbbHttpResponse::Error(error)) if error.code == "device_identity_invalid" => {
                                info_uploaded.last_uploaded = None; // next heartbeat will upload sysinfo again
                                }
                                _ => {
                                info_uploaded.last_uploaded = Some(Instant::now());
                                }
                            }
                        }
                        _ => {
                            info_uploaded.last_uploaded = Some(Instant::now());
                        }
                    }
                }
                if conns.is_empty() && last_sent.map(|x| x.elapsed() < TIME_HEARTBEAT).unwrap_or(false) {
                    continue;
                }
                last_sent = Some(Instant::now());
                let mut v = Value::default();
                v["id"] = json!(id);
                v["uuid"] = json!(device_uuid);
                v["ver"] = json!(camellia_remote_protocol::get_version_number(crate::VERSION));
                if !conns.is_empty() {
                    v["conns"] = json!(conns);
                }
                if let Ok(s) = crate::post_request(url.clone(), v.to_string(), &auth_header).await {
                    let mut allowed = device_lease.update_from_response_with(
                        &s,
                        &id,
                        &device_uuid,
                        Instant::now(),
                        Config::apply_managed_policy,
                    );
                    let watchdog_ready = set_managed_lease_deadline(
                        &lease_deadline_tx,
                        if allowed { device_lease.deadline } else { None },
                    );
                    if !watchdog_ready {
                        device_lease.clear_deadline();
                        allowed = false;
                    }
                    publish_managed_incoming_state(allowed);
                    if let Ok(mut rsp) = serde_json::from_str::<HashMap::<&str, Value>>(&s) {
                        rsp.remove("device_lease");
                        rsp.remove("managed_policy");
                        if rsp.remove("sysinfo").is_some() {
                            info_uploaded.uploaded = false;
                            config::Status::set("sysinfo_hash", "".to_owned());
                            log::info!("sysinfo required to forcely update");
                        }
                        if let Some(conns)  = rsp.remove("disconnect") {
                                if let Ok(conns) = serde_json::from_value::<Vec<i32>>(conns) {
                                    SENDER.lock().unwrap().send(conns).ok();
                                }
                        }
                    }
                }
            }
        }
    }
}

fn heartbeat_url() -> String {
    let url = crate::common::get_api_server(
        Config::get_option("api-server"),
        Config::get_option("custom-rendezvous-server"),
    );
    if url.is_empty() {
        return "".to_owned();
    }
    format!("{}/api/heartbeat", url)
}

#[allow(unused)]
#[cfg(not(any(target_os = "ios")))]
pub fn is_pro() -> bool {
    PRO.lock().unwrap().clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn active_lease(id: &str, uuid: &str, generation: u64, seconds: u64) -> String {
        active_policy(id, uuid, generation, seconds, generation, BTreeMap::new())
    }

    fn active_policy(
        id: &str,
        uuid: &str,
        deployment_generation: u64,
        seconds: u64,
        policy_generation: u64,
        config_options: BTreeMap<String, String>,
    ) -> String {
        let digest = ManagedPolicy::canonical_digest(&config_options).unwrap();
        serde_json::json!({
            "device_lease": {
                "version": 1,
                "state": "active",
                "id": id,
                "uuid": uuid,
                "deployment_generation": deployment_generation,
                "valid_for_seconds": seconds,
            },
            "managed_policy": {
                "version": 1,
                "id": id,
                "uuid": uuid,
                "generation": policy_generation,
                "digest": digest,
                "config_options": config_options,
            }
        })
        .to_string()
    }

    fn apply_success(_policy: ManagedPolicy) -> ManagedPolicyApplyResult {
        ManagedPolicyApplyResult::Applied
    }

    #[test]
    fn managed_lease_binds_identity_generation_and_monotonic_deadline() {
        let now = Instant::now();
        let mut tracker = ManagedLeaseTracker::default();
        assert!(tracker.update_from_response_with(
            &active_lease("device01", "dXVpZA==", 7, 60),
            "device01",
            "dXVpZA==",
            now,
            apply_success,
        ));
        assert!(tracker.is_active(now));
        for invalid in [
            active_lease("other", "dXVpZA==", 8, 60),
            active_lease("device01", "b3RoZXI=", 8, 60),
            active_lease("device01", "dXVpZA==", 6, 60),
            active_lease("device01", "dXVpZA==", 8, 61),
            active_lease("device01", "dXVpZA==", 8, 0),
        ] {
            assert!(!tracker.update_from_response_with(
                &invalid,
                "device01",
                "dXVpZA==",
                now,
                |_| panic!("invalid lease must not apply a policy"),
            ));
            assert!(!tracker.is_active(now));
        }
        let unknown_field = serde_json::json!({
            "device_lease": {
                "version": 1,
                "state": "active",
                "id": "device01",
                "uuid": "dXVpZA==",
                "deployment_generation": 8,
                "valid_for_seconds": 60,
                "unexpected": true,
            }
        })
        .to_string();
        assert!(!tracker.update_from_response_with(
            &unknown_field,
            "device01",
            "dXVpZA==",
            now,
            |_| panic!("unknown lease fields must not apply a policy"),
        ));
        assert!(!tracker.is_active(now));
    }

    #[test]
    fn explicit_revocation_and_lease_expiry_fail_closed() {
        let now = Instant::now();
        let mut tracker = ManagedLeaseTracker::default();
        assert!(tracker.update_from_response_with(
            &active_lease("device01", "dXVpZA==", 1, 1),
            "device01",
            "dXVpZA==",
            now,
            apply_success,
        ));
        let malformed_revocation = serde_json::json!({
            "device_lease": {
                "version": 1,
                "state": "revoked",
                "id": "device01",
                "uuid": "dXVpZA==",
                "deployment_generation": 1,
            }
        })
        .to_string();
        assert!(!tracker.update_from_response_with(
            &malformed_revocation,
            "device01",
            "dXVpZA==",
            now,
            |_| panic!("revocation must not apply a policy"),
        ));
        assert!(!tracker.is_active(now));
        assert!(!tracker.is_active(now + Duration::from_secs(2)));
        let revoked = serde_json::json!({
            "device_lease": {
                "version": 1,
                "state": "revoked",
                "id": "device01",
                "uuid": "dXVpZA==",
            }
        })
        .to_string();
        assert!(!tracker.update_from_response_with(
            &revoked,
            "device01",
            "dXVpZA==",
            now,
            |_| panic!("revocation must not apply a policy"),
        ));
        assert!(!tracker.is_active(now));
        assert!(tracker.update_from_response_with(
            &active_lease("device01", "dXVpZA==", 1, 60),
            "device01",
            "dXVpZA==",
            now,
            apply_success,
        ));
        assert!(tracker.is_active(now));
    }

    #[test]
    fn a_new_bound_identity_starts_its_own_generation_sequence() {
        let now = Instant::now();
        let mut tracker = ManagedLeaseTracker::default();
        assert!(tracker.update_from_response_with(
            &active_lease("device01", "dXVpZC0x", 7, 60),
            "device01",
            "dXVpZC0x",
            now,
            apply_success,
        ));
        assert!(tracker.update_from_response_with(
            &active_lease("device02", "dXVpZC0y", 1, 60),
            "device02",
            "dXVpZC0y",
            now,
            apply_success,
        ));
        assert_eq!(tracker.deployment_generation, Some(1));
    }

    #[test]
    fn policy_is_validated_and_persisted_before_the_lease_becomes_active() {
        let now = Instant::now();
        let mut tracker = ManagedLeaseTracker::default();
        let persisted = Cell::new(false);
        let response = active_policy(
            "device01",
            "dXVpZA==",
            3,
            60,
            9,
            BTreeMap::from([
                ("approve-mode".to_owned(), "password".to_owned()),
                ("unicode".to_owned(), "雪/é".to_owned()),
            ]),
        );

        assert!(tracker.update_from_response_with(
            &response,
            "device01",
            "dXVpZA==",
            now,
            |policy| {
                assert_eq!(policy.generation(), 9);
                assert_eq!(
                    policy.options().get("approve-mode").map(String::as_str),
                    Some("password")
                );
                persisted.set(true);
                ManagedPolicyApplyResult::Applied
            },
        ));
        assert!(persisted.get());
        assert!(tracker.is_active(now));
    }

    #[test]
    fn malformed_or_unpersisted_policy_fails_closed() {
        let now = Instant::now();
        let mut tracker = ManagedLeaseTracker::default();
        let valid = active_lease("device01", "dXVpZA==", 3, 60);
        assert!(tracker.update_from_response_with(
            &valid,
            "device01",
            "dXVpZA==",
            now,
            apply_success,
        ));

        let mut wrong_digest = serde_json::from_str::<Value>(&valid).unwrap();
        wrong_digest["managed_policy"]["digest"] = json!("0".repeat(64));
        assert!(!tracker.update_from_response_with(
            &wrong_digest.to_string(),
            "device01",
            "dXVpZA==",
            now,
            |_| panic!("invalid digest must be rejected before persistence"),
        ));
        assert!(!tracker.is_active(now));

        let mut unknown_field = serde_json::from_str::<Value>(&valid).unwrap();
        unknown_field["managed_policy"]["unexpected"] = json!(true);
        assert!(!tracker.update_from_response_with(
            &unknown_field.to_string(),
            "device01",
            "dXVpZA==",
            now,
            |_| panic!("unknown policy fields must be rejected before persistence"),
        ));

        for rejected in [
            ManagedPolicyApplyResult::RejectedInvalid,
            ManagedPolicyApplyResult::RejectedRollback,
            ManagedPolicyApplyResult::RejectedConflict,
            ManagedPolicyApplyResult::StoreFailed,
        ] {
            assert!(!tracker.update_from_response_with(
                &valid,
                "device01",
                "dXVpZA==",
                now,
                |_| rejected,
            ));
            assert!(!tracker.is_active(now));
        }

        let oversized = "x".repeat(MAX_HEARTBEAT_RESPONSE_BYTES + 1);
        assert!(!tracker.update_from_response_with(
            &oversized,
            "device01",
            "dXVpZA==",
            now,
            |_| panic!("oversized responses must not reach persistence"),
        ));
    }

    #[test]
    fn managed_incoming_admission_starts_closed_and_unmanaged_bypasses_the_lease() {
        assert!(!incoming_state_allows(false, MANAGED_INCOMING_PENDING));
        assert!(!incoming_state_allows(false, MANAGED_INCOMING_REVOKED));
        assert!(incoming_state_allows(false, MANAGED_INCOMING_ACTIVE));
        assert!(incoming_state_allows(true, MANAGED_INCOMING_PENDING));
        assert_eq!(
            published_incoming_state(false, true),
            MANAGED_INCOMING_ACTIVE
        );
        assert_eq!(
            published_incoming_state(false, false),
            MANAGED_INCOMING_REVOKED
        );
    }

    #[tokio::test]
    async fn watchdog_revokes_an_active_state_at_the_monotonic_deadline() {
        MANAGED_INCOMING_STATE.store(MANAGED_INCOMING_ACTIVE, Ordering::SeqCst);
        let deadline = Instant::now() + Duration::from_millis(10);
        let (sender, receiver) = watch::channel(Some(deadline));
        let watchdog = tokio::spawn(managed_lease_watchdog(receiver));

        tokio::time::sleep(Duration::from_millis(30)).await;

        assert_eq!(
            MANAGED_INCOMING_STATE.load(Ordering::SeqCst),
            MANAGED_INCOMING_REVOKED
        );
        drop(sender);
        watchdog.await.unwrap();
        MANAGED_INCOMING_STATE.store(MANAGED_INCOMING_PENDING, Ordering::SeqCst);
    }
}
