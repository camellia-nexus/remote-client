use camellia_remote_protocol::ResultType;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{Map, Value};

#[cfg(feature = "flutter")]
pub mod account;
mod dns;
mod http_client;
pub mod record_upload;
pub mod sync;
pub(crate) use dns::resolve_endpoint;
pub(crate) use http_client::{
    create_http_client_async_for_configuration, create_http_client_for_configuration,
};

pub const MANAGEMENT_RESPONSE_SCHEMA_VERSION: u64 = 1;

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct HbbHttpError {
    pub response_schema_version: u64,
    pub code: String,
    pub message: String,
    pub retryable: bool,
    #[serde(default)]
    pub pending: bool,
}

impl std::fmt::Display for HbbHttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

#[derive(Debug)]
pub enum HbbHttpResponse<T> {
    ErrorFormat,
    Error(HbbHttpError),
    Pending(HbbHttpError),
    DataTypeFormat,
    Data(T),
}

impl<T: DeserializeOwned> HbbHttpResponse<T> {
    pub fn parse(body: &str) -> ResultType<Self> {
        let map = serde_json::from_str::<Map<String, Value>>(body)?;
        if map.get("response_schema_version").and_then(Value::as_u64)
            != Some(MANAGEMENT_RESPONSE_SCHEMA_VERSION)
        {
            return Ok(Self::ErrorFormat);
        }
        let has_error_signature = map.contains_key("retryable")
            || (map.contains_key("code") && map.contains_key("message"));
        if has_error_signature {
            let error = match serde_json::from_value::<HbbHttpError>(Value::Object(map)) {
                Ok(error)
                    if valid_machine_code(&error.code)
                        && !error.message.is_empty()
                        && error.message.chars().count() <= 256 =>
                {
                    error
                }
                _ => return Ok(Self::ErrorFormat),
            };
            if error.pending {
                if error.retryable {
                    return Ok(Self::Pending(error));
                }
                return Ok(Self::ErrorFormat);
            }
            return Ok(Self::Error(error));
        }
        match serde_json::from_value(Value::Object(map)) {
            Ok(v) => Ok(Self::Data(v)),
            Err(_) => Ok(Self::DataTypeFormat),
        }
    }
}

fn valid_machine_code(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Debug, Deserialize, PartialEq, Eq)]
    struct Fixture {
        value: u8,
    }

    #[derive(Debug, Deserialize, PartialEq, Eq)]
    struct SuccessWithCode {
        code: String,
        url: String,
    }

    #[test]
    fn response_parser_requires_v1_and_uses_machine_pending_state() {
        assert!(matches!(
            HbbHttpResponse::<Fixture>::parse(r#"{"response_schema_version":1,"value":7}"#)
                .unwrap(),
            HbbHttpResponse::Data(Fixture { value: 7 })
        ));
        assert!(matches!(
            HbbHttpResponse::<Fixture>::parse(
                r#"{"response_schema_version":1,"code":"oidc_pending","message":"localized text","retryable":true,"pending":true}"#
            )
            .unwrap(),
            HbbHttpResponse::Pending(HbbHttpError { code, .. }) if code == "oidc_pending"
        ));
        assert!(matches!(
            HbbHttpResponse::<Fixture>::parse(r#"{"error":"No authed oidc is found"}"#).unwrap(),
            HbbHttpResponse::ErrorFormat
        ));
        assert!(matches!(
            HbbHttpResponse::<SuccessWithCode>::parse(
                r#"{"response_schema_version":1,"code":"poll-code","url":"https://example.invalid/auth"}"#
            )
            .unwrap(),
            HbbHttpResponse::Data(SuccessWithCode { code, .. }) if code == "poll-code"
        ));
    }
}
