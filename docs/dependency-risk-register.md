# Dependency risk register

Review date: 2026-11-11
Owner: Remote security maintainers

## Enforcement

The root `Cargo.lock` is the only reviewed Rust resolution for this workspace.
CI and the scheduled security workflow run the pinned `cargo-audit` release
through `.github/scripts/audit_cargo_dependencies.py`. The gate fails on:

- every vulnerability;
- every unregistered unmaintained, unsound, or yanked warning;
- malformed or duplicate exceptions;
- an expired exception group.

The machine-readable exception set is
`.github/config/cargo-audit-policy.json`. It is a warning budget, not an
advisory ignore list: `cargo-audit` still reports every item, and any new item
fails CI. Resolved entries may be removed at any time.

Portable packaging pins its Python dependencies in `libs/portable/requirements.txt`.
The Python auditor has one version source in `requirements-audit.txt`, runs in an
isolated disposable environment, and checks both product CI and the scheduled
security workflow without importing the audited package. Requirement changes
also enter dependency review and weekly Dependabot updates. The Brotli 1.2.1
security patch fixes [GHSA-9v8h-qqgm-4m35](https://github.com/advisories/GHSA-9v8h-qqgm-4m35);
the archive format and Rust decoder remain unchanged.

Workspace-member lock files are forbidden because Cargo ignores them when a
member is built from the root. The stale `libs/virtual_display/Cargo.lock`
created false assurance and ten Dependabot alerts, including a high-severity
`mio` advisory, even though released builds used the safe root resolution. It
has been removed and CI prevents a nested lock from returning.

The obsolete `quest` example dependency and its `rpassword 2.1.0` chain were
also removed. The example now uses standard input directly.

## Time-bounded exceptions

| Group | Scope | Expiry | Compensating control and exit |
| --- | --- | --- | --- |
| `gtk3-stack-migration` | GTK3 unmaintained notices (`glib 0.18` unsound iterator advisory eliminated via in-tree audited patch) | 2027-02-28 | No direct `VariantStrIter` use exists in product code; in-tree patch fixes mutability bug in `VariantStrIter::impl_get`; native Linux tests remain required. Exit by migrating the complete desktop integration to a maintained GTK/GLib stack. |
| `inherited-transitive-modernization` | Exact reviewed warnings inherited through upstream media, windowing, code-generation, and text stacks (`atty` completely eliminated) | 2027-02-28 | Exact package, version, category, and advisory identities are frozen; any growth fails. Remove entries as their owning upstream chains are upgraded or replaced. |

Both `atty 0.2.14` (`RUSTSEC-2021-0145` / `RUSTSEC-2024-0375`) and `glib 0.18.5` unsoundness (`RUSTSEC-2024-0429`)
have been remediated in Batch 64 (`DEP-001`): `atty` and obsolete `bindgen 0.59.2` were purged by modernizing
`bindgen` to `0.71` across `magnum-opus` and `hwcodec`, and `glib` was patched with the upstream `VariantStrIter`
mutability fix in `libs/glib`. All unsound advisory exceptions have been eliminated from the cargo audit policy.
A formal release after an exception expiry is a no-go until the dependency is removed or a newly reviewed exception
with current evidence is approved.

New publication checks the release source's policy deadlines before building,
after protected-environment approval and immediately before making its draft
public. These standard-library checks do not rerun product CI or extend an
exception. The policy loaded from the trusted workflow commit must be unexpired
and explicitly cover every approved warning identity whose package and version
remain in the frozen lockfile; absent packages do not require renewed exceptions.
Recovery from reviewed `main` can use a newly approved policy for that same scope
without rewriting a tag or candidate; a changed dependency identity is not an
authorization for the frozen one. Read-only verification and completion of an
already published immutable release remain available after a deadline; they cannot publish new
bytes or replace existing assets.

## Supported dependency constraints

- iOS uses `whoami`'s platform-neutral backend because its Apple OS backend
  links a macOS-only computer-name API. Mobile user and device names come from
  Flutter's native device metadata, not this fallback. The feature is limited
  to the iOS target; desktop identity queries retain their native backends.
  Remove it when an upstream iOS backend links against the supported SDK.
- `libc` is limited to 0.2.189 by the shared protocol manifest. Newer bindings
  restrict `RTM_IFINFO2` to macOS, while the required `sysinfo` fork imports it
  in its iOS network backend. Its Linux process enumeration and file-descriptor
  limits also differ from current upstream `sysinfo`; replace that dependency
  only with equivalent process and privilege behavior proven on every platform.
  Keep the Apple native compilation gate and the unchanged vulnerability audit.
- `wol-rs` stays on the 1.0 patch line: 1.1 introduces `rustc-serialize`,
  which fails the vulnerability gate. Wake-on-LAN packet behavior is unchanged.
- The desktop URI handler currently requires `win32_registry` 2.x. The solver
  therefore retains compatible Win32 5.x, device-info 12.x, package-info 9.x,
  file-picker 11.x, wake-lock 1.x and desktop-drop 0.8.x releases. Win32 6.x
  and registry 3.x cannot be forced into this graph with overrides.
- Flutter stays on 3.44.9, the latest stable patch that preserves the product's
  iOS 13.0 and macOS 10.15 deployment floors. Flutter 3.47 requires iOS 15.0
  and macOS 12.0; changing those floors is not a dependency-only update.
  SDK-pinned packages follow the reviewed stable SDK resolution.
  Freezed 4 and flex-color-picker 4 require Dart 3.13; use their compatible
  3.x releases with the SDK's Dart 3.12 rather than raising deployment floors.
  Build-runner 2.17 requires analyzer 14, while resolved Freezed 3.2.5 requires
  analyzer 9 or 10; update both with their compatible Dart SDK rather than
  forcing an analyzer override. Vector-math follows the SDK's exact 2.2 pin.
  Ffigen 22+ requires `code_assets` 2; compatible native-toolchain-c versions
  then require meta 1.19, while this Flutter SDK pins meta 1.18. The actual Pub
  solver rejects ffigen 23 even though its direct meta range is broad; use 21.x
  until the complete SDK/toolchain graph resolves without overrides.
  The Rust bridge runtime, Dart runtime and generator are all exactly 2.13.0;
  generated sources are committed and verified together.
- Window-manager and multi-window Git packages pin reviewed commits. Their
  updates handle destroyed Linux windows and Windows resize/visibility recovery;
  required native jobs must compile both integrations before merge.
- Tray integration uses the maintained stable registry release, not a moving
  Git branch whose declared version can drift out of range. The macOS builder
  uses the current template-icon API; native Windows and Apple gates still
  validate the shared menu and icon integration.
- KCP pins `32a6c09`: the current upstream KCP 2 path removes bounded send
  segmentation and replaces fallible send/receive handling with panics. Advancing
  it requires preserving those controls and proving bounded large-frame exchange,
  cancellation and interoperability with supported peers, not just compilation.
- Hardware codecs pin `778df1f`: the 0.8 series replaces direct NVENC/AMF/MediaSDK
  VRAM implementations with FFmpeg paths and changes native SDK/build inputs.
  Advance the adapter and reviewed ports together only after native vendor-parity,
  fallback, bitrate and cleanup tests; ordinary non-GPU CI is not that evidence.

Session power protection uses owned native resources: a private connection and
file descriptor on Linux, and IOPM assertion IDs on macOS. The restart adapter
uses platform APIs without the unmaintained `zbus`/`zvariant` chains formerly
pulled by the power libraries. Linux tests use a private mock bus, exercise
partial acquisition cleanup and user cancellation, and never call a host power
service. Windows/macOS compilation is required; these tests do not request an
actual restart or prove host power policy behavior.

Apple tooling pins its JSON serializer in `.github/config/cocoapods-json-version`.
The `pod` launcher selects that exact gem before loading CocoaPods. Local podspec
checksums depend on JSON serialization, including empty-array formatting; relying
on the host Ruby's bundled JSON makes equivalent specs produce different locks.
Regenerate Pod locks with this launcher and keep the native lock-drift gate.

Dependabot reviews Dart generators and SDK-pinned packages as one toolchain
cohort, and the Win32/URI/platform plugins as another. Routine compatible packages
remain separately updatable. The groups do not ignore major versions or authorize
overrides: a new proposal on either side must recheck the complete dependency
chain and native platform floors before these constraints can be removed.
