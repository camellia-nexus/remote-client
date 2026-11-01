use super::HbbHttpResponse;
use camellia_remote_protocol::{
    config::LocalConfig, log, tokio_util::sync::CancellationToken, ResultType,
};
use serde_derive::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};
use std::{
    collections::HashMap,
    sync::{Arc, RwLock},
    time::{Duration, Instant},
};
use url::Url;

lazy_static::lazy_static! {
    static ref OIDC_SESSION: Arc<RwLock<OidcSession>> = Arc::new(RwLock::new(OidcSession::new()));
}

const QUERY_INTERVAL_SECS: f32 = 1.0;
const QUERY_TIMEOUT_SECS: u64 = 60 * 3;

const REQUESTING_ACCOUNT_AUTH: &str = "Requesting account auth";
const WAITING_ACCOUNT_AUTH: &str = "Waiting account auth";
const LOGIN_ACCOUNT_AUTH: &str = "Login account auth";

fn oidc_query_body(code: &str, id: &str, uuid: &str) -> String {
    serde_json::json!({
        "code": code,
        "id": id,
        "uuid": uuid,
    })
    .to_string()
}

#[derive(Deserialize, Clone, Debug)]
pub struct OidcAuthUrl {
    code: String,
    url: Url,
}

#[derive(Debug, Deserialize, Serialize, Default, Clone)]
pub struct DeviceInfo {
    /// Linux , Windows , Android ...
    #[serde(default)]
    pub os: String,

    /// `browser` or `client`
    #[serde(default)]
    pub r#type: String,

    /// device name from rustdesk client,
    /// browser info(name + version) from browser
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WhitelistItem {
    data: String, // ip / device uuid
    info: DeviceInfo,
    exp: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UserInfo {
    #[serde(default, flatten)]
    pub settings: UserSettings,
    #[serde(default)]
    pub login_device_whitelist: Vec<WhitelistItem>,
    #[serde(default)]
    pub other: HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UserSettings {
    #[serde(default)]
    pub email_verification: bool,
    #[serde(default)]
    pub email_alarm_notification: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(i64)]
pub enum UserStatus {
    Disabled = 0,
    Normal = 1,
    Unverified = -1,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserPayload {
    pub name: String,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub avatar: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub status: UserStatus,
    pub info: UserInfo,
    #[serde(default)]
    pub is_admin: bool,
    #[serde(default)]
    pub third_auth_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthBody {
    pub access_token: String,
    pub r#type: String,
    #[serde(default)]
    pub tfa_type: String,
    #[serde(default)]
    pub secret: String,
    pub user: UserPayload,
}

pub struct OidcSession {
    state_msg: &'static str,
    failed_msg: String,
    code_url: Option<OidcAuthUrl>,
    auth_body: Option<AuthBody>,
    keep_querying: bool,
    running: bool,
    query_timeout: Duration,
    generation: u64,
    cancel_token: CancellationToken,
    worker_handle: Option<std::thread::JoinHandle<()>>,
}

#[derive(Serialize)]
pub struct AuthResult {
    pub state_msg: String,
    pub failed_msg: String,
    pub url: Option<String>,
    pub auth_body: Option<AuthBody>,
}

impl Default for UserStatus {
    fn default() -> Self {
        UserStatus::Normal
    }
}

impl OidcSession {
    fn new() -> Self {
        Self {
            state_msg: REQUESTING_ACCOUNT_AUTH,
            failed_msg: "".to_owned(),
            code_url: None,
            auth_body: None,
            keep_querying: false,
            running: false,
            query_timeout: Duration::from_secs(QUERY_TIMEOUT_SECS),
            generation: 0,
            cancel_token: CancellationToken::new(),
            worker_handle: None,
        }
    }

    fn auth(
        api_server: &str,
        op: &str,
        id: &str,
        uuid: &str,
    ) -> ResultType<HbbHttpResponse<OidcAuthUrl>> {
        let device_proof =
            crate::device_identity::request_device_proof(api_server, "oidc", id, uuid, "")?;
        let body = serde_json::json!({
            "op": op,
            "id": id,
            "uuid": uuid,
            "deviceInfo": crate::ui_interface::get_login_device_info(),
            "device_proof": device_proof,
        })
        .to_string();
        let resp = crate::post_request_sync(format!("{}/api/oidc/auth", api_server), body, "")?;
        HbbHttpResponse::parse(&resp)
    }

    fn query(
        api_server: &str,
        code: &str,
        id: &str,
        uuid: &str,
    ) -> ResultType<HbbHttpResponse<AuthBody>> {
        let resp = crate::post_request_sync(
            format!("{}/api/oidc/auth-query", api_server),
            oidc_query_body(code, id, uuid),
            "",
        )?;
        HbbHttpResponse::parse(&resp)
    }

    fn reset(&mut self) {
        self.state_msg = REQUESTING_ACCOUNT_AUTH;
        self.failed_msg = "".to_owned();
        self.keep_querying = true;
        self.running = false;
        self.code_url = None;
        self.auth_body = None;
    }

    fn before_task(&mut self) {
        self.reset();
        self.running = true;
    }

    fn after_task(&mut self) {
        self.running = false;
    }


    fn auth_task(
        api_server: String,
        op: String,
        id: String,
        uuid: String,
        remember_me: bool,
        generation: u64,
        cancel_token: CancellationToken,
    ) {
        if cancel_token.is_cancelled() {
            return;
        }
        let auth_request_res = Self::auth(&api_server, &op, &id, &uuid);
        log::info!("Request oidc auth result: {:?}", &auth_request_res);
        if cancel_token.is_cancelled() {
            log::info!("OIDC auth cancelled after initial auth request");
            return;
        }

        let code_url = match auth_request_res {
            Ok(HbbHttpResponse::<_>::Data(code_url)) => code_url,
            Ok(HbbHttpResponse::<_>::Error(err)) => {
                let mut session = OIDC_SESSION.write().unwrap();
                if session.generation == generation && !cancel_token.is_cancelled() {
                    session.set_state(REQUESTING_ACCOUNT_AUTH, err);
                }
                return;
            }
            Ok(_) => {
                let mut session = OIDC_SESSION.write().unwrap();
                if session.generation == generation && !cancel_token.is_cancelled() {
                    session.set_state(REQUESTING_ACCOUNT_AUTH, "Invalid auth response".to_owned());
                }
                return;
            }
            Err(err) => {
                let mut session = OIDC_SESSION.write().unwrap();
                if session.generation == generation && !cancel_token.is_cancelled() {
                    session.set_state(REQUESTING_ACCOUNT_AUTH, err.to_string());
                }
                return;
            }
        };

        {
            let mut session = OIDC_SESSION.write().unwrap();
            if session.generation != generation || cancel_token.is_cancelled() {
                log::info!("OIDC session generation changed or cancelled before setting code_url");
                return;
            }
            session.set_state(WAITING_ACCOUNT_AUTH, "".to_owned());
            session.code_url = Some(code_url.clone());
        }

        let begin = Instant::now();
        let query_timeout = OIDC_SESSION.read().unwrap().query_timeout;
        while !cancel_token.is_cancelled() && begin.elapsed() < query_timeout {
            {
                let session = OIDC_SESSION.read().unwrap();
                if session.generation != generation || !session.keep_querying {
                    break;
                }
            }
            match Self::query(&api_server, &code_url.code, &id, &uuid) {
                Ok(HbbHttpResponse::<_>::Data(auth_body)) => {
                    let mut session = OIDC_SESSION.write().unwrap();
                    if session.generation != generation || cancel_token.is_cancelled() {
                        return;
                    }
                    if auth_body.r#type == "access_token" {
                        if remember_me {
                            LocalConfig::set_option(
                                "access_token".to_owned(),
                                auth_body.access_token.clone(),
                            );
                            LocalConfig::set_option(
                                "user_info".to_owned(),
                                serde_json::json!({
                                    "name": auth_body.user.name,
                                    "display_name": auth_body.user.display_name,
                                    "avatar": auth_body.user.avatar,
                                    "status": auth_body.user.status
                                })
                                .to_string(),
                            );
                        }
                    }
                    session.set_state(LOGIN_ACCOUNT_AUTH, "".to_owned());
                    session.auth_body = Some(auth_body);
                    return;
                }
                Ok(HbbHttpResponse::<_>::Error(err)) => {
                    if err.contains("No authed oidc is found") {
                        // ignore, keep querying
                    } else {
                        let mut session = OIDC_SESSION.write().unwrap();
                        if session.generation == generation && !cancel_token.is_cancelled() {
                            session.set_state(WAITING_ACCOUNT_AUTH, err);
                        }
                        return;
                    }
                }
                Ok(_) => {
                    // ignore
                }
                Err(err) => {
                    log::trace!("Failed query oidc {}", err);
                    // ignore
                }
            }

            // Bounded cooperative sleep checking cancellation token
            let sleep_start = Instant::now();
            let interval = Duration::from_secs_f32(QUERY_INTERVAL_SECS);
            while sleep_start.elapsed() < interval {
                if cancel_token.is_cancelled() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        }

        if begin.elapsed() >= query_timeout {
            let mut session = OIDC_SESSION.write().unwrap();
            if session.generation == generation && !cancel_token.is_cancelled() {
                session.set_state(WAITING_ACCOUNT_AUTH, "timeout".to_owned());
            }
        }
    }

    fn set_state(&mut self, state_msg: &'static str, failed_msg: String) {
        self.state_msg = state_msg;
        self.failed_msg = failed_msg;
    }

    pub fn account_auth(
        api_server: String,
        op: String,
        id: String,
        uuid: String,
        remember_me: bool,
    ) {
        let (generation, cancel_token, prev_worker) = {
            let mut session = OIDC_SESSION.write().unwrap();
            // Cooperative cancellation of previous worker
            session.cancel_token.cancel();
            let prev_worker = session.worker_handle.take();
            let new_cancel_token = CancellationToken::new();
            session.cancel_token = new_cancel_token.clone();
            session.generation = session.generation.wrapping_add(1);
            let gen = session.generation;
            session.before_task();
            (gen, new_cancel_token, prev_worker)
        };

        // Bounded join deadline (500ms) for previous worker, without holding write lock
        if let Some(handle) = prev_worker {
            let deadline = Duration::from_millis(500);
            let start = Instant::now();
            while !handle.is_finished() && start.elapsed() < deadline {
                std::thread::sleep(Duration::from_millis(10));
            }
            if handle.is_finished() {
                let _ = handle.join();
            } else {
                log::warn!(
                    "Previous OIDC worker did not exit within 500ms; detaching safely under generation isolation"
                );
            }
        }

        let handle = std::thread::spawn(move || {
            Self::auth_task(
                api_server,
                op,
                id,
                uuid,
                remember_me,
                generation,
                cancel_token,
            );
            let mut session = OIDC_SESSION.write().unwrap();
            if session.generation == generation {
                session.after_task();
                session.worker_handle = None;
            }
        });

        OIDC_SESSION.write().unwrap().worker_handle = Some(handle);
    }

    fn get_result_(&self) -> AuthResult {
        AuthResult {
            state_msg: self.state_msg.to_string(),
            failed_msg: self.failed_msg.clone(),
            url: self.code_url.as_ref().map(|x| x.url.to_string()),
            auth_body: self.auth_body.clone(),
        }
    }

    pub fn auth_cancel() {
        let mut session = OIDC_SESSION.write().unwrap();
        session.cancel_token.cancel();
        session.keep_querying = false;
        session.running = false;
        session.code_url = None;
        session.auth_body = None;
        session.set_state("", "cancelled".to_owned());
    }

    pub fn get_result() -> AuthResult {
        OIDC_SESSION.read().unwrap().get_result_()
    }

    #[cfg(test)]
    pub fn current_generation() -> u64 {
        OIDC_SESSION.read().unwrap().generation
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oidc_poll_credentials_are_serialized_in_the_post_body() {
        let body = oidc_query_body("poll-code-canary", "123456789", "device-uuid-canary");
        let parsed: serde_json::Value = serde_json::from_str(&body).unwrap();

        assert_eq!(parsed["code"], "poll-code-canary");
        assert_eq!(parsed["id"], "123456789");
        assert_eq!(parsed["uuid"], "device-uuid-canary");
        assert_eq!(parsed.as_object().unwrap().len(), 3);
    }

    #[test]
    fn test_oidc_cancel_clears_code_url_and_auth_body() {
        OidcSession::auth_cancel();
        let res = OidcSession::get_result();
        assert_eq!(res.url, None);
        assert!(res.auth_body.is_none());
        assert_eq!(res.failed_msg, "cancelled");
    }

    #[test]
    fn test_oidc_generation_increments_monotonically_on_auth() {
        let gen1 = OidcSession::current_generation();
        // Invoke auth with dummy unroutable endpoint; worker starts with bounded timeout
        OidcSession::account_auth(
            "http://127.0.0.1:9".to_string(),
            "oidc".to_string(),
            "test_id".to_string(),
            "test_uuid".to_string(),
            false,
        );
        let gen2 = OidcSession::current_generation();
        assert!(gen2 > gen1, "Generation must increase on account_auth");
        // Immediate cancel resets url and stops querying
        OidcSession::auth_cancel();
        let res = OidcSession::get_result();
        assert_eq!(res.url, None);
    }
}
