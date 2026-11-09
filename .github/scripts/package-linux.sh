#!/usr/bin/env bash
set -euo pipefail

version="${1:?version is required}"
artifact_arch="${2:?artifact architecture is required}"
deb_arch="${3:?Debian architecture is required}"
appimage_arch="${4:?AppImage architecture is required}"

bundle_dir="$(find flutter/build/linux -type d -path '*/release/bundle' -print -quit)"
test -n "$bundle_dir"
test -x "$bundle_dir/camellia-remote"

mkdir -p artifacts

package_root="artifacts/deb-root-${artifact_arch}"
rm -rf "$package_root"
mkdir -p \
  "$package_root/DEBIAN" \
  "$package_root/usr/bin" \
  "$package_root/usr/lib/camellia-remote" \
  "$package_root/usr/share/applications" \
  "$package_root/usr/share/icons/hicolor/128x128/apps"
cp -a "$bundle_dir/." "$package_root/usr/lib/camellia-remote/"
ln -s ../lib/camellia-remote/camellia-remote "$package_root/usr/bin/camellia-remote"
install -m 0644 res/camellia-remote.desktop "$package_root/usr/share/applications/camellia-remote.desktop"
install -m 0644 res/128x128.png "$package_root/usr/share/icons/hicolor/128x128/apps/camellia-remote.png"
printf '%s\n' \
  'Package: camellia-remote' \
  "Version: ${version}" \
  "Architecture: ${deb_arch}" \
  'Maintainer: Camellia Computing' \
  'Section: net' \
  'Priority: optional' \
  'Depends: libasound2, libglib2.0-0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libgtk-3-0, libx11-6, libxcb1, libxdo3' \
  'Description: Secure remote desktop client' \
  ' Camellia provides remote access, file transfer, and device management.' \
  > "$package_root/DEBIAN/control"
dpkg-deb --build --root-owner-group \
  "$package_root" \
  "artifacts/camellia-remote-${version}-linux-${artifact_arch}.deb"

appdir="artifacts/CamelliaRemote.AppDir"
rm -rf "$appdir"
mkdir -p "$appdir/usr/lib/camellia-remote" "$appdir/usr/share/applications"
cp -a "$bundle_dir/." "$appdir/usr/lib/camellia-remote/"
install -m 0644 res/camellia-remote.desktop "$appdir/camellia-remote.desktop"
install -m 0644 res/128x128.png "$appdir/camellia-remote.png"
ln -s usr/lib/camellia-remote/camellia-remote "$appdir/AppRun"

APPIMAGETOOL_VERSION="1.9.1"
declare -A APPIMAGETOOL_SHA256=(
  ["x86_64"]="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
  ["aarch64"]="f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158"
)
declare -A APPIMAGETOOL_SIZE=(
  ["x86_64"]=15092216
  ["aarch64"]=14678536
)

expected_sha256="${APPIMAGETOOL_SHA256[$appimage_arch]:-}"
expected_size="${APPIMAGETOOL_SIZE[$appimage_arch]:-}"

if [[ -z "$expected_sha256" || -z "$expected_size" ]]; then
  echo "ERROR: Unsupported AppImage architecture: ${appimage_arch}" >&2
  exit 1
fi

appimagetool_url="https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VERSION}/appimagetool-${appimage_arch}.AppImage"
appimagetool="artifacts/appimagetool-${appimage_arch}.AppImage"

# Check if pre-cached tool is available
if [[ -n "${APPIMAGETOOL_CACHE_DIR:-}" && -f "${APPIMAGETOOL_CACHE_DIR}/appimagetool-${appimage_arch}.AppImage" ]]; then
  cp "${APPIMAGETOOL_CACHE_DIR}/appimagetool-${appimage_arch}.AppImage" "$appimagetool"
else
  curl --fail --location --retry 3 "$appimagetool_url" --output "$appimagetool"
fi

actual_size="$(stat -c %s "$appimagetool" 2>/dev/null || stat -f %z "$appimagetool")"
if [[ "$actual_size" -ne "$expected_size" ]]; then
  echo "ERROR: Size mismatch for appimagetool-${appimage_arch}.AppImage (expected ${expected_size}, got ${actual_size})" >&2
  rm -f "$appimagetool"
  exit 1
fi

actual_sha256="$(sha256sum "$appimagetool" | awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "ERROR: SHA-256 mismatch for appimagetool-${appimage_arch}.AppImage (expected ${expected_sha256}, got ${actual_sha256})" >&2
  rm -f "$appimagetool"
  exit 1
fi

# Write toolchain provenance metadata
cat > "artifacts/toolchain-appimagetool-${appimage_arch}.json" <<EOF
{
  "tool": "appimagetool",
  "version": "${APPIMAGETOOL_VERSION}",
  "arch": "${appimage_arch}",
  "url": "${appimagetool_url}",
  "sha256": "${actual_sha256}",
  "size": ${actual_size},
  "verified": true
}
EOF

chmod +x "$appimagetool"
ARCH="$appimage_arch" "$appimagetool" --appimage-extract-and-run \
  "$appdir" \
  "artifacts/camellia-remote-${version}-linux-${artifact_arch}.AppImage"

rm -rf "$package_root" "$appdir" "$appimagetool"
