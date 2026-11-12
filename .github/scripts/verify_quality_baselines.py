#!/usr/bin/env python3
"""Quality baseline verification and enforcement tool for Camellia Remote Client (BUILD-001).

Enforces machine-readable quality baselines for:
1. Rust Clippy warnings: strict non-regression / zero-addition budget across workspace packages.
2. Flutter analyze issues: strict non-regression baseline recording exact count/fingerprints,
   with zero tolerance for new errors/warnings or unbudgeted info diagnostics.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any

CLIENT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CLIPPY_BASELINE = CLIENT_ROOT / ".github" / "config" / "clippy-baseline.json"
DEFAULT_FLUTTER_BASELINE = CLIENT_ROOT / ".github" / "config" / "flutter-analyze-baseline.json"
FLUTTER_DIR = CLIENT_ROOT / "flutter"


def run_command(cmd: list[str], cwd: Path) -> str:
    """Execute command and return stdout."""
    res = subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return res.stdout


def extract_package_short_name(pkg_id: str) -> str:
    """Extract human-readable short crate name from package_id."""
    if not pkg_id:
        return "unknown"
    if "#" in pkg_id:
        url_part, frag = pkg_id.split("#", 1)
        if "@" in frag:
            return frag.split("@", 1)[0]
        # If fragment is just a version (e.g. 0.5.0), name is last directory of url_part
        if not any(c.isalpha() for c in frag):
            clean_url = url_part.rstrip("/")
            return clean_url.split("/")[-1]
        return frag
    return pkg_id.split(" ", 1)[0]


def collect_clippy_diagnostics(raw_input: str | None = None) -> list[dict[str, Any]]:
    """Collect and normalize Clippy warnings for workspace packages."""
    if raw_input is None:
        cmd = [
            "cargo",
            "clippy",
            "--locked",
            "--workspace",
            "--all-targets",
            "--features",
            "flutter",
            "--message-format=json",
        ]
        raw_input = run_command(cmd, CLIENT_ROOT)

    warnings: list[dict[str, Any]] = []
    for line in raw_input.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue

        if payload.get("reason") != "compiler-message":
            continue

        message_obj = payload.get("message", {})
        if message_obj.get("level") != "warning":
            continue

        pkg_id = payload.get("package_id", "")
        pkg_name = extract_package_short_name(pkg_id)
        code_obj = message_obj.get("code") or {}
        code = code_obj.get("code") or "compiler_warning"

        spans = message_obj.get("spans", [])
        primary_spans = [s for s in spans if s.get("is_primary")]
        span = primary_spans[0] if primary_spans else (spans[0] if spans else {})

        file_name = span.get("file_name", "unknown")
        line_start = span.get("line_start", 0)
        col_start = span.get("column_start", 0)
        msg_text = message_obj.get("message", "")

        # Compute stable fingerprint: code:file:message
        fp_str = f"{code}:{file_name}:{msg_text}"
        fp_hash = hashlib.sha256(fp_str.encode("utf-8")).hexdigest()[:16]

        warnings.append({
            "package": pkg_name,
            "code": code,
            "file": file_name,
            "line": line_start,
            "column": col_start,
            "message": msg_text,
            "fingerprint": fp_hash,
        })

    return warnings


def collect_flutter_diagnostics(raw_input: str | None = None) -> list[dict[str, Any]]:
    """Collect and normalize Flutter/Dart analyze diagnostics."""
    if raw_input is None:
        cmd = ["dart", "analyze", "--format=json"]
        raw_input = run_command(cmd, FLUTTER_DIR)

    diagnostics: list[dict[str, Any]] = []
    try:
        data = json.loads(raw_input)
        raw_list = data.get("diagnostics", [])
    except json.JSONDecodeError as err:
        sys.stderr.write(f"Failed to parse Dart analyze JSON: {err}\n")
        return []

    for item in raw_list:
        code = item.get("code", "unknown")
        severity = item.get("severity", "UNKNOWN")
        dtype = item.get("type", "UNKNOWN")
        loc = item.get("location", {})
        full_file = loc.get("file", "")
        try:
            rel_file = os.path.relpath(full_file, start=FLUTTER_DIR)
        except ValueError:
            rel_file = full_file

        range_obj = loc.get("range", {}).get("start", {})
        line = range_obj.get("line", 0)
        col = range_obj.get("column", 0)
        msg_text = item.get("problemMessage", "")

        # Compute stable fingerprint: code:rel_file:problemMessage
        fp_str = f"{code}:{rel_file}:{msg_text}"
        fp_hash = hashlib.sha256(fp_str.encode("utf-8")).hexdigest()[:16]

        diagnostics.append({
            "code": code,
            "severity": severity,
            "type": dtype,
            "file": rel_file,
            "line": line,
            "column": col,
            "problemMessage": msg_text,
            "fingerprint": fp_hash,
        })

    return diagnostics


def build_clippy_baseline_payload(warnings: list[dict[str, Any]]) -> dict[str, Any]:
    """Construct structured Clippy baseline dictionary."""
    pkg_counts = Counter(w["package"] for w in warnings)
    code_counts = Counter(w["code"] for w in warnings)
    fps = sorted({w["fingerprint"] for w in warnings})

    return {
        "schema_version": 1,
        "description": "Camellia Remote Client Rust Clippy non-regression baseline (BUILD-001)",
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "command": "cargo clippy --locked --workspace --all-targets --features flutter",
        "total_allowed_warnings": len(warnings),
        "by_package": dict(sorted(pkg_counts.items())),
        "by_lint_code": dict(sorted(code_counts.items())),
        "total_unique_fingerprints": len(fps),
        "fingerprints": fps,
        "warnings": warnings,
    }


def build_flutter_baseline_payload(diags: list[dict[str, Any]]) -> dict[str, Any]:
    """Construct structured Flutter analyze baseline dictionary."""
    severity_counts = Counter(d["severity"] for d in diags)
    code_counts = Counter(d["code"] for d in diags)
    fps = sorted({d["fingerprint"] for d in diags})

    return {
        "schema_version": 1,
        "description": "Camellia Remote Client Flutter Analyze non-regression baseline (BUILD-001)",
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "command": "dart analyze --format=json",
        "total_allowed_issues": len(diags),
        "by_severity": dict(sorted(severity_counts.items())),
        "by_lint_code": dict(sorted(code_counts.items())),
        "total_unique_fingerprints": len(fps),
        "fingerprints": fps,
        "diagnostics": diags,
    }


def verify_clippy(baseline_path: Path, raw_input: str | None = None, verbose: bool = False) -> bool:
    """Verify Clippy warnings against committed baseline."""
    if not baseline_path.is_file():
        sys.stderr.write(f"[Clippy Gate] ERROR: Baseline file missing at {baseline_path}\n")
        return False

    with open(baseline_path, "r", encoding="utf-8") as f:
        baseline = json.load(f)

    allowed_total = baseline["total_allowed_warnings"]
    allowed_packages = baseline.get("by_package", {})
    allowed_codes = baseline.get("by_lint_code", {})

    print(f"[Clippy Gate] Analyzing current Rust workspace clippy warnings...")
    actual_warnings = collect_clippy_diagnostics(raw_input)
    actual_total = len(actual_warnings)
    actual_packages = Counter(w["package"] for w in actual_warnings)
    actual_codes = Counter(w["code"] for w in actual_warnings)

    print(f"[Clippy Gate] Total warnings: {actual_total} (allowed budget: {allowed_total})")

    violations: list[str] = []

    # 1. Total count check
    if actual_total > allowed_total:
        violations.append(
            f"Total Clippy warnings ({actual_total}) exceeded baseline budget ({allowed_total}) by {actual_total - allowed_total}!"
        )

    # 2. Package budget check
    for pkg, count in actual_packages.items():
        allowed_pkg = allowed_packages.get(pkg, 0)
        if count > allowed_pkg:
            violations.append(
                f"Package '{pkg}' warnings ({count}) exceeded allowed budget ({allowed_pkg}) by {count - allowed_pkg}!"
            )

    # 3. New lint codes / code budget check
    for code, count in actual_codes.items():
        allowed_code = allowed_codes.get(code, 0)
        if count > allowed_code:
            violations.append(
                f"Lint code '{code}' occurrences ({count}) exceeded allowed budget ({allowed_code}) by {count - allowed_code}!"
            )

    if violations:
        sys.stderr.write("[Clippy Gate] FAILED — Technical debt additions detected:\n")
        for v in violations:
            sys.stderr.write(f"  - {v}\n")
        baseline_fingerprints = {w.get("fingerprint") for w in baseline.get("warnings", [])}
        new_warnings = [w for w in actual_warnings if w.get("fingerprint") not in baseline_fingerprints]
        if new_warnings:
            sys.stderr.write("  Details of unbudgeted / new warnings:\n")
            for nw in new_warnings[:15]:
                sys.stderr.write(
                    f"    * [{nw.get('package')}] {nw.get('code')}: {nw.get('file')}:{nw.get('line')}:{nw.get('column')} - {nw.get('message')}\n"
                )
        return False

    if actual_total < allowed_total:
        print(
            f"[Clippy Gate] SUCCESS — Quality baseline improved! Warnings reduced from {allowed_total} to {actual_total} (-{allowed_total - actual_total})."
        )
        print("[Clippy Gate] To ratchet the budget down, run: python3 .github/scripts/verify_quality_baselines.py --update --clippy")
    else:
        print(f"[Clippy Gate] SUCCESS — All {actual_total} warnings are strictly within the budgeted baseline.")

    return True


def verify_flutter(baseline_path: Path, raw_input: str | None = None, verbose: bool = False) -> bool:
    """Verify Flutter analyze diagnostics against committed baseline."""
    if not baseline_path.is_file():
        sys.stderr.write(f"[Flutter Gate] ERROR: Baseline file missing at {baseline_path}\n")
        return False

    with open(baseline_path, "r", encoding="utf-8") as f:
        baseline = json.load(f)

    allowed_total = baseline["total_allowed_issues"]
    allowed_codes = baseline.get("by_lint_code", {})
    allowed_fps = set(baseline.get("fingerprints", []))

    print(f"[Flutter Gate] Analyzing Flutter Dart diagnostics...")
    actual_diags = collect_flutter_diagnostics(raw_input)
    actual_total = len(actual_diags)
    actual_severities = Counter(d["severity"] for d in actual_diags)
    actual_codes = Counter(d["code"] for d in actual_diags)
    actual_fps = {d["fingerprint"] for d in actual_diags}

    print(f"[Flutter Gate] Total issues: {actual_total} (allowed budget: {allowed_total})")
    print(f"[Flutter Gate] Severities: {dict(actual_severities)}")

    violations: list[str] = []

    # 1. Zero tolerance for ERROR or WARNING
    if actual_severities.get("ERROR", 0) > 0:
        violations.append(f"Found {actual_severities['ERROR']} fatal ERROR diagnostics! Zero tolerance required.")
    if actual_severities.get("WARNING", 0) > 0:
        violations.append(f"Found {actual_severities['WARNING']} fatal WARNING diagnostics! Zero tolerance required.")

    # 2. Total count check
    if actual_total > allowed_total:
        violations.append(
            f"Total Flutter issues ({actual_total}) exceeded baseline budget ({allowed_total}) by {actual_total - allowed_total}!"
        )

    # 3. New lint codes / code budget check
    for code, count in actual_codes.items():
        allowed_code = allowed_codes.get(code, 0)
        if count > allowed_code:
            violations.append(
                f"Lint code '{code}' occurrences ({count}) exceeded allowed budget ({allowed_code}) by {count - allowed_code}!"
            )

    # 4. Fingerprint additions check
    new_fps = actual_fps - allowed_fps
    if new_fps and actual_total >= allowed_total:
        violations.append(f"Detected {len(new_fps)} unbudgeted diagnostic fingerprints not present in baseline!")
        if verbose:
            for d in actual_diags:
                if d["fingerprint"] in new_fps:
                    violations.append(f"  * [{d['code']}] {d['file']}:{d['line']}:{d['column']} - {d['problemMessage']}")

    if violations:
        sys.stderr.write("[Flutter Gate] FAILED — Technical debt additions detected:\n")
        for v in violations:
            sys.stderr.write(f"  - {v}\n")
        return False

    if actual_total < allowed_total:
        print(
            f"[Flutter Gate] SUCCESS — Quality baseline improved! Issues reduced from {allowed_total} to {actual_total} (-{allowed_total - actual_total})."
        )
        print("[Flutter Gate] To ratchet the baseline down, run: python3 .github/scripts/verify_quality_baselines.py --update --flutter")
    else:
        print(f"[Flutter Gate] SUCCESS — All {actual_total} issues are strictly within the budgeted baseline.")

    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify and enforce quality baselines for Clippy and Flutter analyze (BUILD-001)."
    )
    parser.add_argument("--clippy", action="store_true", help="Verify Clippy warnings baseline.")
    parser.add_argument("--flutter", action="store_true", help="Verify Flutter analyze baseline.")
    parser.add_argument("--all", action="store_true", help="Verify all quality baselines (default).")
    parser.add_argument("--update", action="store_true", help="Generate or update baseline JSON file(s).")
    parser.add_argument(
        "--clippy-baseline",
        type=Path,
        default=DEFAULT_CLIPPY_BASELINE,
        help="Path to Clippy baseline JSON file.",
    )
    parser.add_argument(
        "--flutter-baseline",
        type=Path,
        default=DEFAULT_FLUTTER_BASELINE,
        help="Path to Flutter analyze baseline JSON file.",
    )
    parser.add_argument(
        "--clippy-input",
        type=str,
        default=None,
        help="Path to pre-collected Clippy JSON messages, or '-' for stdin.",
    )
    parser.add_argument(
        "--flutter-input",
        type=str,
        default=None,
        help="Path to pre-collected Dart analyze JSON, or '-' for stdin.",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose diagnostic output.")
    args = parser.parse_args()

    do_clippy = args.clippy or args.all or (not args.clippy and not args.flutter)
    do_flutter = args.flutter or args.all or (not args.clippy and not args.flutter)

    clippy_raw: str | None = None
    if args.clippy_input:
        if args.clippy_input == "-":
            clippy_raw = sys.stdin.read()
        else:
            clippy_raw = Path(args.clippy_input).read_text(encoding="utf-8")

    flutter_raw: str | None = None
    if args.flutter_input:
        if args.flutter_input == "-":
            flutter_raw = sys.stdin.read()
        else:
            flutter_raw = Path(args.flutter_input).read_text(encoding="utf-8")

    if args.update:
        if do_clippy:
            print(f"[Baseline Update] Collecting Clippy warnings...")
            warnings = collect_clippy_diagnostics(clippy_raw)
            payload = build_clippy_baseline_payload(warnings)
            args.clippy_baseline.parent.mkdir(parents=True, exist_ok=True)
            args.clippy_baseline.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            print(f"[Baseline Update] Wrote {len(warnings)} Clippy warnings to {args.clippy_baseline}")

        if do_flutter:
            print(f"[Baseline Update] Collecting Flutter analyze diagnostics...")
            diags = collect_flutter_diagnostics(flutter_raw)
            payload = build_flutter_baseline_payload(diags)
            args.flutter_baseline.parent.mkdir(parents=True, exist_ok=True)
            args.flutter_baseline.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            print(f"[Baseline Update] Wrote {len(diags)} Flutter diagnostics to {args.flutter_baseline}")

        return 0

    success = True
    if do_clippy:
        if not verify_clippy(args.clippy_baseline, clippy_raw, args.verbose):
            success = False

    if do_flutter:
        if not verify_flutter(args.flutter_baseline, flutter_raw, args.verbose):
            success = False

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
