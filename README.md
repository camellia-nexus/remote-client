# Camellia Remote Client

Secure cross-platform remote desktop software for Windows, macOS, Linux, Android, iOS, and Web. The Rust core owns transport, capture, input, clipboard, file transfer, and session security; Flutter provides the user interface.

Use Camellia Remote only on systems you own or are explicitly authorized to administer. Remote access without informed authorization can violate law and privacy.

## Product topology

- [`remote-protocol`](https://github.com/camellia-computing/remote-protocol): shared wire types, transport helpers, limits, and cryptographic configuration. This repository pins it as a submodule.
- [`remote-server`](https://github.com/camellia-computing/remote-server): identity/rendezvous and relay services.
- [`remote-management-server`](https://github.com/camellia-computing/remote-management-server): accounts, devices, policy, audit, plugin signing, and the commit-pinned Web client.

All four repositories start from clean root histories. Camellia Remote is prelaunch: only the current application identifiers and data layout are supported; obsolete development-build data is not migrated. Protocol parsing that remains in the runtime is a network safety/interoperability boundary, not a local data-compatibility promise.

## Development

Validated toolchains are Rust 1.99.1, Flutter 3.44.9, Node.js 24.22.1, and the locked package managers/dependencies in this repository. Apple CI and release builds use the `macos-26` hosted image with Xcode 26.2 selected through `DEVELOPER_DIR`; the workflow fails if that exact Xcode installation or its iPhoneOS/macOS SDKs are unavailable. Platform builds also require the native SDK, compiler, and vcpkg dependencies declared by CI.
The current Apple deployment baselines are iOS 13.0 and macOS 10.15. The
Apple Silicon slice uses its architecture floor, macOS 11.0, while the
x86_64 slice preserves the 10.15 product baseline. Rust, Flutter/Xcode,
CocoaPods, FFmpeg, and vcpkg derive their applicable minimum from this policy.
If a locked plugin requires a newer OS, raise the relevant baseline everywhere;
the required CI policy check rejects partial drift.

```bash
git submodule update --init --recursive
bash .github/scripts/prepare-dependencies.sh locked
bash .github/scripts/generate-bridge.sh
cargo check --workspace --all-targets --locked
cd flutter
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

Windows automation uses current PowerShell Core (`pwsh`), never Windows PowerShell. Packaging and signing commands must run under PowerShell 7.6+.

Useful component paths:

- `src/client.rs`, `src/server/`: peer and hosted-session behavior.
- `src/platform/`: OS integration and privilege boundaries.
- `libs/scrap`, `libs/enigo`, `libs/clipboard`: capture, input, and clipboard.
- `flutter/`: desktop, mobile, and Web interface.
- `docs/ui-design-system.md`: responsive, accessibility, session-control, and
  brand-asset UI contract.
- `.github/scripts/release_metadata.py`: the canonical release metadata validator.

## Security and data handling

- Pairing, session, file-transfer, clipboard, input, and proxy inputs are bounded and validated before resource allocation or filesystem access.
- Secrets and deployment endpoints must be supplied through the documented build/deployment trust channel; never commit private keys, access tokens, or customer configuration.
- Account login and deployment use one-use `camellia-device-proof-v1` challenges signed by the persistent Ed25519 device identity. Native clients use the existing persisted host key; Web keeps a per-browser signing identity in its encrypted local-secret envelope. Both clients validate the complete canonical purpose, challenge, rid, UUID, generation, public-key hash, and expiry before signing, so a configured Management endpoint cannot turn the device key into an arbitrary-message signing oracle. Enrolled-device login fails closed without current-key proof; a lost key requires an administrator's exact, ten-minute, one-use recovery approval.
- A managed host accepts incoming sessions only while it holds a bound Management heartbeat lease. The 60-second lease is renewed on the existing 15-second idle or 3-second active cadence, uses a monotonic local deadline, and rejects identity mismatch, generation rollback, or an excessive duration. Explicit disable/deletion revocation immediately closes direct, relay, file, terminal, and other active sessions, stops rendezvous registration and direct listening, and rejects connection races. Transient Management/network failures use the remaining lease as bounded grace and fail closed when it expires. `register-device=N` installations remain explicitly unmanaged and do not use this lease.
- Connection auditing uses Management protocol v3. The host serializes open, authorization, 20-second heartbeat, evidence, and close requests through one ordered 64-item queue that preserves two terminal slots; lifecycle requests reuse their UUIDv4 event ID for at most the 90-second lease window. Each logical audit event also binds that ID to `X-Camellia-Event-ID` and a stable W3C trace ID across retry, while every direct HTTP or TCP-proxy attempt gets a fresh span ID; caller-supplied correlation headers cannot override it. Controller lookup accepts only a matching v3 acknowledgement for an `active` lease. `closed`, pre-authorization `aborted`, and telemetry-lost `expired` sessions can never be returned as active or revived by a late heartbeat.
- File and Alarm evidence uses receipt protocol v1. Before its first attempt, the Client assigns a session-local reporter sequence and atomically persists the unchanged event ID, Management capability, URL, and bounded body in a checksummed, user-private 256-entry outbox; the bearer is never stored. Response loss retries the same record for a finite 90-second window, and the next process/connection resumes pending records only when their exact endpoint still belongs to the currently configured Management authority. Only a matching immutable acknowledgement, a permanent authority rejection, or expiry removes the record.
- The installed `camellia-remote-admin` control commands send a canonical UUID `Idempotency-Key` and print the exact operation ID and target before mutation. Replaying an ID requires the complete original request/generation snapshot; strategy assignment freezes every target generation. After restart, target deletion or inventory change, read the immutable receipt using `camellia-remote-admin operations --url <management-url> --token <bearer> --operation-id <uuid>` instead of replaying the write. Receipt retention is finite; a missing receipt is not proof of non-commit. A single-target ID is never reused across multiple matches, and only matching complete receipts count as success.
- Opt-in incoming-session recording upload uses only Management protocol v2. Before creating or mutating remote state, the Client persists a two-slot, checksummed sidecar containing the create/upload identity, committed offset/revision, and any pending chunk or finalize intent. Sidecars use mode 0600 on Unix and the recording directory's ACL on Windows; they contain no bearer token. Create, pending chunk/status, and terminal requests respectively use the persisted create, chunk, or upload UUID as their stable event/trace identity and generate a fresh span for each network attempt. Lost responses are resolved from Management status, and an advanced offset is accepted only when the server confirms the exact pending chunk ID, range, revision, length, and SHA-256 receipt. A completed local file is published remotely only after full-size and full-digest finalize succeeds; an interrupted recorder is aborted rather than presented as complete. The legacy header-overwrite `tail` protocol is intentionally unsupported.
- Desktop application data uses the `com.camellia.remote` identity. No old application directory is scanned or migrated.
- The application contains no version service or background updater and never
  discovers or downloads releases. Obtain an immutable reviewed Release,
  verify its checksum and signing evidence, then invoke the platform installer
  on that user-selected local package.
- Web assets embedded by the management server are accepted only from the full commit in `web-client.lock` after a successful client push CI run.

Report vulnerabilities through GitHub private vulnerability reporting as described in [SECURITY.md](SECURITY.md).

## Management CLI

Use the Client-owned Python package (`uv sync --locked`, then
`uv run --locked camellia-remote-admin --help`). Sources and tests live once in
`tools/admin-cli/`; the former `res/*.py` command paths are removed.
Management control commands expose typed nonzero outcomes, `--json` reports,
explicit `--allow-empty`, and frozen-target confirmation with `--yes`. Numeric
device RIDs/usernames are never guessed to be database identifiers; use
`guid:<identifier>` for strategy-assignment GUID selectors. See the
[CLI outcome contract](docs/admin-cli.md) before unattended administration.

## CI and release

Pull requests and `main` run pinned-action checks for metadata, dependencies, Rust, Flutter, Web, scripts, and platform-specific build contracts. The Apple required gate first resolves both committed Pod locks on the owning macOS runner and prints any exact lock drift before native compilation. It then compiles both the iOS Rust library and a complete unsigned iOS archive and rejects tracked or untracked build-time mutation of the checked-out source tree. Apple plugin resolution uses exactly CocoaPods 1.17.0 with committed iOS and macOS locks; project-level Swift Package Manager integration remains explicitly disabled until every plugin provides an immutable package graph. Xcode inherits plugin linkage from CocoaPods instead of hard-coding plugin frameworks, generated bridge sources are formatted before reuse, and the iOS host uses an application-owned C ABI link anchor instead of depending on a generated header that may validly be empty. The release workflow accepts only an exact commit reachable from the default branch and reuses artifacts from its successful full default-branch CI run: either the matching push run or a maintainer-dispatched matching CI run that executes every runtime, automation, and dependency gate.
Required CI also rejects any mismatch between the protocol submodule and the exact revision recorded in `SOURCE_PROVENANCE.json`.

Formal publication requires the protected `release` environment. Selected platform packages are produced once, checksummed, described by `versions.json`, and attested with GitHub/Sigstore identity. Windows Authenticode, macOS signing/notarization, Linux OpenPGP signatures, Android release keys, and iOS certificate/provisioning exports are optional complete groups; missing groups produce explicitly unsigned/ad-hoc or re-signing outputs and partial groups fail closed. Public packages should use a recognized publisher identity, but private or temporarily unsigned releases remain supported when their limitations are stated. See [release signing modes](docs/release-signing.md).

Versions are stable SemVer from the root manifest. Published tags and assets are immutable; rebuilding or moving an existing release is prohibited. See the [release policy](docs/releasing.md) for the complete release decision.

## Self-hosting

Deploy the server and management repositories by immutable OCI digest, configure TLS ingress, generate independent high-entropy server/device secrets, and keep database and service keys in encrypted backups. The initial target is single-region 99.9%, RPO ≤ 1 hour, and RTO ≤ 4 hours; those objectives require monitored hourly backups and tested restores, not only source configuration.

Client builds should inject only reviewed identity/relay/API origins and the matching server public key. A production HTTPS Web client must use WSS endpoints on the same trusted origin or an explicitly reviewed origin.

## License and provenance

This repository is licensed under GNU AGPL-3.0-only. Deploying a modified version over a network carries corresponding-source obligations. The exact imported snapshot, normalized repository, and protocol revision are recorded in [SOURCE_PROVENANCE.json](SOURCE_PROVENANCE.json); upstream RustDesk and other third-party copyright and license terms remain applicable as described in [NOTICE](NOTICE).
