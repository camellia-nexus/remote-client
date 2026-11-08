#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::clipboard::{update_clipboard, ClipboardSide};
use camellia_remote_protocol::{log, message_proto::*, ResultType};
use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

pub const MAX_SCREENSHOT_BYTES: usize = 32 * 1024 * 1024; // 32 MiB
pub const MAX_CACHED_SESSIONS: usize = 32;
pub const SCREENSHOT_TTL: Duration = Duration::from_secs(300); // 5 minutes

#[derive(Clone)]
struct CachedScreenshot {
    data: bytes::Bytes,
    created_at: Instant,
}

#[derive(Default)]
pub struct ScreenshotStore {
    sessions: HashMap<String, CachedScreenshot>,
    last_session_id: String,
}

impl ScreenshotStore {
    fn clean_expired(&mut self) {
        let now = Instant::now();
        self.sessions
            .retain(|_, v| now.duration_since(v.created_at) < SCREENSHOT_TTL);
    }

    pub fn set_session_screenshot(&mut self, session_id: &str, data: bytes::Bytes) {
        if data.len() > MAX_SCREENSHOT_BYTES {
            log::warn!(
                "Rejecting screenshot for session {}: size {} exceeds max {}",
                session_id,
                data.len(),
                MAX_SCREENSHOT_BYTES
            );
            return;
        }
        self.clean_expired();
        if self.sessions.len() >= MAX_CACHED_SESSIONS {
            if let Some(oldest_key) = self
                .sessions
                .iter()
                .min_by_key(|(_, v)| v.created_at)
                .map(|(k, _)| k.clone())
            {
                self.sessions.remove(&oldest_key);
            }
        }
        let sid = session_id.to_string();
        self.sessions.insert(
            sid.clone(),
            CachedScreenshot {
                data,
                created_at: Instant::now(),
            },
        );
        self.last_session_id = sid;
    }

    pub fn handle_session_screenshot(&mut self, session_id: &str, action: String) -> String {
        self.clean_expired();
        let cached = if !session_id.is_empty() {
            self.sessions.remove(session_id)
        } else {
            if let Some(c) = self.sessions.remove(&self.last_session_id) {
                Some(c)
            } else if let Some(key) = self.sessions.keys().next().cloned() {
                self.sessions.remove(&key)
            } else {
                None
            }
        };

        let Some(cached) = cached else {
            return "No cached screenshot".to_owned();
        };

        match handle_screenshot_action(cached.data, action) {
            Ok(()) => "".to_owned(),
            Err(e) => e.to_string(),
        }
    }

    pub fn clear_session_screenshot(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }
}

lazy_static::lazy_static! {
    static ref SCREENSHOT_STORE: Mutex<ScreenshotStore> = Default::default();
}

pub enum ScreenshotAction {
    SaveAs(String),
    CopyToClipboard,
    Discard,
}

impl Default for ScreenshotAction {
    fn default() -> Self {
        Self::Discard
    }
}

impl From<&str> for ScreenshotAction {
    fn from(value: &str) -> Self {
        match value.chars().next() {
            Some('0') => {
                if let Some((pos, _)) = value.char_indices().nth(2) {
                    let substring = &value[pos..];
                    Self::SaveAs(substring.to_string())
                } else {
                    Self::default()
                }
            }
            Some('1') => Self::CopyToClipboard,
            Some('2') => Self::default(),
            _ => Self::default(),
        }
    }
}

impl Into<String> for ScreenshotAction {
    fn into(self) -> String {
        match self {
            Self::SaveAs(p) => format!("0:{p}"),
            Self::CopyToClipboard => "1".to_owned(),
            Self::Discard => "2".to_owned(),
        }
    }
}

fn handle_screenshot_action(data: bytes::Bytes, action: String) -> ResultType<()> {
    match ScreenshotAction::from(&action as &str) {
        ScreenshotAction::SaveAs(p) => {
            std::fs::write(p, data)?;
        }
        ScreenshotAction::CopyToClipboard => {
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            {
                let clips = vec![Clipboard {
                    compress: false,
                    content: data,
                    format: ClipboardFormat::ImagePng.into(),
                    ..Default::default()
                }];
                update_clipboard(clips, ClipboardSide::Client);
            }
        }
        ScreenshotAction::Discard => {}
    }
    Ok(())
}

pub fn set_session_screenshot(session_id: &str, data: bytes::Bytes) {
    SCREENSHOT_STORE
        .lock()
        .unwrap()
        .set_session_screenshot(session_id, data);
}

pub fn handle_session_screenshot(session_id: &str, action: String) -> String {
    SCREENSHOT_STORE
        .lock()
        .unwrap()
        .handle_session_screenshot(session_id, action)
}

pub fn clear_session_screenshot(session_id: &str) {
    SCREENSHOT_STORE
        .lock()
        .unwrap()
        .clear_session_screenshot(session_id);
}

pub fn set_screenshot(data: bytes::Bytes) {
    set_session_screenshot("", data);
}

pub fn handle_screenshot(action: String) -> String {
    handle_session_screenshot("", action)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_screenshot_session_isolation_state_025() {
        let sid1 = "session-state025-1";
        let sid2 = "session-state025-2";

        let data1 = bytes::Bytes::from_static(b"PNG_DATA_1");
        let data2 = bytes::Bytes::from_static(b"PNG_DATA_2");

        set_session_screenshot(sid1, data1);
        set_session_screenshot(sid2, data2);

        // Session 1 consumes Discard action
        let res1 = handle_session_screenshot(sid1, "2".to_string());
        assert_eq!(res1, "");

        // Session 1 is now empty
        let res1_again = handle_session_screenshot(sid1, "2".to_string());
        assert_eq!(res1_again, "No cached screenshot");

        // Session 2 is still intact and not corrupted or deleted by session 1
        let res2 = handle_session_screenshot(sid2, "2".to_string());
        assert_eq!(res2, "");

        // Session 2 is now empty
        let res2_again = handle_session_screenshot(sid2, "2".to_string());
        assert_eq!(res2_again, "No cached screenshot");
    }

    #[test]
    fn test_screenshot_store_oversized_rejection() {
        let sid = "session-oversized";
        let mut store = ScreenshotStore::default();
        let big_data = bytes::Bytes::from(vec![0u8; MAX_SCREENSHOT_BYTES + 1]);

        store.set_session_screenshot(sid, big_data);
        assert_eq!(
            store.handle_session_screenshot(sid, "2".to_string()),
            "No cached screenshot"
        );
    }
}
