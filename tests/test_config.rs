use camellia_remote::ipc::{
    is_root_owned_option, sanitize_user_config2_for_root, sanitize_user_config_for_root,
};
use camellia_remote_protocol::config::{keys, Config, Config2};

#[test]
fn test_config_is_root_owned_option() {
    // Root-owned options must return true
    assert!(is_root_owned_option(keys::OPTION_CUSTOM_RENDEZVOUS_SERVER));
    assert!(is_root_owned_option(keys::OPTION_RELAY_SERVER));
    assert!(is_root_owned_option(keys::OPTION_KEY));
    assert!(is_root_owned_option(keys::OPTION_API_SERVER));
    assert!(is_root_owned_option(keys::OPTION_ICE_SERVERS));
    assert!(is_root_owned_option(keys::OPTION_ALLOW_WEBSOCKET));
    assert!(is_root_owned_option(keys::OPTION_DISABLE_UDP));
    assert!(is_root_owned_option("proxy-url"));
    assert!(is_root_owned_option("proxy-username"));
    assert!(is_root_owned_option("proxy-password"));
    assert!(is_root_owned_option(keys::OPTION_DEFAULT_CONNECT_PASSWORD));
    assert!(is_root_owned_option(
        keys::OPTION_PRESET_ADDRESS_BOOK_PASSWORD
    ));
    assert!(is_root_owned_option(
        keys::OPTION_DISABLE_CHANGE_PERMANENT_PASSWORD
    ));
    assert!(is_root_owned_option(keys::OPTION_DISABLE_CHANGE_ID));
    assert!(is_root_owned_option(keys::OPTION_DISABLE_UNLOCK_PIN));
    assert!(is_root_owned_option(
        keys::OPTION_ALLOW_COMMAND_LINE_SETTINGS_WHEN_SETTINGS_DISABLED
    ));
    assert!(is_root_owned_option(keys::OPTION_ENABLE_TRUSTED_DEVICES));
    assert!(is_root_owned_option(keys::OPTION_WHITELIST));
    assert!(is_root_owned_option(keys::OPTION_ID_WHITELIST));

    // Regular user-facing options must return false
    assert!(!is_root_owned_option(keys::OPTION_VIEW_STYLE));
    assert!(!is_root_owned_option(keys::OPTION_SCROLL_STYLE));
    assert!(!is_root_owned_option(keys::OPTION_IMAGE_QUALITY));
    assert!(!is_root_owned_option(keys::OPTION_CUSTOM_FPS));
    assert!(!is_root_owned_option(keys::OPTION_THEME));
    assert!(!is_root_owned_option(keys::OPTION_LANGUAGE));
    assert!(!is_root_owned_option("enable-abr"));
}

#[test]
fn test_config_sanitize_user_config2_for_root_preserves_root_security_settings() {
    let mut root_cfg2 = Config2::default();
    root_cfg2.options.insert(
        keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_string(),
        "authoritative-rendezvous.org".to_string(),
    );
    root_cfg2.options.insert(
        keys::OPTION_RELAY_SERVER.to_string(),
        "authoritative-relay.org".to_string(),
    );
    root_cfg2.options.insert(
        keys::OPTION_KEY.to_string(),
        "root-public-key-abcdef".to_string(),
    );
    root_cfg2.options.insert(
        keys::OPTION_API_SERVER.to_string(),
        "https://api.authoritative.org".to_string(),
    );
    root_cfg2.options.insert(
        keys::OPTION_WHITELIST.to_string(),
        "admin-id-1,admin-id-2".to_string(),
    );
    root_cfg2.options.insert(
        keys::OPTION_ID_WHITELIST.to_string(),
        "device-uuid-1".to_string(),
    );
    root_cfg2.options.insert(
        keys::OPTION_ENABLE_TRUSTED_DEVICES.to_string(),
        "Y".to_string(),
    );
    root_cfg2.options.insert(
        keys::OPTION_DEFAULT_CONNECT_PASSWORD.to_string(),
        "root-secret".to_string(),
    );
    root_cfg2
        .options
        .insert(keys::OPTION_THEME.to_string(), "light".to_string());

    // User attempts to clobber root security/network settings and change the theme
    let mut user_cfg2 = Config2::default();
    user_cfg2.options.insert(
        keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_string(),
        "evil-rendezvous.com".to_string(),
    );
    user_cfg2.options.insert(
        keys::OPTION_RELAY_SERVER.to_string(),
        "evil-relay.com".to_string(),
    );
    user_cfg2
        .options
        .insert(keys::OPTION_KEY.to_string(), "evil-key".to_string());
    user_cfg2.options.insert(
        keys::OPTION_API_SERVER.to_string(),
        "https://api.evil.com".to_string(),
    );
    user_cfg2.options.insert(
        keys::OPTION_WHITELIST.to_string(),
        "attacker-id".to_string(),
    );
    user_cfg2.options.insert(
        keys::OPTION_ID_WHITELIST.to_string(),
        "attacker-device".to_string(),
    );
    user_cfg2.options.insert(
        keys::OPTION_ENABLE_TRUSTED_DEVICES.to_string(),
        "N".to_string(),
    );
    user_cfg2.options.insert(
        keys::OPTION_DEFAULT_CONNECT_PASSWORD.to_string(),
        "attacker-pass".to_string(),
    );
    user_cfg2
        .options
        .insert(keys::OPTION_THEME.to_string(), "dark".to_string());
    user_cfg2
        .options
        .insert(keys::OPTION_CUSTOM_FPS.to_string(), "120".to_string());

    let sanitized = sanitize_user_config2_for_root(&user_cfg2, &root_cfg2);

    // All root-owned settings MUST match root_cfg2
    assert_eq!(
        sanitized
            .options
            .get(keys::OPTION_CUSTOM_RENDEZVOUS_SERVER)
            .unwrap(),
        "authoritative-rendezvous.org"
    );
    assert_eq!(
        sanitized.options.get(keys::OPTION_RELAY_SERVER).unwrap(),
        "authoritative-relay.org"
    );
    assert_eq!(
        sanitized.options.get(keys::OPTION_KEY).unwrap(),
        "root-public-key-abcdef"
    );
    assert_eq!(
        sanitized.options.get(keys::OPTION_API_SERVER).unwrap(),
        "https://api.authoritative.org"
    );
    assert_eq!(
        sanitized.options.get(keys::OPTION_WHITELIST).unwrap(),
        "admin-id-1,admin-id-2"
    );
    assert_eq!(
        sanitized.options.get(keys::OPTION_ID_WHITELIST).unwrap(),
        "device-uuid-1"
    );
    assert_eq!(
        sanitized
            .options
            .get(keys::OPTION_ENABLE_TRUSTED_DEVICES)
            .unwrap(),
        "Y"
    );
    assert_eq!(
        sanitized
            .options
            .get(keys::OPTION_DEFAULT_CONNECT_PASSWORD)
            .unwrap(),
        "root-secret"
    );

    // User-permitted options MUST be accepted
    assert_eq!(sanitized.options.get(keys::OPTION_THEME).unwrap(), "dark");
    assert_eq!(
        sanitized.options.get(keys::OPTION_CUSTOM_FPS).unwrap(),
        "120"
    );
}

#[test]
fn test_config_sanitize_user_config2_for_root_blocks_user_injection() {
    let root_cfg2 = Config2::default(); // No root settings configured initially

    // User attempts to inject custom rendezvous server and whitelist into root
    let mut user_cfg2 = Config2::default();
    user_cfg2.options.insert(
        keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_string(),
        "injected-rendezvous.com".to_string(),
    );
    user_cfg2.options.insert(
        keys::OPTION_WHITELIST.to_string(),
        "injected-whitelist".to_string(),
    );
    user_cfg2
        .options
        .insert(keys::OPTION_THEME.to_string(), "nord".to_string());

    let sanitized = sanitize_user_config2_for_root(&user_cfg2, &root_cfg2);

    // Injected root-owned settings must NOT appear
    assert!(!sanitized
        .options
        .contains_key(keys::OPTION_CUSTOM_RENDEZVOUS_SERVER));
    assert!(!sanitized.options.contains_key(keys::OPTION_WHITELIST));

    // Non-root setting is preserved
    assert_eq!(sanitized.options.get(keys::OPTION_THEME).unwrap(), "nord");
}

#[test]
fn test_config_sanitize_user_config_for_root_preserves_root_identity() {
    // Create a mock non-empty root config
    let root_config: Config = serde_json::from_str(
        r#"{
            "id": "root-device-id",
            "enc_id": "root-enc-id",
            "password": "root-hashed-password",
            "salt": "root-salt-value",
            "key_pair": [[1, 2, 3], [4, 5, 6]],
            "key_confirmed": true,
            "keys_confirmed": {}
        }"#,
    )
    .unwrap();

    let user_config: Config = serde_json::from_str(
        r#"{
            "id": "user-clobber-id",
            "enc_id": "user-clobber-enc",
            "password": "user-clobber-password",
            "salt": "user-clobber-salt",
            "key_pair": [[7, 8, 9], [10, 11, 12]],
            "key_confirmed": false,
            "keys_confirmed": {}
        }"#,
    )
    .unwrap();

    let root_config2 = Config2::default();
    let user_config2 = Config2::default();

    let (merged_cfg, _) =
        sanitize_user_config_for_root(&user_config, &user_config2, &root_config, &root_config2);

    // Root Config identity and credentials must be completely untouched
    assert_eq!(merged_cfg.id, "root-device-id");
    assert_eq!(merged_cfg, root_config);
}

#[test]
fn test_config_sanitize_user_config_for_root_seeds_empty_root() {
    let root_config = Config::default(); // empty
    let root_config2 = Config2::default(); // empty

    let user_config: Config = serde_json::from_str(
        r#"{
            "id": "initial-id",
            "enc_id": "initial-enc-id",
            "password": "",
            "salt": "",
            "key_pair": [[1, 2, 3], [4, 5, 6]],
            "key_confirmed": false,
            "keys_confirmed": {}
        }"#,
    )
    .unwrap();

    let mut user_config2 = Config2::default();
    user_config2
        .options
        .insert(keys::OPTION_THEME.to_string(), "dark".to_string());

    let (merged_cfg, merged_cfg2) =
        sanitize_user_config_for_root(&user_config, &user_config2, &root_config, &root_config2);

    // Empty root is bootstrapped by user config
    assert_eq!(merged_cfg.id, "initial-id");
    assert_eq!(merged_cfg2.options.get(keys::OPTION_THEME).unwrap(), "dark");
}

#[test]
fn test_config_import_config_empty_file_returns_error() {
    let dir = std::env::temp_dir().join(format!("test_import_empty_{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let empty_file = dir.join("empty.toml");
    std::fs::write(&empty_file, "").unwrap();

    let result = camellia_remote::core_main::import_config(empty_file.to_str().unwrap());
    assert!(result.is_err(), "Importing empty config must return Err");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn test_config_import_config_nonexistent_file_returns_error() {
    let result = camellia_remote::core_main::import_config("/nonexistent/path/never_existed.toml");
    assert!(
        result.is_err(),
        "Importing nonexistent config must return Err"
    );
}
