#!/usr/bin/env bash
set -euo pipefail

version="${1:?stable MAJOR.MINOR.PATCH version is required}"
build_number="${2:?positive Flutter build number is required}"
source_date_epoch="${3:-${SOURCE_DATE_EPOCH:-}}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "version must be stable SemVer MAJOR.MINOR.PATCH without a v prefix" >&2
  exit 2
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "build number must be a positive decimal integer" >&2
  exit 2
fi
if [[ -n "$source_date_epoch" && ! "$source_date_epoch" =~ ^[0-9]+$ ]]; then
  echo "source date epoch must be a non-negative decimal integer" >&2
  exit 2
fi

if [[ -z "$source_date_epoch" ]]; then
  if git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    source_date_epoch="$(git -C "$repo_root" show -s --format=%ct HEAD 2>/dev/null || true)"
  fi
fi

if [[ -n "$source_date_epoch" && ! "$source_date_epoch" =~ ^[0-9]+$ ]]; then
  echo "source date epoch resolved from git must be a non-negative decimal integer" >&2
  exit 2
fi

cargo_version="$version"
app_version="${version}+${build_number}"
if [[ -n "$source_date_epoch" ]]; then
  build_date="$(
    python3 - "$source_date_epoch" <<'PY'
import datetime
import sys

timestamp = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))
PY
  )"
else
  build_date="$(date -u '+%Y-%m-%d %H:%M UTC')"
fi

if [[ -n "${GITHUB_ENV:-}" && -w "$GITHUB_ENV" ]]; then
  if [[ -n "$source_date_epoch" ]]; then
    echo "SOURCE_DATE_EPOCH=${source_date_epoch}" >> "$GITHUB_ENV"
  fi
  echo "BUILD_DATE=${build_date}" >> "$GITHUB_ENV"
  echo "CAMELLIA_BUILD_DATE=${build_date}" >> "$GITHUB_ENV"
fi

CARGO_VERSION="${cargo_version}" perl -0pi -e 's/^version = "[^"]+"/version = "$ENV{CARGO_VERSION}"/m' Cargo.toml

if [[ -f Cargo.lock ]]; then
  CARGO_VERSION="${cargo_version}" perl -0pi -e 's/(\[\[package\]\]\nname = "camellia-remote"\nversion = ")[^"]+(")/$1$ENV{CARGO_VERSION}$2/' Cargo.lock
fi

APP_VERSION="${app_version}" perl -0pi -e 's/^version:.*/version: $ENV{APP_VERSION}/m' flutter/pubspec.yaml

mkdir -p src
if [[ ! -f src/version.rs ]] || ! grep -q 'option_env!("CAMELLIA_BUILD_DATE")' src/version.rs; then
  cat > src/version.rs <<VERSION_RS
// Auto-generated build-time constants.
// Values are injected by build.rs via \`cargo:rustc-env\` with reproducible UTC fallbacks.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[allow(dead_code)]
pub const BUILD_DATE: &str = match option_env!("CAMELLIA_BUILD_DATE") {
    Some(date) => date,
    None => match option_env!("BUILD_DATE") {
        Some(date) => date,
        None => "1970-01-01 00:00 UTC",
    },
};
VERSION_RS
fi

python3 .github/scripts/release_metadata.py >/dev/null
