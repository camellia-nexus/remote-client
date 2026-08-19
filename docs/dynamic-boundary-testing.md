# Dynamic boundary testing

The normal Required suite discovers the deterministic peer-ID mutation test and
the existing platform IPC/FFI unit tests where their target is supported. These
tests use fixed bounded input and remain part of the ordinary Rust test layer.

The scheduled `Dynamic Boundaries` workflow runs two Linux x86_64 targets:

- the Unix IPC filesystem tests exercise the production unsafe libc FFI across
  symlink, inode-replacement, owner, mode, and cleanup boundaries, with a
  separate ten-minute execution budget after compilation;
- the production portable archive parser runs under ASan/libFuzzer.

The fuzz job pins `nightly-2026-08-15`, `cargo-fuzz 0.13.2`, and an
independent fuzz lock file. The target accepts at most 64 KiB and runs for five
minutes. Committed seeds are copied to a private runner-temporary corpus, so
coverage discoveries cannot dirty the source checkout.

Only a crashing input is uploaded, for seven days. The target reads no
environment variables, credentials, raw logs, addresses, or user data, and the
artifact is bounded to 64 KiB. This Linux parser job does not replace real
Windows/macOS/Linux IPC, native FFI, or UI runtime tests.
