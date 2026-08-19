from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/dynamic-boundaries.yml"
FUZZ_MANIFEST = ROOT / "libs/portable/fuzz/Cargo.toml"
FUZZ_LOCK = ROOT / "libs/portable/fuzz/Cargo.lock"
FUZZ_TARGET = ROOT / "libs/portable/fuzz/fuzz_targets/portable_archive.rs"
DOCUMENTATION = ROOT / "docs/dynamic-boundary-testing.md"


workflow = WORKFLOW.read_text(encoding="utf-8")
required = (
    "NIGHTLY_TOOLCHAIN: nightly-2026-08-15",
    "cargo install cargo-fuzz --version 0.13.2 --locked",
    "fetch --locked --manifest-path libs/portable/fuzz/Cargo.toml",
    "cargo test --locked --lib --no-run",
    "timeout --signal=TERM --kill-after=30s 10m",
    "cargo test --locked --lib ipc::ipc_fs::tests -- --test-threads=1",
    '"$RUNNER_TEMP/portable-fuzz-corpus"',
    "cp -- libs/portable/fuzz/corpus/portable_archive/*",
    "-max_len=65536",
    "-max_total_time=300",
    "-rss_limit_mb=2048",
    "-runs=1000000",
    "-seed=20260819",
    "-timeout=5",
    "retention-days: 7",
)
missing = [marker for marker in required if marker not in workflow]
if missing:
    raise SystemExit(f"Client dynamic boundary workflow is incomplete: {missing}")
for forbidden in ("continue-on-error:", "|| true", "pull_request_target:"):
    if forbidden in workflow:
        raise SystemExit(f"Client dynamic boundary workflow contains forbidden marker: {forbidden}")
if workflow.count("timeout-minutes: 30") != 1 or workflow.count("timeout-minutes: 15") != 1:
    raise SystemExit("Client dynamic boundary job timeouts drifted")
if 'libfuzzer-sys = "0.4"' not in FUZZ_MANIFEST.read_text(encoding="utf-8"):
    raise SystemExit("Client portable fuzz manifest does not pin libFuzzer")
if 'name = "libfuzzer-sys"' not in FUZZ_LOCK.read_text(encoding="utf-8"):
    raise SystemExit("Client portable fuzz lock does not contain libFuzzer")
target = FUZZ_TARGET.read_text(encoding="utf-8")
if "const MAX_INPUT: usize = 64 * 1024;" not in target or "bin_reader::validate_archive(data)" not in target:
    raise SystemExit("Client portable fuzz target lost its production parser or input bound")
documentation = DOCUMENTATION.read_text(encoding="utf-8")
for marker in (
    "normal Required suite",
    "nightly-2026-08-15",
    "unsafe libc FFI",
    "64 KiB",
    "seven days",
    "reads no",
):
    if marker not in documentation:
        raise SystemExit(f"Client dynamic boundary documentation is incomplete: {marker}")
print("Client dynamic boundary policy passed")
