use camellia_remote::common::post_request_sync;
use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Barrier,
    },
    thread,
};
use url::Url;

// Replicate sanitize_url_path_for_log and tcp_proxy_log_target as in src/common.rs
// to test them under adversarial, complex, and malformed inputs
fn sanitize_url_path_for_log(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for segment in path.split('/') {
        if segment.starts_with("bot") && segment.len() > 3 {
            parts.push("bot<redacted>");
        } else {
            parts.push(segment);
        }
    }
    parts.join("/")
}

fn tcp_proxy_log_target(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .map(|parsed| {
            let mut redacted = format!("{}://", parsed.scheme());
            let Some(host) = parsed.host() else {
                return "<invalid-url>".to_owned();
            };
            redacted.push_str(&host.to_string());
            if let Some(port) = parsed.port() {
                redacted.push(':');
                redacted.push_str(&port.to_string());
            }
            let sanitized_path = sanitize_url_path_for_log(parsed.path());
            redacted.push_str(&sanitized_path);
            redacted
        })
        .unwrap_or_else(|| "<invalid-url>".to_owned())
}

// TelegramBot struct and Debug / Display implementations matching src/auth_2fa.rs
#[derive(Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct TelegramBot {
    #[serde(skip)]
    pub token_str: String,
    pub token: Vec<u8>,
    pub chat_id: String,
}

impl std::fmt::Debug for TelegramBot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TelegramBot")
            .field(
                "token_str",
                &if self.token_str.is_empty() {
                    "<empty>"
                } else {
                    "<redacted>"
                },
            )
            .field(
                "token",
                &if self.token.is_empty() {
                    "<empty>"
                } else {
                    "<redacted>"
                },
            )
            .field("chat_id", &self.chat_id)
            .finish()
    }
}

impl std::fmt::Display for TelegramBot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TelegramBot(chat_id: {})", self.chat_id)
    }
}

// OidcAuthUrl struct and Debug implementation matching src/hbbs_http/account.rs
#[derive(serde::Deserialize, Clone)]
pub struct OidcAuthUrl {
    pub code: String,
    pub url: Url,
}

impl std::fmt::Debug for OidcAuthUrl {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut sanitized_url = format!("{}://", self.url.scheme());
        if let Some(host) = self.url.host_str() {
            sanitized_url.push_str(host);
        }
        if let Some(port) = self.url.port() {
            sanitized_url.push(':');
            sanitized_url.push_str(&port.to_string());
        }
        sanitized_url.push_str(self.url.path());
        if self.url.query().is_some() {
            sanitized_url.push_str("?<redacted>");
        }

        f.debug_struct("OidcAuthUrl")
            .field(
                "code",
                &if self.code.is_empty() {
                    "<empty>"
                } else {
                    "<redacted>"
                },
            )
            .field("url", &sanitized_url)
            .finish()
    }
}

// =====================================================================
// Challenge 1: URL Path Sanitization & Error URL Stripping (LOG-004)
// =====================================================================

#[test]
fn test_challenge_url_path_sanitization_adversarial_matrix() {
    let test_cases = vec![
        // Standard Telegram bot URL
        (
            "https://api.telegram.org/bot123456789:CANARY_SECRET_TOKEN_STD/sendMessage",
            "CANARY_SECRET_TOKEN_STD",
            "https://api.telegram.org/bot<redacted>/sendMessage",
        ),
        // Deeply nested path
        (
            "https://api.telegram.org/v1/internal/proxy/bot987654321:CANARY_SECRET_TOKEN_NESTED/action/subaction",
            "CANARY_SECRET_TOKEN_NESTED",
            "https://api.telegram.org/v1/internal/proxy/bot<redacted>/action/subaction",
        ),
        // Multiple bot segments
        (
            "https://api.telegram.org/botCANARY_BOT_SEG_1/middle/botCANARY_BOT_SEG_2/end",
            "CANARY_BOT_SEG_1",
            "https://api.telegram.org/bot<redacted>/middle/bot<redacted>/end",
        ),
        // Double and trailing slashes
        (
            "https://api.telegram.org//botCANARY_SLASH_TRICK///finish",
            "CANARY_SLASH_TRICK",
            "https://api.telegram.org//bot<redacted>///finish",
        ),
        // URL with query parameters (query params must be stripped completely)
        (
            "https://api.telegram.org/botCANARY_TOKEN_QUERY/sendMessage?param=CANARY_QUERY_SECRET&code=CANARY_CODE",
            "CANARY_QUERY_SECRET",
            "https://api.telegram.org/bot<redacted>/sendMessage",
        ),
        // URL with fragment
        (
            "https://api.telegram.org/botCANARY_TOKEN_FRAG/sendMessage#access_token=CANARY_FRAG_SECRET",
            "CANARY_FRAG_SECRET",
            "https://api.telegram.org/bot<redacted>/sendMessage",
        ),
        // URL with userinfo credentials
        (
            "https://CANARY_USER:CANARY_PASS@api.telegram.org/botCANARY_TOKEN_USERINFO/sendMessage",
            "CANARY_PASS",
            "https://api.telegram.org/bot<redacted>/sendMessage",
        ),
        // Custom port and IPv6 host
        (
            "https://[2001:db8::1]:8443/botCANARY_TOKEN_IPV6/sendMessage",
            "CANARY_TOKEN_IPV6",
            "https://[2001:db8::1]:8443/bot<redacted>/sendMessage",
        ),
        // Localhost with port
        (
            "http://127.0.0.1:9090/botCANARY_TOKEN_LOCAL/cmd",
            "CANARY_TOKEN_LOCAL",
            "http://127.0.0.1:9090/bot<redacted>/cmd",
        ),
        // Segment length boundary: segment == "bot" (len 3, not > 3)
        (
            "https://api.telegram.org/bot/test",
            "NON_EXISTENT_CANARY",
            "https://api.telegram.org/bot/test",
        ),
        // Segment length boundary: segment == "bot1" (len 4, > 3)
        (
            "https://api.telegram.org/botCANARY_FOUR/test",
            "CANARY_FOUR",
            "https://api.telegram.org/bot<redacted>/test",
        ),
    ];

    for (url, canary, expected_redacted) in test_cases {
        let result = tcp_proxy_log_target(url);
        assert!(
            !result.contains(canary),
            "Canary string '{}' leaked in tcp_proxy_log_target! Output: {}",
            canary,
            result
        );
        assert_eq!(
            result, expected_redacted,
            "Mismatch in expected redacted output for URL: {}",
            url
        );
    }

    // Malformed URLs must evaluate to <invalid-url> without leaking
    let malformed_cases = vec![
        "not_a_valid_url_at_all_CANARY_MALFORMED_1",
        "https://",
        "file:///botCANARY_MALFORMED_2/test",
        "htt p://spaces in url CANARY_MALFORMED_3",
        "://missing_scheme_CANARY_MALFORMED_4",
        "https://api.telegram.org:not_a_port/botCANARY_MALFORMED_5",
    ];

    for malformed in malformed_cases {
        let result = tcp_proxy_log_target(malformed);
        assert!(
            !result.contains("CANARY_MALFORMED"),
            "Canary leaked from malformed URL '{}'! Output: {}",
            malformed,
            result
        );
        assert_eq!(result, "<invalid-url>");
    }
}

#[test]
fn test_challenge_reqwest_error_without_url_strips_canary() {
    let client = reqwest::blocking::Client::builder().build().unwrap();

    // 1. Connection Refused Scenario
    let canary_token = "CANARY_TOKEN_CONN_REFUSED_123456789";
    let url_refused = format!("http://127.0.0.1:1/bot{}/sendMessage", canary_token);

    let raw_err = client.post(&url_refused).body("test").send().unwrap_err();

    // Verify the raw error originally DOES leak the canary URL
    let raw_debug = format!("{:?}", raw_err);
    assert!(
        raw_debug.contains(canary_token),
        "Sanity check: raw reqwest::Error should contain canary URL"
    );

    // Apply without_url() as required by LOG-004
    let stripped = raw_err.without_url();
    let debug_output = format!("{:?}", stripped);
    let display_output = format!("{}", stripped);

    assert!(
        !debug_output.contains(canary_token),
        "Canary leaked in Debug output of without_url(): {}",
        debug_output
    );
    assert!(
        !display_output.contains(canary_token),
        "Canary leaked in Display output of without_url(): {}",
        display_output
    );

    // 2. DNS Resolution Failure Scenario
    let dns_canary = "CANARY_TOKEN_DNS_FAIL_987654321";
    let url_dns = format!(
        "http://nonexistent-domain-for-testing-canary-{}.test/bot{}/sendMessage",
        dns_canary, dns_canary
    );

    let dns_raw_err = client.post(&url_dns).body("test").send().unwrap_err();

    let dns_stripped = dns_raw_err.without_url();
    let dns_debug = format!("{:?}", dns_stripped);
    let dns_display = format!("{}", dns_stripped);

    assert!(
        !dns_debug.contains(dns_canary),
        "DNS canary leaked in Debug: {}",
        dns_debug
    );
    assert!(
        !dns_display.contains(dns_canary),
        "DNS canary leaked in Display: {}",
        dns_display
    );
}

#[test]
fn test_challenge_post_request_error_does_not_leak_telegram_bot_token() {
    let canary_token = "CANARY_BOT_TOKEN_VIA_POST_REQUEST_99999";
    // Connect to an unroutable blackhole or non-listening port
    let url = format!("http://127.0.0.1:1/bot{}/sendMessage", canary_token);

    let res = post_request_sync(url, "{}".to_string(), "");
    assert!(res.is_err(), "Expected connection refused error");

    let err = res.unwrap_err();
    let err_str = err.to_string();
    let err_debug = format!("{:?}", err);

    assert!(
        !err_str.contains(canary_token),
        "Canary token leaked in post_request error string: {}",
        err_str
    );
    assert!(
        !err_debug.contains(canary_token),
        "Canary token leaked in post_request error debug: {}",
        err_debug
    );
}

// =====================================================================
// Challenge 2: TelegramBot and OidcAuthUrl Custom Debug (LOG-004 & LOG-005)
// =====================================================================

#[test]
fn test_challenge_telegram_bot_custom_debug_and_display() {
    let bot = TelegramBot {
        token_str: "CANARY_TG_TOKEN_PLAINTEXT_SECRET_123".to_string(),
        token: vec![10, 20, 30, 40, 50],
        chat_id: "CANARY_TG_CHAT_ID_456".to_string(),
    };

    let debug_compact = format!("{:?}", bot);
    let debug_pretty = format!("{:#?}", bot);
    let display = format!("{}", bot);

    // Plaintext token_str must never appear
    assert!(!debug_compact.contains("CANARY_TG_TOKEN_PLAINTEXT_SECRET_123"));
    assert!(!debug_pretty.contains("CANARY_TG_TOKEN_PLAINTEXT_SECRET_123"));
    assert!(!display.contains("CANARY_TG_TOKEN_PLAINTEXT_SECRET_123"));

    // Raw byte tokens must never appear
    assert!(!debug_compact.contains("[10, 20, 30, 40, 50]"));
    assert!(!debug_pretty.contains("[10, 20, 30, 40, 50]"));
    assert!(!display.contains("[10, 20, 30, 40, 50]"));

    // Expected redaction indicator
    assert!(debug_compact.contains("<redacted>"));
    assert!(debug_pretty.contains("<redacted>"));

    // Chat ID is safe to display for diagnostics
    assert!(debug_compact.contains("CANARY_TG_CHAT_ID_456"));
    assert!(display.contains("CANARY_TG_CHAT_ID_456"));

    // Test empty tokens
    let empty_bot = TelegramBot {
        token_str: "".to_string(),
        token: vec![],
        chat_id: "chat_000".to_string(),
    };
    let empty_debug = format!("{:?}", empty_bot);
    assert!(empty_debug.contains("<empty>"));
    assert!(!empty_debug.contains("<redacted>"));

    // Test JSON serialization: token_str has #[serde(skip)]
    let serialized = serde_json::to_string(&bot).unwrap();
    assert!(
        !serialized.contains("CANARY_TG_TOKEN_PLAINTEXT_SECRET_123"),
        "token_str must be skipped in JSON serialization: {}",
        serialized
    );
}

#[test]
fn test_challenge_oidc_auth_url_custom_debug() {
    let canary_code = "CANARY_OIDC_AUTHORIZATION_CODE_POLL_777";
    let canary_state = "CANARY_STATE_PARAMETER_SECRET_888";
    let canary_secret_query = "CANARY_QUERY_SECRET_TOKEN_999";

    let url_str = format!(
        "https://idp.example.com/oauth/authorize?client_id=myclient&state={}&secret={}",
        canary_state, canary_secret_query
    );

    let auth_url = OidcAuthUrl {
        code: canary_code.to_string(),
        url: Url::parse(&url_str).unwrap(),
    };

    let debug_compact = format!("{:?}", auth_url);
    let debug_pretty = format!("{:#?}", auth_url);

    // Code must be redacted
    assert!(
        !debug_compact.contains(canary_code),
        "OIDC polling code leaked in Debug: {}",
        debug_compact
    );
    assert!(
        !debug_pretty.contains(canary_code),
        "OIDC polling code leaked in Pretty Debug: {}",
        debug_pretty
    );

    // Query parameters must be stripped and replaced with ?<redacted>
    assert!(
        !debug_compact.contains(canary_state),
        "OIDC state leaked in Debug: {}",
        debug_compact
    );
    assert!(
        !debug_compact.contains(canary_secret_query),
        "OIDC query parameter leaked in Debug: {}",
        debug_compact
    );
    assert!(
        debug_compact.contains("https://idp.example.com/oauth/authorize?<redacted>"),
        "Query string not properly replaced with ?<redacted>: {}",
        debug_compact
    );

    // Test empty code
    let empty_auth_url = OidcAuthUrl {
        code: "".to_string(),
        url: Url::parse("https://idp.example.com/oauth/authorize").unwrap(),
    };
    let empty_debug = format!("{:?}", empty_auth_url);
    assert!(empty_debug.contains("<empty>"));
    assert_eq!(
        empty_debug,
        "OidcAuthUrl { code: \"<empty>\", url: \"https://idp.example.com/oauth/authorize\" }"
    );
}

#[test]
fn test_stress_telegram_bot_debug_50_threads() {
    let barrier = Arc::new(Barrier::new(50));
    let errors = Arc::new(AtomicUsize::new(0));
    let mut handles = Vec::with_capacity(50);

    for thread_idx in 0..50 {
        let b = Arc::clone(&barrier);
        let err_count = Arc::clone(&errors);

        handles.push(thread::spawn(move || {
            b.wait();

            for iter in 0..100 {
                let canary_token = format!("CANARY_TG_TH_{thread_idx}_ITER_{iter}");
                let bot = TelegramBot {
                    token_str: canary_token.clone(),
                    token: canary_token.as_bytes().to_vec(),
                    chat_id: format!("chat_{thread_idx}"),
                };

                let debug = format!("{:?}", bot);
                let display = format!("{}", bot);

                if debug.contains(&canary_token) || display.contains(&canary_token) {
                    err_count.fetch_add(1, Ordering::SeqCst);
                }
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(
        errors.load(Ordering::SeqCst),
        0,
        "Concurrent TelegramBot debug leaks detected!"
    );
}

#[test]
fn test_stress_oidc_auth_url_debug_50_threads() {
    let barrier = Arc::new(Barrier::new(50));
    let errors = Arc::new(AtomicUsize::new(0));
    let mut handles = Vec::with_capacity(50);

    for thread_idx in 0..50 {
        let b = Arc::clone(&barrier);
        let err_count = Arc::clone(&errors);

        handles.push(thread::spawn(move || {
            b.wait();

            for iter in 0..100 {
                let canary_code = format!("CANARY_OIDC_CODE_TH_{thread_idx}_ITER_{iter}");
                let canary_state = format!("CANARY_STATE_TH_{thread_idx}_ITER_{iter}");
                let url = Url::parse(&format!(
                    "https://idp.example.com/auth?code={canary_code}&state={canary_state}"
                ))
                .unwrap();

                let auth_url = OidcAuthUrl {
                    code: canary_code.clone(),
                    url,
                };

                let debug = format!("{:?}", auth_url);

                if debug.contains(&canary_code) || debug.contains(&canary_state) {
                    err_count.fetch_add(1, Ordering::SeqCst);
                }
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(
        errors.load(Ordering::SeqCst),
        0,
        "Concurrent OidcAuthUrl debug leaks detected!"
    );
}
