// Auto-generated build-time constants.
// Values are injected by build.rs via `cargo:rustc-env` with reproducible UTC fallbacks.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[allow(dead_code)]
pub const BUILD_DATE: &str = match option_env!("CAMELLIA_BUILD_DATE") {
    Some(date) => date,
    None => match option_env!("BUILD_DATE") {
        Some(date) => date,
        None => "1970-01-01 00:00 UTC",
    },
};
