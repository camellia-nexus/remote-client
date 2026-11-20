#!/usr/bin/env bash
set -euo pipefail

: "${ACTIONS_TOKEN:?ACTIONS_TOKEN is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${RELEASE_APP_LOGIN:?RELEASE_APP_LOGIN is required}"
: "${RELEASE_ASSET_DIRECTORY:?RELEASE_ASSET_DIRECTORY is required}"
: "${RELEASE_COMMIT:?RELEASE_COMMIT is required}"
: "${RELEASE_ID:?RELEASE_ID is required}"
: "${RELEASE_PR_NUMBER:?RELEASE_PR_NUMBER is required}"
: "${RELEASE_SIGNING_IDENTITY:?RELEASE_SIGNING_IDENTITY is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${RELEASE_TITLE:?RELEASE_TITLE is required}"
: "${VERSION:?VERSION is required}"

verify_published_only="${VERIFY_PUBLISHED_ONLY:-false}"
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
issuer="https://token.actions.githubusercontent.com"
tag_identity="https://github.com/$GITHUB_REPOSITORY/.github/workflows/publish-release.yml@refs/tags/$RELEASE_TAG"
main_identity="https://github.com/$GITHUB_REPOSITORY/.github/workflows/publish-release.yml@refs/heads/main"
work_directory="$(mktemp -d "${RUNNER_TEMP:-/tmp}/client-release.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
[[ "$RELEASE_TAG" == "v$VERSION" ]]
[[ "$RELEASE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$RELEASE_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$RELEASE_PR_NUMBER" =~ ^[1-9][0-9]*$ ]]
[[ "$verify_published_only" == true || "$verify_published_only" == false ]]
[[ "$RELEASE_SIGNING_IDENTITY" == "$tag_identity" ||
  "$RELEASE_SIGNING_IDENTITY" == "$main_identity" ]] || {
  echo "Release signing identity is not an authorized publication workflow" >&2
  exit 1
}

release_json="$work_directory/release.json"
assets_json="$work_directory/assets.json"
remote_names="$work_directory/remote-assets"
expected_raw_names="$work_directory/expected-raw-assets"
expected_names="$work_directory/expected-assets"

refresh_release() {
  GH_TOKEN="$GH_TOKEN" gh api --paginate --slurp \
    "repos/$GITHUB_REPOSITORY/releases?per_page=100" |
    jq -ce --arg tag "$RELEASE_TAG" --argjson id "$RELEASE_ID" '
      [.[][] | select(.tag_name == $tag)] as $matches |
      if ($matches | length) == 1 and $matches[0].id == $id then $matches[0]
      elif ($matches | length) == 0 then error("managed release not found")
      elif ($matches | length) > 1 then error("multiple releases use the same tag")
      else error("managed release identity changed") end
    ' > "$release_json"
  jq -e \
    --arg app "$RELEASE_APP_LOGIN" \
    --arg sha "$RELEASE_COMMIT" \
    --arg tag "$RELEASE_TAG" \
    --arg title "$RELEASE_TITLE $VERSION" \
    --argjson id "$RELEASE_ID" '
      .id == $id and
      .tag_name == $tag and
      .target_commitish == $sha and
      .author.login == $app and
      .name == $title and
      .prerelease == false and
      (.draft | type == "boolean") and
      (.immutable | type == "boolean") and
      (.draft == true or .immutable == true) and
      (.assets | type == "array")
    ' "$release_json" >/dev/null || {
    echo "Managed Release metadata changed" >&2
    return 1
  }
  local body
  body="$(jq -r '.body // ""' "$release_json")"
  [[ "$(grep -Fxc "<!-- release-commit:$RELEASE_COMMIT -->" <<< "$body" || true)" == 1 ]]
  [[ "$(grep -Fxc "<!-- release-pr:$RELEASE_PR_NUMBER -->" <<< "$body" || true)" == 1 ]]
  jq -ce '.assets' "$release_json" > "$assets_json"
  jq -r '.[].name' "$assets_json" | LC_ALL=C sort > "$remote_names"
  [[ -z "$(uniq -d "$remote_names")" ]] || {
    echo "Release contains duplicate asset names" >&2
    return 1
  }
}

download_asset() {
  local name="$1" destination="$2" asset_id
  asset_id="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .id' "$assets_json")"
  [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] || {
    echo "Unable to resolve remote asset $name" >&2
    return 1
  }
  GH_TOKEN="$GH_TOKEN" gh api -H "Accept: application/octet-stream" \
    "repos/$GITHUB_REPOSITORY/releases/assets/$asset_id" > "$destination"
}

verify_blob_bundle() {
  local subject="$1" bundle="$2" identity
  local -a identities=("$tag_identity")
  [[ "$RELEASE_SIGNING_IDENTITY" == "$tag_identity" ]] ||
    identities+=("$RELEASE_SIGNING_IDENTITY")
  for identity in "${identities[@]}"; do
    if cosign verify-blob "$subject" \
      --bundle "$bundle" \
      --certificate-identity "$identity" \
      --certificate-oidc-issuer "$issuer" >/dev/null 2>&1; then
      return 0
    fi
  done
  echo "Blob signature is not bound to the managed publication workflow: $(basename "$bundle")" >&2
  return 1
}

configure_local_assets() {
  [[ -d "$RELEASE_ASSET_DIRECTORY" && ! -L "$RELEASE_ASSET_DIRECTORY" ]]
  find "$RELEASE_ASSET_DIRECTORY" -maxdepth 1 -type f ! -name "*.sigstore.json" \
    -printf "%f\n" | LC_ALL=C sort > "$expected_raw_names"
  grep -Fxq SHA256SUMS "$expected_raw_names"
  grep -Fxq release-evidence.json "$expected_raw_names"
  {
    cat "$expected_raw_names"
    sed 's/$/.sigstore.json/' "$expected_raw_names"
  } | LC_ALL=C sort > "$expected_names"
}

configure_remote_assets() {
  local bootstrap="$work_directory/checksum-bootstrap"
  local bootstrap_bundle="$bootstrap.sigstore.json"
  grep -Fxq SHA256SUMS "$remote_names" ||
    { echo "Published Release has no checksum inventory" >&2; return 1; }
  grep -Fxq SHA256SUMS.sigstore.json "$remote_names" ||
    { echo "Published Release has no signed checksum inventory" >&2; return 1; }
  download_asset SHA256SUMS "$bootstrap"
  download_asset SHA256SUMS.sigstore.json "$bootstrap_bundle"
  verify_blob_bundle "$bootstrap" "$bootstrap_bundle"
  python3 - "$bootstrap" "$expected_raw_names" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
entries = []
for line in source.read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(r"[0-9a-f]{64}  ([A-Za-z0-9][A-Za-z0-9._+-]*)", line)
    if not match:
        raise ValueError("SHA256SUMS contains an unsafe or malformed entry")
    name = match.group(1)
    if name == "SHA256SUMS" or name.endswith(".sigstore.json"):
        raise ValueError("SHA256SUMS contains a recursive or signature entry")
    entries.append(name)
if entries != sorted(set(entries)):
    raise ValueError("SHA256SUMS entries must be sorted and unique")
destination.write_text(
    "\n".join(sorted(["SHA256SUMS", *entries])) + "\n",
    encoding="utf-8",
)
PY
  {
    cat "$expected_raw_names"
    sed 's/$/.sigstore.json/' "$expected_raw_names"
  } | LC_ALL=C sort > "$expected_names"
}

verify_asset_directory() {
  local directory="$1" raw name
  find "$directory" -maxdepth 1 -type f -printf "%f\n" |
    LC_ALL=C sort > "$work_directory/actual-assets"
  diff -u "$expected_names" "$work_directory/actual-assets"
  (
    cd "$directory"
    sha256sum --check SHA256SUMS
  )
  python3 "$script_directory/validate-release-evidence.py" \
    "$directory/release-evidence.json" >/dev/null
  jq -e \
    --arg commit "$RELEASE_COMMIT" \
    --arg version "$VERSION" '
      .repository == "remote-client" and
      .version == $version and
      .release_kind == "formal" and
      .source.commit == $commit and
      .source.ref == ("refs/tags/v" + $version) and
      (.files | length > 0) and
      .images == []
    ' "$directory/release-evidence.json" >/dev/null
  while IFS= read -r raw; do
    name="$directory/$raw"
    [[ -f "$name" && ! -L "$name" ]]
    verify_blob_bundle "$name" "$name.sigstore.json"
  done < "$expected_raw_names"
}

verify_remote_release() {
  local destination="$1" name
  refresh_release
  [[ "$(jq -r '.draft' "$release_json")" == false ]]
  [[ "$(jq -r '.immutable' "$release_json")" == true ]]
  jq -e --arg app "$RELEASE_APP_LOGIN" \
    '[.[] | select(.uploader.login != $app)] | length == 0' \
    "$assets_json" >/dev/null
  rm -rf "$destination"
  mkdir "$destination"
  while IFS= read -r name; do
    download_asset "$name" "$destination/$name"
  done < "$expected_names"
  verify_asset_directory "$destination"
}

refresh_release
if [[ "$(jq -r '.draft' "$release_json")" == false ]]; then
  [[ "$verify_published_only" == true || "$verify_published_only" == false ]]
  configure_remote_assets
  diff -u "$expected_names" "$remote_names"
  verify_remote_release "$work_directory/published-recovery"
  echo "Verified existing immutable $RELEASE_TAG"
  exit 0
fi

[[ "$verify_published_only" == false ]] || {
  echo "Release remains draft but recovery has no frozen candidate" >&2
  exit 1
}
python3 "$script_directory/audit_cargo_dependencies.py" --policy-only \
  --authorization-policy "$script_directory/cargo-audit-policy.json"
configure_local_assets
(
  cd "$RELEASE_ASSET_DIRECTORY"
  find . -maxdepth 1 -type f ! -name "*.sigstore.json" ! -name SHA256SUMS \
    -printf "%f\0" |
    LC_ALL=C sort -z |
    xargs -0 sha256sum > "$work_directory/release-checksums"
  mv "$work_directory/release-checksums" SHA256SUMS
  sha256sum --check SHA256SUMS
)
configure_local_assets
mapfile -d "" subjects < <(
  find "$RELEASE_ASSET_DIRECTORY" -maxdepth 1 -type f ! -name "*.sigstore.json" \
    -print0 | sort -z
)
for subject in "${subjects[@]}"; do
  cosign sign-blob --yes --bundle "$subject.sigstore.json" "$subject" >/dev/null
  verify_blob_bundle "$subject" "$subject.sigstore.json"
done
configure_local_assets
verify_asset_directory "$RELEASE_ASSET_DIRECTORY"

LC_ALL=C comm -13 "$expected_names" "$remote_names" > "$work_directory/unexpected-assets"
[[ ! -s "$work_directory/unexpected-assets" ]] || {
  echo "Draft Release contains unexpected assets" >&2
  sed 's/^/  /' "$work_directory/unexpected-assets" >&2
  exit 1
}
while IFS= read -r name; do
  GH_TOKEN="$GH_TOKEN" gh release upload "$RELEASE_TAG" \
    "$RELEASE_ASSET_DIRECTORY/$name" \
    --clobber \
    --repo "$GITHUB_REPOSITORY"
done < "$expected_names"

refresh_release
diff -u "$expected_names" "$remote_names"
[[ "$(jq -r '.draft' "$release_json")" == true ]]
ACTIONS_TOKEN="$ACTIONS_TOKEN" GH_TOKEN="$GH_TOKEN" \
  python3 "$script_directory/manage-release.py" authorize \
  --version "$VERSION" --sha "$RELEASE_COMMIT" --tag "$RELEASE_TAG" >/dev/null
python3 "$script_directory/audit_cargo_dependencies.py" --policy-only \
  --authorization-policy "$script_directory/cargo-audit-policy.json"
GH_TOKEN="$GH_TOKEN" gh release edit "$RELEASE_TAG" \
  --repo "$GITHUB_REPOSITORY" \
  --draft=false

refresh_release
[[ "$(jq -r '.draft' "$release_json")" == false &&
  "$(jq -r '.immutable' "$release_json")" == true ]] || {
  echo "Published Release did not converge to immutable state" >&2
  exit 1
}
verify_remote_release "$work_directory/published"
echo "Published and independently re-read $RELEASE_TAG"
exit 0
