#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_FILE="${SCRIPT_DIR}/web_codec_manifest.json"

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "Missing web codec manifest: $MANIFEST_FILE" >&2
  exit 1
fi

VERIFY_ONLY=false
if [[ "${1:-}" == "--verify-only" ]]; then
  VERIFY_ONLY=true
fi

verify_web_deps() {
  local target_dir="$1"
  python3 -c '
import hashlib, json, sys
from pathlib import Path

target_dir = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
with manifest_path.open("r", encoding="utf-8") as f:
    manifest = json.load(f)

files = manifest.get("files", {})
if not files:
    sys.exit(1)

for rel_path, spec in files.items():
    file_path = target_dir / rel_path
    if not file_path.is_file():
        sys.exit(2)
    stat = file_path.stat()
    if stat.st_size != spec["size"]:
        sys.exit(3)
    digest = hashlib.sha256(file_path.read_bytes()).hexdigest()
    if digest.lower() != spec["sha256"].lower():
        sys.exit(4)
sys.exit(0)
' "$target_dir" "$MANIFEST_FILE"
}

if verify_web_deps "$WEB_DIR"; then
  echo "Web codec assets verified against web_codec_manifest.json, skipping download."
  exit 0
fi

if [[ "$VERIFY_ONLY" == "true" ]]; then
  echo "Web codec verification failed." >&2
  exit 1
fi

read -r WEB_DEPS_URL WEB_DEPS_API_ASSET_URL WEB_DEPS_SHA256 < <(
  python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    m = json.load(f)["archive"]
    print(f"{m[\"url\"]} {m[\"api_asset_url\"]} {m[\"sha256\"]}")
' "$MANIFEST_FILE"
)

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/camellia-web-deps.XXXXXX")"
deps_tar="${temp_dir}/web_deps.tar.gz"
extract_dir="${temp_dir}/extracted"
mkdir -p "$extract_dir"

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

tar -xzf "$deps_tar" -C "$extract_dir"

if ! verify_web_deps "$extract_dir"; then
  echo "Extracted web deps failed manifest verification." >&2
  exit 4
fi

cp -a "$extract_dir"/. "$WEB_DIR"/

if ! verify_web_deps "$WEB_DIR"; then
  echo "Web deps directory verification failed after installation." >&2
  exit 4
fi

echo "Verified Web codec dependencies against web_codec_manifest.json."
