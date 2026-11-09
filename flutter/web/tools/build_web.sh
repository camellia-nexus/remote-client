#!/usr/bin/env bash

set -euo pipefail

MODE="${MODE:-release}"
RUN=false
SKIP_JS=false
SKIP_DEPS=false
BASE_HREF="${BASE_HREF:-/}"

usage() {
  cat <<'EOF'
Usage: build_web.sh [options]

Options:
  --mode release|profile|debug  Build mode (default: release)
  --base-href PATH              Base href for web deployment (default: /)
  --run                         Run in Chrome instead of producing build/web
  --skip-js                     Reuse the existing compiled JS bridge
  --skip-deps                   Do not bootstrap optional codec assets
  -h, --help                    Show this help

The build never rewrites tracked launcher icons. Refresh those explicitly with
`dart run tool/generate_brand_assets.dart` from the Flutter directory and
review the generated source diff.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "--mode requires a value" >&2
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    --base-href)
      if [[ $# -lt 2 ]]; then
        echo "--base-href requires a value" >&2
        exit 1
      fi
      BASE_HREF="$2"
      shift 2
      ;;
    --run)
      RUN=true
      shift
      ;;
    --skip-js)
      SKIP_JS=true
      shift
      ;;
    --skip-deps)
      SKIP_DEPS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

case "$MODE" in
  release|profile|debug) ;;
  *)
    echo "Unsupported build mode: $MODE" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$FLUTTER_ROOT"

FLUTTER="${FLUTTER_BIN:-flutter}"
if ! command -v -- "$FLUTTER" >/dev/null 2>&1; then
  echo "Missing '$FLUTTER'. Install Flutter and ensure it is in PATH, or set FLUTTER_BIN." >&2
  exit 1
fi

WEB_DIR="${FLUTTER_ROOT}/web"
WEB_JS_DIR="${WEB_DIR}/js"
WEB_JS_PKG="${WEB_JS_DIR}/package.json"
WEB_JS_LOCK="${WEB_JS_DIR}/package-lock.json"
REPO_ROOT="$(cd "${FLUTTER_ROOT}/.." && pwd)"
PUBSPEC_FILE="${FLUTTER_ROOT}/pubspec.yaml"
APP_VERSION_VALUE="${APP_VERSION:-}"
APP_NAME_VALUE="${APP_NAME:-}"
if [[ -z "$APP_VERSION_VALUE" && -f "$PUBSPEC_FILE" ]]; then
  APP_VERSION_VALUE="$(grep -E '^version:' "$PUBSPEC_FILE" | head -n 1 | sed -E 's/^version:[[:space:]]*//')"
fi

required_web_assets=(
  "index.html"
  "manifest.json"
  "favicon.svg"
  "favicon.png"
  "icons/Icon-192.png"
  "icons/Icon-512.png"
  "icons/Icon-maskable-192.png"
  "icons/Icon-maskable-512.png"
)
for required_asset in "${required_web_assets[@]}"; do
  if [[ ! -f "${WEB_DIR}/${required_asset}" ]]; then
    echo "Missing web asset: ${WEB_DIR}/${required_asset}" >&2
    exit 2
  fi
done

if [[ "$SKIP_DEPS" == "false" ]]; then
  bash "${SCRIPT_DIR}/prepare_web_deps.sh"
fi

"$FLUTTER" pub get --enforce-lockfile

if [[ "$SKIP_JS" == "false" ]]; then
  if [[ ! -f "$WEB_JS_PKG" ]]; then
    echo "Missing '$WEB_JS_PKG'. Add the web JS bridge toolchain, or use --skip-js." >&2
    exit 3
  fi
  if [[ ! -f "$WEB_JS_LOCK" ]]; then
    echo "Missing '$WEB_JS_LOCK'. Web builds require the committed npm lockfile." >&2
    exit 3
  fi
  if ! command -v npm >/dev/null 2>&1; then
    echo "Missing 'npm'. Install Node.js (npm) to build web JS dependencies." >&2
    exit 4
  fi
  pushd "$WEB_JS_DIR" >/dev/null
  npm ci --no-fund --no-audit
  npm run build
  popd >/dev/null
fi

if [[ ! -f "${WEB_JS_DIR}/dist/web_bridge.js" ]]; then
  echo "Missing compiled JS bridge: ${WEB_JS_DIR}/dist/web_bridge.js" >&2
  exit 3
fi

BUILD_DATE_VALUE="${BUILD_DATE:-}"
if [[ -z "$BUILD_DATE_VALUE" ]]; then
  SOURCE_DATE_EPOCH_VALUE="${SOURCE_DATE_EPOCH:-}"
  if [[ -z "$SOURCE_DATE_EPOCH_VALUE" ]]; then
    SOURCE_DATE_EPOCH_VALUE="$(git -C "$REPO_ROOT" show -s --format=%ct HEAD)"
  fi
  if [[ ! "$SOURCE_DATE_EPOCH_VALUE" =~ ^[0-9]+$ ]]; then
    echo "SOURCE_DATE_EPOCH must be a non-negative integer." >&2
    exit 4
  fi
  if BUILD_DATE_VALUE="$(date -u -d "@${SOURCE_DATE_EPOCH_VALUE}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null)"; then
    :
  elif BUILD_DATE_VALUE="$(date -u -r "$SOURCE_DATE_EPOCH_VALUE" '+%Y-%m-%d %H:%M UTC' 2>/dev/null)"; then
    :
  else
    echo "Unable to convert SOURCE_DATE_EPOCH with the local date command." >&2
    exit 4
  fi
  export SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH_VALUE"
fi
if [[ "$BUILD_DATE_VALUE" == *$'\n'* || "$BUILD_DATE_VALUE" == *$'\r'* ]]; then
  echo "BUILD_DATE must be a single line." >&2
  exit 4
fi

is_set() {
  if [[ -n "${!1:-}" ]]; then
    printf 'set'
  else
    printf 'unset'
  fi
}

echo "Web build configuration: mode=$MODE base_href=$BASE_HREF run=$RUN version=${APP_VERSION_VALUE:-unset} build_date=$BUILD_DATE_VALUE"
echo "Endpoint configuration: RS_PUB_KEY=$(is_set RS_PUB_KEY) RENDEZVOUS_SERVERS=$(is_set RENDEZVOUS_SERVERS) API_SERVER=$(is_set API_SERVER) APP_NAME=$(is_set APP_NAME)"

FLUTTER_BUILD_ARGS=()
if [[ "$RUN" == "true" ]]; then
  FLUTTER_BUILD_ARGS=("run" "-d" "chrome" "-v")
  if [[ "$MODE" == "release" ]]; then
    FLUTTER_BUILD_ARGS+=("--release")
  elif [[ "$MODE" == "profile" ]]; then
    FLUTTER_BUILD_ARGS+=("--profile")
  fi
else
  FLUTTER_BUILD_ARGS=("build" "web" "--${MODE}" "--no-wasm-dry-run")
  if [[ -n "$BASE_HREF" ]]; then
    FLUTTER_BUILD_ARGS+=("--base-href=${BASE_HREF}")
  fi
  if [[ "$MODE" == "release" ]]; then
    FLUTTER_BUILD_ARGS+=("--csp")
  fi
fi
if [[ -n "${RS_PUB_KEY:-}" ]]; then
  FLUTTER_BUILD_ARGS+=("--dart-define=RS_PUB_KEY=${RS_PUB_KEY}")
fi
if [[ -n "${RENDEZVOUS_SERVERS:-}" ]]; then
  FLUTTER_BUILD_ARGS+=("--dart-define=RENDEZVOUS_SERVERS=${RENDEZVOUS_SERVERS}")
fi
if [[ -n "${API_SERVER:-}" ]]; then
  FLUTTER_BUILD_ARGS+=("--dart-define=API_SERVER=${API_SERVER}")
fi
if [[ -n "$APP_NAME_VALUE" ]]; then
  FLUTTER_BUILD_ARGS+=("--dart-define=APP_NAME=${APP_NAME_VALUE}")
fi
if [[ -n "$APP_VERSION_VALUE" ]]; then
  FLUTTER_BUILD_ARGS+=("--dart-define=APP_VERSION=${APP_VERSION_VALUE}")
fi
FLUTTER_BUILD_ARGS+=("--dart-define=BUILD_DATE=${BUILD_DATE_VALUE}")

"$FLUTTER" "${FLUTTER_BUILD_ARGS[@]}"

if [[ "$RUN" == "false" ]]; then
  FLUTTER_BOOTSTRAP="${FLUTTER_ROOT}/build/web/flutter_bootstrap.js"
  if [[ ! -f "$FLUTTER_BOOTSTRAP" ]] ||
    ! grep -q '"compileTarget":"dart2js"' "$FLUTTER_BOOTSTRAP"; then
    echo "Incomplete Flutter web build configuration." >&2
    exit 5
  fi
  if grep -Eq '"builds":\[[^]]*(\{\},|,\{\})' "$FLUTTER_BOOTSTRAP"; then
    echo "Flutter web build contains an empty target configuration." >&2
    exit 6
  fi

  SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    SOURCE_STATE="dirty"
  else
    SOURCE_STATE="clean"
  fi
  printf '%s %s\n' "$SOURCE_REVISION" "$SOURCE_STATE" > "${FLUTTER_ROOT}/build/web/.source_revision"

  python3 -c '
import hashlib, json, os, sys
from pathlib import Path

web_build = Path(sys.argv[1])
repo_root = Path(sys.argv[2])
revision = sys.argv[3]
state = sys.argv[4]
base_href = sys.argv[5]

files = {}
for root, _, filenames in os.walk(web_build):
    for fn in filenames:
        fp = Path(root) / fn
        rel = fp.relative_to(web_build).as_posix()
        if rel in (".source_revision", "build_manifest.json"):
            continue
        data = fp.read_bytes()
        files[rel] = {
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest()
        }

sorted_files = sorted(files.keys())
lines = [k + ":" + str(files[k]["size"]) + ":" + files[k]["sha256"] for k in sorted_files]
root_digest = hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()

manifest = {
    "schema_version": 1,
    "source_revision": revision,
    "source_state": state,
    "base_href": base_href,
    "root_digest": root_digest,
    "files": files
}

manifest_file = web_build / "build_manifest.json"
with manifest_file.open("w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
' "${FLUTTER_ROOT}/build/web" "$REPO_ROOT" "$SOURCE_REVISION" "$SOURCE_STATE" "$BASE_HREF"
fi
