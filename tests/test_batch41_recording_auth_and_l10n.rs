// Client Batch 41 Hardening Tests (FEEDBACK-003, AUTH-008, L10N-001, L10N-002)

#![cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    feature = "flutter"
))]

use camellia_remote::lang::translate_locale;
use camellia_remote_protocol::bytes::Bytes;
use camellia_remote_protocol::config::{Config, TrustedDevice};
use scrap::record::{create_record_channel, RecordState};
use std::sync::Mutex;

static BATCH41_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_batch41_test_lock() -> std::sync::MutexGuard<'static, ()> {
    BATCH41_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner())
}

#[test]
fn test_feedback003_record_channel_error_propagation() {
    let _lock = acquire_batch41_test_lock();
    let (tx, rx) = create_record_channel();

    let err_msg = "disk write error: no space left on device";
    tx.send(RecordState::Failed(err_msg.to_string()))
        .expect("Failed to send record failed state");

    match rx.try_recv() {
        Ok(RecordState::Failed(msg)) => {
            assert_eq!(msg, err_msg);
        }
        other => panic!("Expected RecordState::Failed, got {other:?}"),
    }
}

#[test]
fn test_auth008_atomic_2fa_and_trusted_device_revocation() {
    let _lock = acquire_batch41_test_lock();

    Config::clear_trusted_devices();
    assert!(Config::get_trusted_devices().is_empty());

    let dev = TrustedDevice {
        device_id: "test-controller-auth-008".to_string(),
        public_key: Bytes::from_static(&[0x22; 32]),
        public_key_fingerprint: "fp-auth008".to_string(),
        name: "Test Auth008 Controller".to_string(),
        platform: "linux".to_string(),
        created_at: camellia_remote_protocol::get_time(),
        last_used_at: camellia_remote_protocol::get_time(),
        hwid: Bytes::new(),
    };

    Config::set_option("2fa".to_owned(), "secret-totp-123".to_owned());
    Config::set_option("bot".to_owned(), "telegram-bot-token-456".to_owned());
    assert!(Config::add_trusted_device(dev).is_ok());

    assert_eq!(Config::get_option("2fa"), "secret-totp-123");
    assert_eq!(Config::get_option("bot"), "telegram-bot-token-456");
    assert_eq!(Config::get_trusted_devices().len(), 1);

    // Atomically revoke
    assert!(Config::try_disable_2fa_and_clear_trusted_devices().is_ok());

    assert_eq!(Config::get_option("2fa"), "");
    assert_eq!(Config::get_option("bot"), "");
    assert!(Config::get_trusted_devices().is_empty());
}

#[test]
fn test_l10n001_and_l10n002_script_priority_and_catalog() {
    let _lock = acquire_batch41_test_lock();

    // 1. New keys in cn, tw, and en
    assert_eq!(
        translate_locale("Recording failed".to_string(), "zh-cn"),
        "录屏失败"
    );
    assert_eq!(
        translate_locale("Recording failed".to_string(), "zh-tw"),
        "錄影失敗"
    );
    assert_eq!(
        translate_locale("Account disabled".to_string(), "zh-cn"),
        "账户已禁用"
    );
    assert_eq!(
        translate_locale("Account disabled".to_string(), "zh-tw"),
        "帳戶已停用"
    );

    // 2. Dynamic placeholder substitution
    assert_eq!(
        translate_locale("length>={12}".to_string(), "zh-cn"),
        "长度不小于 12"
    );
    assert_eq!(
        translate_locale("length>={12}".to_string(), "zh-tw"),
        "長度大於或等於 12"
    );
    assert_eq!(
        translate_locale("Continue with {Google}".to_string(), "zh-cn"),
        "使用 Google 登录"
    );

    // 3. Documentation URL branding checks
    let mac_url = translate_locale("doc_mac_permission".to_string(), "en");
    assert!(
        mac_url.contains("camellia-nexus/remote-client"),
        "doc_mac_permission must point to camellia-nexus/remote-client: {mac_url}"
    );
    assert!(
        !mac_url.contains("camellia-computing"),
        "doc_mac_permission must not contain camellia-computing"
    );

    let wayland_url = translate_locale("doc_fix_wayland".to_string(), "en");
    assert!(
        wayland_url.contains("camellia-nexus/remote-client"),
        "doc_fix_wayland must point to camellia-nexus/remote-client: {wayland_url}"
    );

    // 4. Script locale priority: script takes precedence over country code
    let cn_status = translate_locale("Status".to_string(), "zh-cn");
    let tw_status = translate_locale("Status".to_string(), "zh-tw");
    assert_ne!(cn_status, tw_status);

    // zh-Hans-TW has script Hans with country TW -> should resolve to zh-cn
    assert_eq!(
        translate_locale("Status".to_string(), "zh-Hans-TW"),
        cn_status
    );
    // zh-Hant-CN has script Hant with country CN -> should resolve to zh-tw
    assert_eq!(
        translate_locale("Status".to_string(), "zh-Hant-CN"),
        tw_status
    );
}
