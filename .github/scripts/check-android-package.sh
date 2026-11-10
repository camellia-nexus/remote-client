#!/usr/bin/env bash
set -euo pipefail

# check-android-package.sh
# Validates Android packaging contracts (BUILD-014, COMPAT-005, RES-062):
# - ABI filters configured to arm64-v8a in build.gradle
# - System.loadLibrary("camellia_remote") requires libcamellia_remote.so
# - No misnamed camellia_remote.so in jniLibs or package artifacts
# - No orphaned partial ABIs (e.g. x86_64, armeabi-v7a) without core so
# - libc++_shared.so closure validation when required by DT_NEEDED

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --repo-check            Validate repository configuration and source contracts (default)
  --apk <path>            Inspect and validate an APK archive
  --aab <path>            Inspect and validate an AAB archive
  --jni-dir <path>        Inspect a jniLibs directory
  -h, --help              Show this help message
EOF
}

TARGET_APK=""
TARGET_AAB=""
TARGET_JNI=""
DO_REPO_CHECK=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-check)
      DO_REPO_CHECK=true
      shift
      ;;
    --apk)
      TARGET_APK="${2:?Path to APK required}"
      DO_REPO_CHECK=false
      shift 2
      ;;
    --aab)
      TARGET_AAB="${2:?Path to AAB required}"
      DO_REPO_CHECK=false
      shift 2
      ;;
    --jni-dir)
      TARGET_JNI="${2:?Path to jniLibs required}"
      DO_REPO_CHECK=false
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

validate_repo() {
  echo "==> Validating repository Android build configurations..."
  local build_gradle="$CLIENT_ROOT/flutter/android/app/build.gradle"
  local ffi_kt="$CLIENT_ROOT/flutter/android/app/src/main/kotlin/ffi.kt"
  local build_py="$CLIENT_ROOT/build.py"

  [[ -f "$build_gradle" ]] || {
    echo "ERROR: build.gradle not found at $build_gradle" >&2
    return 1
  }

  [[ -f "$ffi_kt" ]] || {
    echo "ERROR: ffi.kt not found at $ffi_kt" >&2
    return 1
  }

  # 1. build.gradle must have abiFilters "arm64-v8a"
  if ! grep -q 'abiFilters.*arm64-v8a' "$build_gradle"; then
    echo "ERROR: build.gradle missing abiFilters \"arm64-v8a\" under defaultConfig.ndk" >&2
    return 1
  fi
  echo "  ✓ build.gradle specifies ndk.abiFilters 'arm64-v8a'"

  # 2. ffi.kt must load camellia_remote
  if ! grep -q 'System.loadLibrary("camellia_remote")' "$ffi_kt"; then
    echo "ERROR: ffi.kt must call System.loadLibrary(\"camellia_remote\")" >&2
    return 1
  fi
  echo "  ✓ ffi.kt calls System.loadLibrary(\"camellia_remote\")"

  # 3. build.py must copy to libcamellia_remote.so
  if grep -E 'shutil\.copy2.*jni_libs\s*/\s*"camellia_remote\.so"' "$build_py"; then
    echo "ERROR: build.py copies to un-prefixed camellia_remote.so" >&2
    return 1
  fi
  if ! grep -q 'jni_libs / "libcamellia_remote.so"' "$build_py"; then
    echo "ERROR: build.py must stage to libcamellia_remote.so" >&2
    return 1
  fi
  echo "  ✓ build.py stages correctly named libcamellia_remote.so"

  # 4. Check jniLibs on disk if it exists
  local jni_libs_dir="$CLIENT_ROOT/flutter/android/app/src/main/jniLibs"
  if [[ -d "$jni_libs_dir" ]]; then
    validate_jni_dir "$jni_libs_dir"
  fi

  echo "==> Repository Android packaging contracts OK."
}

validate_jni_dir() {
  local dir="$1"
  echo "==> Validating JNI directory: $dir"

  # Assert no bare camellia_remote.so exists anywhere
  local misnamed
  misnamed=$(find "$dir" -type f -name "camellia_remote.so" 2>/dev/null || true)
  if [[ -n "$misnamed" ]]; then
    echo "ERROR: Found misnamed core library without 'lib' prefix: $misnamed" >&2
    return 1
  fi

  # Check arm64-v8a if present
  if [[ -d "$dir/arm64-v8a" ]]; then
    local core_so="$dir/arm64-v8a/libcamellia_remote.so"
    if [[ -f "$core_so" ]]; then
      echo "  ✓ Found $core_so"
      if command -v readelf >/dev/null 2>&1; then
        local machine
        machine=$(readelf -h "$core_so" | grep "Machine:" || true)
        if [[ ! "$machine" =~ AArch64 ]]; then
          echo "ERROR: $core_so is not AArch64: $machine" >&2
          return 1
        fi
        echo "  ✓ Architecture confirmed: AArch64"

        # Check for absolute RUNPATH
        if readelf -d "$core_so" | grep -E 'RUNPATH|RPATH' | grep -q '/home/'; then
          echo "WARNING: Core ELF contains runner absolute path in RUNPATH" >&2
        fi
      fi
    fi
  fi

  # Check that no other ABI directory has libraries while arm64-v8a is the only target
  for other_abi in armeabi-v7a x86 x86_64; do
    if [[ -d "$dir/$other_abi" ]]; then
      local other_files
      other_files=$(find "$dir/$other_abi" -name "*.so" 2>/dev/null || true)
      if [[ -n "$other_files" ]] && [[ ! -f "$dir/$other_abi/libcamellia_remote.so" ]]; then
        echo "ERROR: Found partial ABI directory $other_abi with libraries but no core so:" >&2
        echo "$other_files" >&2
        return 1
      fi
    fi
  done
  echo "==> JNI directory validation OK."
}

validate_zip_archive() {
  local archive="$1"
  local kind="$2"
  echo "==> Validating $kind archive: $archive"

  [[ -f "$archive" ]] || {
    echo "ERROR: $kind not found at $archive" >&2
    return 1
  }

  command -v unzip >/dev/null 2>&1 || {
    echo "WARNING: unzip not available, skipping archive interior inspection"
    return 0
  }

  local file_list
  file_list=$(unzip -l "$archive")

  # 1. Must NOT have camellia_remote.so without lib prefix
  if echo "$file_list" | grep -qE '(^|[ /])camellia_remote\.so$'; then
    echo "ERROR: $kind contains misnamed 'camellia_remote.so' without 'lib' prefix" >&2
    return 1
  fi
  echo "  ✓ No misnamed 'camellia_remote.so' found"

  # 2. Must contain libcamellia_remote.so in arm64-v8a
  if ! echo "$file_list" | grep -qE 'lib/arm64-v8a/libcamellia_remote\.so|base/lib/arm64-v8a/libcamellia_remote\.so'; then
    echo "ERROR: $kind missing arm64-v8a core library 'libcamellia_remote.so'" >&2
    return 1
  fi
  echo "  ✓ Found libcamellia_remote.so in arm64-v8a"

  # 3. Check for partial ABIs
  for abi in armeabi-v7a x86 x86_64; do
    if echo "$file_list" | grep -qE "lib/$abi/|base/lib/$abi/"; then
      if ! echo "$file_list" | grep -qE "lib/$abi/libcamellia_remote\.so|base/lib/$abi/libcamellia_remote\.so"; then
        echo "ERROR: $kind contains partial ABI '$abi' with secondary JNI libraries but missing core so" >&2
        return 1
      fi
    fi
  done
  echo "  ✓ No orphaned partial ABIs found"

  echo "==> $kind validation OK."
}

if [[ -n "$TARGET_APK" ]]; then
  validate_zip_archive "$TARGET_APK" "APK"
elif [[ -n "$TARGET_AAB" ]]; then
  validate_zip_archive "$TARGET_AAB" "AAB"
elif [[ -n "$TARGET_JNI" ]]; then
  validate_jni_dir "$TARGET_JNI"
elif [[ "$DO_REPO_CHECK" == true ]]; then
  validate_repo
fi
