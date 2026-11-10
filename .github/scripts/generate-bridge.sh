#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

provenance_config=".github/config/bridge-codegen-provenance.json"
if [[ ! -f "$provenance_config" ]]; then
  echo "Missing provenance config: $provenance_config" >&2
  exit 1
fi

default_version="$(python3 -c "import json; print(json.load(open('$provenance_config'))['default_version'])")"
frb_codegen_version="${FRB_CODEGEN_VERSION:-$default_version}"
rust_features="${FRB_RUST_FEATURES:-}"

# Verify version is supported in provenance manifest
python3 -c "
import json, sys
data = json.load(open('$provenance_config'))
ver = '$frb_codegen_version'
if ver not in data.get('versions', {}):
    sys.exit(f'Unsupported FRB codegen version {ver}; not found in {provenance_config}')
"

installed_version=""
if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  installed_version="$(flutter_rust_bridge_codegen --version | awk '{print $NF}')"
fi

if [[ "${installed_version}" != "${frb_codegen_version}" ]]; then
  echo "Installing flutter_rust_bridge_codegen ${frb_codegen_version} with --locked..."
  cargo install flutter_rust_bridge_codegen --version "${frb_codegen_version}" --locked
fi

# Verify crate and Cargo.lock cryptographic provenance
python3 -c "
import glob, hashlib, json, sys
from pathlib import Path

target_version = '$frb_codegen_version'
data = json.load(open('$provenance_config'))['versions'][target_version]
exp_crate = data['crate_sha256']
exp_lock = data['lockfile_sha256']

cargo_home = Path.home() / '.cargo'
crate_matches = list(cargo_home.glob(f'registry/cache/**/flutter_rust_bridge_codegen-{target_version}.crate'))
for crate_file in crate_matches:
    digest = hashlib.sha256(crate_file.read_bytes()).hexdigest()
    if digest != exp_crate:
        sys.exit(f'Cryptographic mismatch on {crate_file}: {digest} != {exp_crate}')
    print(f'[Provenance] Verified crate checksum: {digest}')

lock_matches = list(cargo_home.glob(f'registry/src/**/flutter_rust_bridge_codegen-{target_version}/Cargo.lock'))
for lock_file in lock_matches:
    digest = hashlib.sha256(lock_file.read_bytes()).hexdigest()
    if digest != exp_lock:
        sys.exit(f'Cryptographic mismatch on {lock_file}: {digest} != {exp_lock}')
    print(f'[Provenance] Verified lockfile checksum: {digest}')
"

codegen_bin="$(command -v flutter_rust_bridge_codegen)"
bin_sha256="$(sha256sum "$codegen_bin" | awk '{print $1}')"
echo "[Provenance] Codegen executable: $codegen_bin ($bin_sha256)"
echo "[Provenance] Rust toolchain: $(rustc --version) / $(cargo --version)"

args=(
  --rust-input crate::flutter_ffi
  --rust-root .
  --rust-output ./src/bridge_generated.rs
  --dart-root ./flutter
  --dart-output ./flutter/lib/generated_bridge
  --c-output ./flutter/ios/Runner/bridge_generated.h
  --duplicated-c-output ./flutter/macos/Runner/bridge_generated.h
  --no-add-mod-to-lib
  --type-64bit-int
  --no-deps-check
  --no-auto-upgrade-dependency
)

if [[ -n "${rust_features}" ]]; then
  args+=(--rust-features "${rust_features}")
fi

flutter_rust_bridge_codegen generate "${args[@]}"
python3 .github/scripts/generate-bridge-facade.py
dart format \
  ./flutter/lib/generated_bridge.dart \
  ./flutter/lib/generated_bridge
python3 .github/scripts/normalize-generated-bridge.py
