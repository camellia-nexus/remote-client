#!/usr/bin/env bash
set -euo pipefail

: "${COCOAPODS_VERSION:?COCOAPODS_VERSION is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
json_version="$(tr -d '\r\n' < "$repository_root/.github/config/cocoapods-json-version")"

[[ "$COCOAPODS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "COCOAPODS_VERSION must be an exact semantic version" >&2
  exit 2
}
[[ "$json_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'CocoaPods JSON must be an exact semantic version' >&2
  exit 2
}

brew install nasm
gem install \
  --user-install \
  cocoapods \
  --version "$COCOAPODS_VERSION" \
  --no-document
gem install --user-install json --version "$json_version" --no-document

gem_bin="$(mktemp -d "$RUNNER_TEMP/camellia-apple-tools.XXXXXX")"
ln -s "$repository_root/.github/scripts/pod.rb" "$gem_bin/pod"
pod_version="$("$gem_bin/pod" --version)"
[[ "$pod_version" == "$COCOAPODS_VERSION" ]] || {
  echo "Expected CocoaPods $COCOAPODS_VERSION, found $pod_version" >&2
  exit 1
}

printf '%s\n' "$gem_bin" >> "$GITHUB_PATH"
echo "CocoaPods $pod_version, JSON $json_version and NASM are ready"

# Pre-seed vcpkg baseline and binary in RUNNER_TEMP if needed.
# This prevents bootstrap failures when GitHub's releases/download redirector suffers 504 gateway timeouts.
vcpkg_baseline="120deac3062162151622ca4860575a33844ba10b"
vcpkg_target_dir="${RUNNER_TEMP}/vcpkg"
vcpkg_binary_sha="504b96a5b76136308fc1d461c7721ab7797c3dc0c31eba872bae61ed4fd2960af668f96b862c663dbe4f89c029996a51cf945e9407b2a58b9987f6c166475735"

if [[ ! -x "${vcpkg_target_dir}/vcpkg" ]]; then
  echo "Pre-seeding vcpkg at ${vcpkg_target_dir}..."
  for attempt in 1 2 3 4 5; do
    rm -rf "${vcpkg_target_dir}"
    if GIT_TERMINAL_PROMPT=0 git clone https://github.com/microsoft/vcpkg.git -n "${vcpkg_target_dir}"; then
      break
    fi
    echo "git clone vcpkg failed (attempt $attempt), retrying in 3s..."
    sleep 3
  done
  git -C "${vcpkg_target_dir}" checkout --force "${vcpkg_baseline}"

  download_url="https://github.com/microsoft/vcpkg-tool/releases/download/2025-07-21/vcpkg-macos"
  api_asset_url="https://api.github.com/repos/microsoft/vcpkg-tool/releases/assets/275051630"

  if ! curl -L --tlsv1.2 --create-dirs --connect-timeout 5 --max-time 15 --retry 1 --output "${vcpkg_target_dir}/vcpkg" --silent --show-error --fail "${download_url}"; then
    echo "Direct release download failed; fetching vcpkg-macos from GitHub API asset endpoint..."
    curl -L --tlsv1.2 --create-dirs --connect-timeout 10 --max-time 60 --retry 3 -H "Accept: application/octet-stream" --output "${vcpkg_target_dir}/vcpkg" --silent --show-error --fail "${api_asset_url}"
  fi

  actual_sha="$(shasum -a 512 "${vcpkg_target_dir}/vcpkg" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${vcpkg_binary_sha}" ]]; then
    echo "Downloaded vcpkg binary hash mismatch: expected ${vcpkg_binary_sha}, got ${actual_sha}" >&2
    exit 1
  fi
  chmod +x "${vcpkg_target_dir}/vcpkg"
  printf '%s' "${vcpkg_baseline}" > "${vcpkg_target_dir}/vcpkgLastBuiltCommitId"
  if [[ -f "${vcpkg_target_dir}/bootstrap-vcpkg.sh" ]]; then
    python3 -c "
p = '${vcpkg_target_dir}/bootstrap-vcpkg.sh'
with open(p, 'r') as f:
    c = f.read()
if 'exit 0' not in c:
    lines = c.split('\n', 1)
    rest = lines[1] if len(lines) > 1 else ''
    with open(p, 'w') as f:
        f.write('#!/bin/sh -e\nif [ -x \"\$(dirname \"\$0\")/vcpkg\" ]; then exit 0; fi\n' + rest)
"
    chmod +x "${vcpkg_target_dir}/bootstrap-vcpkg.sh"
  fi
  echo "vcpkg pre-seed complete."
fi

