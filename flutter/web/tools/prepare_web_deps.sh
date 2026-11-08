#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WEB_DEPS_URL="https://github.com/rustdesk/doc.rustdesk.com/releases/download/console/web_deps.tar.gz"
WEB_DEPS_API_ASSET_URL="https://api.github.com/repos/rustdesk/doc.rustdesk.com/releases/assets/305513689"
WEB_DEPS_SHA256="b66011c4fc066b90c46ba0c78884fe5d1a7e5a7fad3dce401300ad893de63818"

have_web_deps() {
  [[ -f "${WEB_DIR}/libopus.js" ]] &&
    [[ -f "${WEB_DIR}/libopus.wasm" ]] &&
    [[ -f "${WEB_DIR}/yuv-canvas-1.2.6.js" ]] &&
    [[ -f "${WEB_DIR}/ogvjs-1.8.6/ogv-decoder-video-vp8-wasm.js" ]] &&
    [[ -f "${WEB_DIR}/ogvjs-1.8.6/ogv-decoder-video-vp8-wasm.wasm" ]] &&
    [[ -f "${WEB_DIR}/ogvjs-1.8.6/ogv-decoder-video-vp9-wasm.js" ]] &&
    [[ -f "${WEB_DIR}/ogvjs-1.8.6/ogv-decoder-video-vp9-wasm.wasm" ]] &&
    [[ -f "${WEB_DIR}/ogvjs-1.8.6/ogv-decoder-video-av1-wasm.js" ]] &&
    [[ -f "${WEB_DIR}/ogvjs-1.8.6/ogv-decoder-video-av1-wasm.wasm" ]]
}

if have_web_deps; then
  echo "Web deps already present, skipping download."
  exit 0
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustdesk-web-deps.XXXXXX")"
deps_tar="${temp_dir}/web_deps.tar.gz"
cleanup() {
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

echo "Downloading web deps: $WEB_DEPS_URL"
if ! curl -L --tlsv1.2 --create-dirs --connect-timeout 5 --max-time 15 --retry 1 -o "$deps_tar" --silent --show-error --fail "$WEB_DEPS_URL"; then
  echo "Direct release download failed; fetching web_deps.tar.gz from GitHub API asset endpoint..."
  curl -L --tlsv1.2 --create-dirs --connect-timeout 10 --max-time 60 --retry 3 -H "Accept: application/octet-stream" -o "$deps_tar" --silent --show-error --fail "$WEB_DEPS_API_ASSET_URL"
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256="$(sha256sum "$deps_tar" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  actual_sha256="$(shasum -a 256 "$deps_tar" | awk '{print $1}')"
else
  echo "Missing SHA-256 tool (sha256sum or shasum)." >&2
  exit 4
fi
if [[ "$actual_sha256" != "$WEB_DEPS_SHA256" ]]; then
  echo "Web deps checksum mismatch: expected $WEB_DEPS_SHA256, got $actual_sha256" >&2
  exit 4
fi

if ! tar -tzf "$deps_tar" | awk '
  /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
  !/^(ogvjs-1\.8\.6\/|libopus\.js$|libopus\.wasm$|yuv-canvas-1\.2\.6\.js$)/ { bad = 1 }
  END { exit bad }
'; then
  echo "Web deps archive contains an unsafe or unexpected path." >&2
  exit 4
fi
if tar -tvzf "$deps_tar" | awk '$1 ~ /^[lh]/ { found = 1 } END { exit !found }'; then
  echo "Web deps archive must not contain symbolic or hard links." >&2
  exit 4
fi

tar -xzf "$deps_tar" -C "$WEB_DIR"
if ! have_web_deps; then
  echo "Web deps archive is incomplete after extraction." >&2
  exit 4
fi

echo "Verified Web codec dependencies."
