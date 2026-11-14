use std::ops::Deref;

mod cn;
mod en;
mod tw;

pub const LANGS: &[(&str, &str)] = &[
    ("en", "English"),
    ("zh-cn", "简体中文"),
    ("zh-tw", "繁體中文"),
];

fn canonical_lang(lang_or_locale: &str) -> &'static str {
    let normalized = lang_or_locale.trim().to_lowercase().replace('_', "-");
    if !normalized.starts_with("zh") {
        return "en";
    }
    if normalized.contains("hans") {
        "zh-cn"
    } else if normalized.contains("hant")
        || normalized.contains("-tw")
        || normalized.contains("-hk")
        || normalized.contains("-mo")
    {
        "zh-tw"
    } else {
        "zh-cn"
    }
}

fn resolve_lang(saved_lang: &str, locale: &str) -> String {
    let saved = saved_lang.trim();
    let source = if saved.is_empty() || saved.eq_ignore_ascii_case("default") {
        locale
    } else {
        saved
    };
    canonical_lang(source).to_owned()
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn translate(name: String) -> String {
    let locale = sys_locale::get_locale().unwrap_or_default();
    translate_locale(name, &locale)
}

pub fn translate_locale(name: String, locale: &str) -> String {
    let lang = resolve_lang(
        &camellia_remote_protocol::config::LocalConfig::get_option("lang"),
        locale,
    );
    let m = match lang.as_str() {
        "zh-cn" => cn::T.deref(),
        "zh-tw" => tw::T.deref(),
        _ => en::T.deref(),
    };
    let (name, placeholder_value) = extract_placeholder(&name);
    let replace = |s: &&str| {
        let mut s = s.to_string();
        if let Some(value) = placeholder_value.as_ref() {
            s = s.replace("{}", &value);
        }
        if s.contains("RustDesk")
            && !name.starts_with("upgrade_rustdesk_server_pro")
            && name != "powered_by_me"
        {
            s = s.replace("RustDesk", &crate::get_app_name());
        }
        s
    };
    if let Some(v) = m.get(&name as &str) {
        if !v.is_empty() {
            return replace(v);
        }
    }
    if lang != "en" {
        if let Some(v) = en::T.get(&name as &str) {
            if !v.is_empty() {
                return replace(v);
            }
        }
    }
    replace(&name.as_str())
}

// Matching pattern is {}
// Write {value} in the UI and {} in the translation file
//
// Example:
// Write in the UI: translate("There are {24} hours in a day")
// Write in the translation file: ("There are {} hours in a day", "{} hours make up a day")
// Linear, zero-regex placeholder extraction (PERF-005)
fn extract_placeholder(input: &str) -> (String, Option<String>) {
    if let Some(start) = input.find('{') {
        if let Some(rel_end) = input[start + 1..].find('}') {
            let end = start + 1 + rel_end;
            let value = &input[start + 1..end];
            let mut name = String::with_capacity(input.len() + 2 - (end - start + 1));
            name.push_str(&input[..start]);
            name.push_str("{}");
            name.push_str(&input[end + 1..]);
            return (name, Some(value.to_string()));
        }
    }
    (input.to_string(), None)
}

mod test {
    #[test]
    fn test_extract_placeholders() {
        use super::extract_placeholder as f;

        assert_eq!(f(""), ("".to_string(), None));
        assert_eq!(
            f("{3} sessions"),
            ("{} sessions".to_string(), Some("3".to_string()))
        );
        assert_eq!(f(" } { "), (" } { ".to_string(), None));
        // Allow empty value
        assert_eq!(
            f("{} sessions"),
            ("{} sessions".to_string(), Some("".to_string()))
        );
        // Match only the first one
        assert_eq!(
            f("{2} times {4} makes {8}"),
            ("{} times {4} makes {8}".to_string(), Some("2".to_string()))
        );
    }

    #[test]
    fn test_resolve_lang_respects_explicit_supported_language() {
        use super::resolve_lang as f;

        assert_eq!(f("en", "zh-TW"), "en");
        assert_eq!(f("zh-cn", "en-US"), "zh-cn");
        assert_eq!(f("zh-tw", "en-US"), "zh-tw");
    }

    #[test]
    fn test_resolve_lang_follows_system_for_default() {
        use super::resolve_lang as f;

        assert_eq!(f("", "zh_CN"), "zh-cn");
        assert_eq!(f("default", "zh-Hant-HK"), "zh-tw");
        assert_eq!(f("DEFAULT", "zh_MO"), "zh-tw");
        assert_eq!(f("", "ja-JP"), "en");
    }

    #[test]
    fn test_resolve_lang_normalizes_regions_and_scripts() {
        use super::resolve_lang as f;

        assert_eq!(f("zh-Hans-SG", "en-US"), "zh-cn");
        assert_eq!(f("zh-Hant", "en-US"), "zh-tw");
        assert_eq!(f("zh-HK", "en-US"), "zh-tw");
        assert_eq!(f("fr", "zh-TW"), "en");
    }
}
