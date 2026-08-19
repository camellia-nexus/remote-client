#!/usr/bin/env python3
"""Verify the Windows C/C++ runtime contract from source through the final DLL."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib


ROOT = Path(__file__).resolve().parents[2]
MAX_TOOL_OUTPUT = 8 * 1024 * 1024
MAX_LOG_SIZE = 16 * 1024 * 1024
DUMPBIN_TIMEOUT_SECONDS = 30
CRT_LIBRARIES = {"LIBCMT", "LIBCMTD", "MSVCRT", "MSVCRTD"}
EXPECTED_RUNTIME = {
    ("static", "release"): "LIBCMT",
    ("static", "debug"): "LIBCMTD",
    ("dynamic", "release"): "MSVCRT",
    ("dynamic", "debug"): "MSVCRTD",
}
LINKER_WARNING_CODES = ("LNK4098", "LNK4217", "LNK4286")
DYNAMIC_CRT_DEPENDENCY = re.compile(
    r"^(?:"
    r"VCRUNTIME\d+(?:_[A-Z0-9]+)*D?|"
    r"MSVCP\d+(?:_[A-Z0-9]+)*D?|"
    r"MSVCP_WIN|"
    r"MSVCR\d+D?|"
    r"CONCRT\d+D?|"
    r"VCCORLIB\d+D?|"
    r"UCRTBASE|"
    r"API-MS-WIN-CRT-[A-Z0-9-]+"
    r")\.DLL$",
    re.IGNORECASE,
)


class CrtPolicyError(ValueError):
    """A Windows CRT build boundary is missing, ambiguous, or inconsistent."""


def read_text(path: Path, *, limit: int = MAX_LOG_SIZE) -> str:
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise CrtPolicyError(f"cannot inspect {path}: {exc}") from exc
    if not path.is_file():
        raise CrtPolicyError(f"inspection input is not a file: {path}")
    if size > limit:
        raise CrtPolicyError(f"inspection input exceeds {limit} bytes: {path}")
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CrtPolicyError(f"cannot read {path}: {exc}") from exc


def workflow_job(workflow: str, job_name: str, source: str) -> str:
    match = re.search(
        rf"^  {re.escape(job_name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise CrtPolicyError(f"{source} is missing the {job_name} job")
    return match.group("body")


def require_once(text: str, value: str, source: str) -> None:
    count = text.count(value)
    if count != 1:
        raise CrtPolicyError(
            f"{source} must contain {value!r} exactly once, found {count}"
        )


def verify_opus_overlay(root: Path) -> None:
    port_path = root / "res/vcpkg/opus/portfile.cmake"
    port = read_text(port_path)
    runtime_block = """if(VCPKG_TARGET_IS_WINDOWS AND NOT VCPKG_TARGET_IS_MINGW)
    if(VCPKG_CRT_LINKAGE STREQUAL "static")
        list(APPEND ADDITIONAL_OPUS_OPTIONS "-DOPUS_STATIC_RUNTIME=ON")
    elseif(VCPKG_CRT_LINKAGE STREQUAL "dynamic")
        list(APPEND ADDITIONAL_OPUS_OPTIONS "-DOPUS_STATIC_RUNTIME=OFF")
    else()
        message(FATAL_ERROR "Unsupported Windows CRT linkage for Opus: ${VCPKG_CRT_LINKAGE}")
    endif()
endif()"""
    require_once(port, runtime_block, str(port_path.relative_to(root)))
    if port.count("OPUS_STATIC_RUNTIME") != 2:
        raise CrtPolicyError(
            "Opus overlay must contain only the guarded runtime option and error"
        )

    metadata_path = root / "res/vcpkg/opus/vcpkg.json"
    try:
        metadata = json.loads(read_text(metadata_path))
    except json.JSONDecodeError as exc:
        raise CrtPolicyError(f"invalid JSON in {metadata_path}: {exc}") from exc
    port_version = metadata.get("port-version")
    if not isinstance(port_version, int) or isinstance(port_version, bool):
        raise CrtPolicyError("Opus overlay must declare an integer port-version")
    if port_version < 1:
        raise CrtPolicyError("Opus overlay port-version must be at least 1")


def verify_cargo_config(root: Path) -> None:
    config_path = root / ".cargo/config.toml"
    try:
        config = tomllib.loads(read_text(config_path))
    except tomllib.TOMLDecodeError as exc:
        raise CrtPolicyError(f"invalid TOML in {config_path}: {exc}") from exc

    targets = config.get("target")
    if not isinstance(targets, dict):
        raise CrtPolicyError(".cargo/config.toml has no target table")
    for target in (
        "x86_64-pc-windows-msvc",
        "i686-pc-windows-msvc",
        "aarch64-pc-windows-msvc",
    ):
        values = targets.get(target)
        if not isinstance(values, dict):
            raise CrtPolicyError(f"Cargo config is missing the {target} target")
        rustflags = values.get("rustflags")
        if not isinstance(rustflags, list) or not all(
            isinstance(value, str) for value in rustflags
        ):
            raise CrtPolicyError(f"Cargo config has invalid rustflags for {target}")
        joined = " ".join(rustflags).upper()
        if "+CRT-STATIC" not in joined:
            raise CrtPolicyError(f"Cargo config must enable crt-static for {target}")
        if "NODEFAULTLIB" in joined:
            raise CrtPolicyError(
                f"Cargo config must not hide CRT conflicts with NODEFAULTLIB for {target}"
            )


def verify_ci_workflow(root: Path) -> None:
    source = ".github/workflows/ci.yml"
    workflow = read_text(root / source)
    native = workflow_job(workflow, "windows_native", source)
    for value in (
        "'x64-windows-static', 'arm64-windows-static'",
        "VCPKG_BINARY_SOURCES: clear",
        "doNotCache: true",
        "microsoft/setup-msbuild@",
        "python .github/scripts/verify_windows_crt.py source",
        '"opus:$triplet"',
        '"--x-buildtrees-root=$buildtrees"',
        "--clean-after-build",
        'throw "Refusing to reuse Opus build root: $workRoot"',
        "--linkage static --configuration release",
        "--linkage static --configuration debug",
    ):
        require_once(native, value, f"{source} windows_native")

    required = workflow_job(workflow, "required", source)
    for value in (
        "- windows_native",
        "WINDOWS_NATIVE_RESULT: ${{ needs.windows_native.result }}",
        'require_success "Windows native runner verification" "$WINDOWS_NATIVE_RESULT"',
    ):
        require_once(required, value, f"{source} required")


def verify_release_workflow(root: Path) -> None:
    source = ".github/workflows/release.yml"
    workflow = read_text(root / source)
    job = workflow_job(workflow, "build_windows", source)
    for value in (
        "VCPKG_DEFAULT_TRIPLET: x64-windows-static",
        "python .github/scripts/verify_windows_crt.py source",
        "--linkage static --configuration release",
        "--linkage static --configuration debug",
        "set -o pipefail",
        '2>&1 | tee "$RUNNER_TEMP/',
        'link-log --path "$RUNNER_TEMP/',
        "image --path flutter/build/windows/x64/runner/Release/camellia_remote.dll",
    ):
        require_once(job, value, f"{source} build_windows")


def verify_source(root: Path = ROOT) -> None:
    root = root.resolve()
    verify_opus_overlay(root)
    verify_cargo_config(root)
    verify_ci_workflow(root)
    verify_release_workflow(root)


def directive_runtimes(output: str) -> set[str]:
    runtimes: set[str] = set()
    for match in re.finditer(
        r"(?:/|-)DEFAULTLIB:(?:\"([^\"]+)\"|([^\s]+))",
        output,
        re.IGNORECASE,
    ):
        name = (match.group(1) or match.group(2)).strip().upper()
        if name.endswith(".LIB"):
            name = name[:-4]
        if name in CRT_LIBRARIES:
            runtimes.add(name)
    return runtimes


def verify_archive_output(output: str, linkage: str, configuration: str) -> None:
    expected = EXPECTED_RUNTIME[(linkage, configuration)]
    observed = directive_runtimes(output)
    if observed != {expected}:
        raise CrtPolicyError(
            f"archive must select only {expected}; observed CRT directives: "
            f"{sorted(observed) or ['<missing>']}"
        )


def verify_link_log_text(output: str) -> None:
    found = sorted(
        code for code in LINKER_WARNING_CODES if re.search(code, output, re.IGNORECASE)
    )
    if found:
        raise CrtPolicyError(f"link output contains forbidden CRT warnings: {found}")


def image_dependencies(output: str) -> set[str]:
    return {
        match.group(1).upper()
        for match in re.finditer(
            r"^\s*([A-Za-z0-9_.-]+\.dll)\s*$", output, re.MULTILINE | re.IGNORECASE
        )
    }


def verify_image_output(output: str) -> None:
    dependencies = image_dependencies(output)
    forbidden = sorted(
        dependency
        for dependency in dependencies
        if DYNAMIC_CRT_DEPENDENCY.fullmatch(dependency)
    )
    if forbidden:
        raise CrtPolicyError(
            f"static-CRT image imports dynamic Visual C++ runtime libraries: {forbidden}"
        )


def _existing_executable(path: Path | str | None) -> Path | None:
    if not path:
        return None
    candidate = Path(path).expanduser()
    try:
        candidate = candidate.resolve(strict=True)
    except OSError:
        return None
    return candidate if candidate.is_file() else None


def find_dumpbin(requested: str | None = None) -> Path:
    for candidate in (
        requested,
        os.environ.get("DUMPBIN"),
        shutil.which("dumpbin.exe"),
        shutil.which("dumpbin"),
    ):
        executable = _existing_executable(candidate)
        if executable is not None:
            return executable

    tool_roots: list[Path] = []
    vc_tools = os.environ.get("VCToolsInstallDir")
    if vc_tools:
        tool_roots.append(Path(vc_tools))

    vswhere_candidates: list[Path] = []
    for variable in ("ProgramFiles(x86)", "ProgramFiles"):
        base = os.environ.get(variable)
        if base:
            vswhere_candidates.append(
                Path(base) / "Microsoft Visual Studio/Installer/vswhere.exe"
            )
    for vswhere in vswhere_candidates:
        if not vswhere.is_file():
            continue
        command = [
            str(vswhere),
            "-latest",
            "-products",
            "*",
            "-property",
            "installationPath",
        ]
        try:
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=15,
                shell=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if completed.returncode != 0 or len(completed.stdout) > 32768:
            continue
        installation = completed.stdout.strip()
        if installation:
            tool_roots.extend(
                sorted(
                    (Path(installation) / "VC/Tools/MSVC").glob("*"), reverse=True
                )
            )

    relative_candidates = (
        "bin/Hostx64/x64/dumpbin.exe",
        "bin/Hostarm64/arm64/dumpbin.exe",
        "bin/Hostx86/x86/dumpbin.exe",
    )
    for root in tool_roots:
        for relative in relative_candidates:
            executable = _existing_executable(root / relative)
            if executable is not None:
                return executable
    raise CrtPolicyError(
        "dumpbin.exe was not found in PATH, VCToolsInstallDir, or Visual Studio"
    )


def run_dumpbin(tool: Path, option: str, input_path: Path) -> str:
    input_path = input_path.resolve()
    if not input_path.is_file():
        raise CrtPolicyError(f"dumpbin input is not a file: {input_path}")
    command = [str(tool), option, str(input_path)]
    with tempfile.TemporaryFile() as output:
        try:
            process = subprocess.Popen(
                command,
                stdout=output,
                stderr=subprocess.STDOUT,
                shell=False,
            )
            deadline = time.monotonic() + DUMPBIN_TIMEOUT_SECONDS
            while (returncode := process.poll()) is None:
                if os.fstat(output.fileno()).st_size > MAX_TOOL_OUTPUT:
                    process.kill()
                    process.wait()
                    raise CrtPolicyError(
                        f"dumpbin output exceeds {MAX_TOOL_OUTPUT} bytes"
                    )
                if time.monotonic() >= deadline:
                    process.kill()
                    process.wait()
                    raise CrtPolicyError(
                        f"dumpbin exceeded {DUMPBIN_TIMEOUT_SECONDS} seconds"
                    )
                time.sleep(0.05)
            if returncode is None:  # pragma: no cover - poll loop owns this invariant.
                process.kill()
                process.wait()
                raise CrtPolicyError("dumpbin did not produce an exit status")
        except OSError as exc:
            raise CrtPolicyError(f"cannot execute dumpbin: {exc}") from exc
        output.seek(0)
        data = output.read(MAX_TOOL_OUTPUT + 1)
    if len(data) > MAX_TOOL_OUTPUT:
        raise CrtPolicyError(f"dumpbin output exceeds {MAX_TOOL_OUTPUT} bytes")
    text = data.decode("utf-8", errors="replace")
    if returncode != 0:
        tail = text[-2000:].strip()
        raise CrtPolicyError(f"dumpbin exited with {returncode}: {tail}")
    return text


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    source = subparsers.add_parser("source", help="verify repository build policy")
    source.add_argument("--root", type=Path, default=ROOT)

    archive = subparsers.add_parser("archive", help="verify archive CRT directives")
    archive.add_argument("--path", type=Path, required=True)
    archive.add_argument("--linkage", choices=("static", "dynamic"), required=True)
    archive.add_argument(
        "--configuration", choices=("release", "debug"), required=True
    )
    archive.add_argument("--dumpbin")

    link_log = subparsers.add_parser("link-log", help="reject CRT linker warnings")
    link_log.add_argument("--path", type=Path, required=True)

    image = subparsers.add_parser("image", help="verify final PE dependencies")
    image.add_argument("--path", type=Path, required=True)
    image.add_argument("--dumpbin")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "source":
            verify_source(args.root)
            print("Windows CRT source policy is consistent")
        elif args.command == "archive":
            tool = find_dumpbin(args.dumpbin)
            output = run_dumpbin(tool, "/directives", args.path)
            verify_archive_output(output, args.linkage, args.configuration)
            print(
                f"Archive uses {EXPECTED_RUNTIME[(args.linkage, args.configuration)]}: "
                f"{args.path}"
            )
        elif args.command == "link-log":
            verify_link_log_text(read_text(args.path))
            print(f"Link output has no forbidden CRT warnings: {args.path}")
        elif args.command == "image":
            tool = find_dumpbin(args.dumpbin)
            verify_image_output(run_dumpbin(tool, "/dependents", args.path))
            print(f"Image has no dynamic Visual C++ CRT dependency: {args.path}")
        else:  # pragma: no cover - argparse owns this boundary.
            raise CrtPolicyError(f"unsupported command: {args.command}")
    except CrtPolicyError as exc:
        print(f"Windows CRT policy error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
