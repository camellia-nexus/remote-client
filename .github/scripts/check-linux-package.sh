#!/usr/bin/env bash
set -euo pipefail

deb_file="${1:-}"
appdir_or_appimage="${2:-}"
target_arch="${3:-x86_64}"

echo "=== Linux Packaging & Dependency Closure Verification ==="

if [[ -n "$deb_file" ]]; then
  echo "--- Verifying Debian package: $deb_file ---"
  test -f "$deb_file"

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  # Verify package control metadata
  dpkg-deb -I "$deb_file" > "$tmp_dir/control_info.txt"
  grep -q "^ Package: camellia-remote$" "$tmp_dir/control_info.txt"
  grep -q "^ Maintainer: Camellia Computing$" "$tmp_dir/control_info.txt"
  grep -q "libgtk-3-0" "$tmp_dir/control_info.txt"
  grep -q "libx11-6" "$tmp_dir/control_info.txt"
  grep -q "libxdo3" "$tmp_dir/control_info.txt"

  # Extract control scripts
  dpkg-deb -e "$deb_file" "$tmp_dir/DEBIAN"
  for script in preinst postinst prerm postrm; do
    test -f "$tmp_dir/DEBIAN/$script"
    test -x "$tmp_dir/DEBIAN/$script"
  done

  # Verify maintainer script contracts (BUILD-012)
  grep -q "camellia-remote.service" "$tmp_dir/DEBIAN/preinst"
  grep -q "daemon-reload" "$tmp_dir/DEBIAN/postinst"
  grep -q "update-desktop-database" "$tmp_dir/DEBIAN/postinst"
  grep -q "update-mime-database" "$tmp_dir/DEBIAN/postinst"
  grep -q "camellia-remote.service" "$tmp_dir/DEBIAN/prerm"
  grep -q "daemon-reload" "$tmp_dir/DEBIAN/postrm"

  # Extract data filesystem
  dpkg-deb -x "$deb_file" "$tmp_dir/data"
  test -x "$tmp_dir/data/usr/lib/camellia-remote/camellia-remote"
  test -L "$tmp_dir/data/usr/bin/camellia-remote"
  test -f "$tmp_dir/data/lib/systemd/system/camellia-remote.service"
  test -f "$tmp_dir/data/usr/share/applications/camellia-remote.desktop"
  test -f "$tmp_dir/data/usr/share/applications/camellia-remote-link.desktop"
  test -f "$tmp_dir/data/usr/share/icons/hicolor/128x128/apps/camellia-remote.png"

  # Verify desktop scheme handler association (BUILD-011)
  grep -q "MimeType=x-scheme-handler/camellia-remote;" "$tmp_dir/data/usr/share/applications/camellia-remote.desktop"
  grep -q "Exec=camellia-remote %u" "$tmp_dir/data/usr/share/applications/camellia-remote.desktop"
  grep -q "MimeType=x-scheme-handler/camellia-remote;" "$tmp_dir/data/usr/share/applications/camellia-remote-link.desktop"
  grep -q "NoDisplay=true" "$tmp_dir/data/usr/share/applications/camellia-remote-link.desktop"

  # Verify service unit safety (BUILD-012)
  grep -q "Description=Camellia Remote Service" "$tmp_dir/data/lib/systemd/system/camellia-remote.service"
  grep -q "ExecStart=/usr/bin/camellia-remote --service" "$tmp_dir/data/lib/systemd/system/camellia-remote.service"
  if grep -q "pkill" "$tmp_dir/data/lib/systemd/system/camellia-remote.service"; then
    echo "ERROR: Unsafe broad pkill found in camellia-remote.service" >&2
    exit 1
  fi
  if grep -q "PIDFile" "$tmp_dir/data/lib/systemd/system/camellia-remote.service"; then
    echo "ERROR: Unowned PIDFile found in camellia-remote.service" >&2
    exit 1
  fi

  echo "Debian package verification PASSED."
fi

if [[ -n "$appdir_or_appimage" ]]; then
  echo "--- Verifying AppDir / AppImage: $appdir_or_appimage ---"

  appdir=""
  if [[ -d "$appdir_or_appimage" ]]; then
    appdir="$appdir_or_appimage"
  elif [[ -f "$appdir_or_appimage" ]]; then
    appimage_tmp="$(mktemp -d)"
    trap 'rm -rf "$appimage_tmp"' EXIT
    test -x "$appdir_or_appimage"
    # Extract AppImage if possible
    "$appdir_or_appimage" --appimage-extract >/dev/null 2>&1
    appdir="squashfs-root"
  fi

  test -d "$appdir"
  test -x "$appdir/AppRun"
  test -f "$appdir/camellia-remote.desktop"
  test -f "$appdir/camellia-remote.png"
  test -f "$appdir/.DirIcon"
  test -f "$appdir/usr/share/applications/camellia-remote.desktop"
  test -f "$appdir/usr/share/applications/camellia-remote-link.desktop"

  # Verify desktop scheme handler in AppImage (BUILD-011)
  grep -q "MimeType=x-scheme-handler/camellia-remote;" "$appdir/camellia-remote.desktop"
  grep -q "MimeType=x-scheme-handler/camellia-remote;" "$appdir/usr/share/applications/camellia-remote.desktop"
  grep -q "MimeType=x-scheme-handler/camellia-remote;" "$appdir/usr/share/applications/camellia-remote-link.desktop"

  # Verify AppRun environment isolation (BUILD-013)
  grep -q "LD_LIBRARY_PATH" "$appdir/AppRun"
  grep -q "XDG_DATA_DIRS" "$appdir/AppRun"
  grep -q "exec \"\${APPDIR}/usr/lib/camellia-remote/camellia-remote\"" "$appdir/AppRun"

  # Verify ELF binaries and architecture closure (BUILD-013)
  main_elf="$appdir/usr/lib/camellia-remote/camellia-remote"
  test -x "$main_elf"

  case "$target_arch" in
    x86_64)
      expected_pattern="ELF 64-bit LSB (pie executable|executable|shared object), x86-64"
      ;;
    aarch64)
      expected_pattern="ELF 64-bit LSB (pie executable|executable|shared object), ARM aarch64"
      ;;
    *)
      expected_pattern="ELF 64-bit LSB"
      ;;
  esac

  main_desc="$(file -b "$main_elf")"
  if [[ ! "$main_desc" =~ $expected_pattern ]]; then
    echo "ERROR: Architecture mismatch in $main_elf: got '$main_desc'" >&2
    exit 1
  fi

  echo "AppDir / AppImage verification PASSED."
fi

echo "All Linux package checks PASSED."
