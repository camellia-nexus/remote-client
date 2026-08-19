# Windows CRT contract

Camellia Remote's MSVC Rust targets and native static dependencies use one
static C runtime. Release objects select `LIBCMT`; debug objects select
`LIBCMTD`. Static archives built with a dynamic CRT, such as a `static-md`
triplet, remain valid for development only when they select `MSVCRT` or
`MSVCRTD` consistently; they must never enter a static-CRT release build.

The repository-owned Opus overlay derives `OPUS_STATIC_RUNTIME` exclusively
from `VCPKG_CRT_LINKAGE`. Unknown Windows linkage values fail configuration,
and MinGW does not receive the MSVC-only option. Cargo enables `crt-static` for
all three declared MSVC targets. Linker suppression such as
`/NODEFAULTLIB:MSVCRT` is prohibited because it hides incorrectly compiled
objects instead of repairing them.

Required CI builds x64 and ARM64 Opus archives in isolated runner-temporary
vcpkg roots with binary caching disabled. Release builds check both release and
debug archives, reject `LNK4098`, `LNK4217`, and `LNK4286` in the Rust link log,
then reject dynamic Visual C++ CRT imports in `camellia_remote.dll`. The checks
are available locally through `.github/scripts/verify_windows_crt.py`; archive
and image commands locate `dumpbin.exe` through the active Visual Studio tools.

Changing the CRT contract requires rebuilding every native dependency from a
clean binary cache and validating the complete Windows payload. Rollback is a
single coordinated revert of the overlay, Cargo flags, verifier, and workflow
wiring. A release must remain blocked after rollback; warning suppression or
reuse of archives built under the other runtime is not a rollback strategy.
