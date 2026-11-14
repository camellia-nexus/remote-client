#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent
FLUTTER_DIR = ROOT / "flutter"


def run(cmd, cwd=ROOT, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    subprocess.run(cmd, cwd=cwd, env=merged_env, check=True)


def ensure_tool(name):
    if shutil.which(name) is None:
        raise SystemExit(f"Required tool is not available on PATH: {name}")


def resolve_source_date_epoch(explicit_epoch=None):
    if explicit_epoch:
        return str(explicit_epoch)
    if "SOURCE_DATE_EPOCH" in os.environ:
        return os.environ["SOURCE_DATE_EPOCH"]
    try:
        result = subprocess.run(
            ["git", "show", "-s", "--format=%ct", "HEAD"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        epoch = result.stdout.strip()
        if epoch.isdigit():
            return epoch
    except Exception:
        pass
    return None


def sync_version(version, build_number, source_date_epoch=None):
    cmd = ["bash", ".github/scripts/sync-version.sh", version, str(build_number)]
    if source_date_epoch is not None:
        cmd.append(str(source_date_epoch))
    run(cmd)


def prepare_dependencies(mode):
    run(["bash", ".github/scripts/prepare-dependencies.sh", mode])


def generate_bridge():
    run(["bash", ".github/scripts/generate-bridge.sh"])


def ensure_bridge(force=False):
    bridge_rs = ROOT / "src/bridge_generated.rs"
    bridge_h_ios = ROOT / "flutter/ios/Runner/bridge_generated.h"
    bridge_h_mac = ROOT / "flutter/macos/Runner/bridge_generated.h"
    bridge_dart = ROOT / "flutter/lib/generated_bridge.dart"

    missing = [
        str(p)
        for p in (bridge_rs, bridge_h_ios, bridge_h_mac, bridge_dart)
        if not p.is_file()
    ]
    if force or missing:
        generate_bridge()


def build_rust(features, target=None):
    cmd = ["cargo", "build", "--release", "--lib", "--features", features]
    if target:
        cmd[3:3] = ["--target", target]
    run(cmd)


def build_flutter(platform, extra_args):
    run(["flutter", "build", platform, "--release", *extra_args], cwd=FLUTTER_DIR)


def build_windows(args):
    build_rust("flutter,hwcodec,vram")
    build_flutter("windows", [])


def build_macos(args):
    build_rust("flutter,hwcodec,screencapturekit,unix-file-copy-paste")
    build_flutter("macos", [])


def build_linux(args):
    build_rust("flutter,hwcodec,unix-file-copy-paste")
    build_flutter("linux", [])


def build_android(args):
    ensure_tool("cargo")
    ensure_tool("flutter")
    android_env = {
        "BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android": "--target=aarch64-linux-android26 -D__ANDROID_API__=26",
    }
    run(
        [
            "cargo",
            "ndk",
            "--platform",
            "26",
            "--target",
            "arm64-v8a",
            "build",
            "--release",
            "--lib",
            "--features",
            "flutter,hwcodec",
        ],
        env=android_env,
    )
    jni_libs = FLUTTER_DIR / "android/app/src/main/jniLibs/arm64-v8a"
    jni_libs.mkdir(parents=True, exist_ok=True)
    # Remove stale legacy name if present
    legacy_so = jni_libs / "camellia_remote.so"
    if legacy_so.exists():
        legacy_so.unlink()
    shutil.copy2(
        ROOT / "target/aarch64-linux-android/release/libcamellia_remote.so",
        jni_libs / "libcamellia_remote.so",
    )
    ndk_home = os.environ.get("ANDROID_NDK_HOME") or os.environ.get("NDK_HOME")
    if ndk_home:
        cxx_candidates = list(
            Path(ndk_home).glob("**/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so")
        )
        if cxx_candidates:
            shutil.copy2(cxx_candidates[0], jni_libs / "libc++_shared.so")
    build_flutter("apk", ["--target-platform", "android-arm64"])
    build_flutter("appbundle", ["--target-platform", "android-arm64"])


def build_ios(args):
    build_rust("flutter", "aarch64-apple-ios")
    runner_dir = FLUTTER_DIR / "ios/Runner"
    runner_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "target/aarch64-apple-ios/release/libcamellia_remote.a",
        runner_dir / "camellia_remote.a",
    )
    build_flutter("ipa", ["--no-codesign"])


def build_web(args):
    build_script = FLUTTER_DIR / "web/tools/build_web.sh"
    run(["bash", str(build_script), "--mode", "release"])


BUILDERS = {
    "windows": build_windows,
    "macos": build_macos,
    "linux": build_linux,
    "android": build_android,
    "ios": build_ios,
    "web": build_web,
}


def main():
    parser = argparse.ArgumentParser(description="Build Camellia with the Flutter UI baseline.")
    parser.add_argument(
        "platform",
        choices=sorted(BUILDERS),
        help="Target platform to build.",
    )
    parser.add_argument("--version", default=None, help="Stable version to write before building.")
    parser.add_argument(
        "--build-number",
        default=None,
        help="Positive Flutter build number; required together with --version.",
    )
    parser.add_argument(
        "--dependency-mode",
        choices=["locked"],
        default="locked",
        help="Use committed dependency lockfiles.",
    )
    parser.add_argument(
        "--regenerate-bridge",
        action="store_true",
        help="Force regeneration of Flutter Rust Bridge even if generated files exist.",
    )
    parser.add_argument(
        "--skip-bridge",
        action="store_true",
        help="Skip Flutter Rust Bridge generation when generated files already exist.",
    )
    parser.add_argument(
        "--source-date-epoch",
        default=None,
        help="Deterministic build timestamp in seconds since epoch.",
    )
    args = parser.parse_args()

    ensure_tool("cargo")
    ensure_tool("flutter")
    epoch = resolve_source_date_epoch(args.source_date_epoch)
    if epoch:
        os.environ["SOURCE_DATE_EPOCH"] = epoch
    if (args.version is None) != (args.build_number is None):
        parser.error("--version and --build-number must be provided together")
    if args.version is not None:
        sync_version(args.version, args.build_number, epoch)
    prepare_dependencies(args.dependency_mode)
    if not args.skip_bridge:
        ensure_bridge(force=args.regenerate_bridge)
    BUILDERS[args.platform](args)


if __name__ == "__main__":
    main()
