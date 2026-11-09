# Web Client Build Guide

This directory contains the Flutter web entry (`index.html`, `manifest.json`,
favicon, icons) and the JS bridge toolchain under `web/js`.

## Directory layout
- `web/index.html`: Flutter web entrypoint and JS bridge bootstrap.
- `web/manifest.json`: PWA manifest.
- `web/js`: TypeScript bridge sources. Build output is `web/js/dist/web_bridge.js`.
- `web/tools/build_web.ps1`: Windows build helper.
- `web/tools/build_web.sh`: Linux/macOS build helper.

## What the scripts do
1. Bootstrap and verify the checksum-pinned optional web codec/runtime archive
   against `tools/web_codec_manifest.json` unless deps bootstrap is skipped.
2. Build the JS bridge in `web/js` (runs `check-web-build.mjs`) unless JS build is skipped.
3. Resolve Flutter packages with `flutter pub get --enforce-lockfile`.
4. Run `flutter build web` or `flutter run -d chrome`.
5. Record the exact Git revision and tracked-worktree state in
   `build/web/.source_revision` and emit a canonical `build/web/build_manifest.json`
   containing file-level SHA-256 digests and root tree digest.

Web builds never rewrite tracked launcher icons or favicon sources. Brand
artifacts have one reviewed geometry source. Refresh and verify them from the
repository root with:

```bash
cd flutter
dart run tool/generate_brand_assets.dart
cd ..
bash .github/scripts/verify-brand-assets.sh
```

Review and commit generated assets separately from runtime build output.

The scripts automatically pass these build-time values as `--dart-define` when
the environment variables are set:
- `RS_PUB_KEY`
- `RENDEZVOUS_SERVERS`
- `API_SERVER`
- `APP_NAME`
- `APP_VERSION`

`BUILD_DATE` can be supplied explicitly. Otherwise the scripts convert
`SOURCE_DATE_EPOCH` to UTC; when neither value is set they use the current Git
commit timestamp. Rebuilding the same clean revision therefore produces the
same embedded build date instead of the local wall-clock time.

## Parameters

### PowerShell
`build_web.ps1` accepts:
- `-Mode release|profile|debug`
- `-BaseHref PATH` (default: `/`)
- `-Run`
- `-SkipJs`
- `-SkipDeps`

### Bash
`build_web.sh` accepts:
- `--mode release|profile|debug`
- `--base-href PATH` (default: `/`)
- `--run`
- `--skip-js`
- `--skip-deps`

## Recommended usage

### Windows: build release package
Run this from the repository root:

```powershell
$env:RS_PUB_KEY='your_rs_pub_key'
$env:RENDEZVOUS_SERVERS='rs1.example.com:21116,rs2.example.com:21116'
$env:API_SERVER='https://api.example.com'
$env:APP_NAME='Example Remote Client'
$env:APP_VERSION='1.0.0'

.\flutter\web\tools\build_web.ps1 -Mode release
```

### Windows: run locally in Chrome

```powershell
$env:RS_PUB_KEY='your_rs_pub_key'
$env:RENDEZVOUS_SERVERS='rs1.example.com:21116'
$env:API_SERVER='https://api.example.com'
$env:APP_NAME='Example Remote Client'

.\flutter\web\tools\build_web.ps1 -Run
```

To run Chrome in release mode:

```powershell
.\flutter\web\tools\build_web.ps1 -Run -Mode release
```

### Windows: run local debug and write logs to a folder

```powershell
$logDir = ".\tmp\web-debug-run"
New-Item -ItemType Directory -Force $logDir | Out-Null

$env:RS_PUB_KEY='your_rs_pub_key'
$env:RENDEZVOUS_SERVERS='rs1.example.com:21116,rs2.example.com:21116'
$env:API_SERVER='https://api.example.com'
$env:APP_NAME='Example Remote Client'
$env:APP_VERSION='1.0.0'

.\flutter\web\tools\build_web.ps1 -Run -Mode debug *>&1 |
  Tee-Object -FilePath (Join-Path $logDir 'run-debug.log')
```

### Windows: build debug output and write logs to a folder

```powershell
$logDir = ".\tmp\web-debug-build"
New-Item -ItemType Directory -Force $logDir | Out-Null

$env:RS_PUB_KEY='your_rs_pub_key'
$env:RENDEZVOUS_SERVERS='rs1.example.com:21116,rs2.example.com:21116'
$env:API_SERVER='https://api.example.com'
$env:APP_NAME='Example Remote Client'
$env:APP_VERSION='1.0.0'

.\flutter\web\tools\build_web.ps1 -Mode debug *>&1 |
  Tee-Object -FilePath (Join-Path $logDir 'build-debug.log')
```

The debug build output still goes to `flutter/build/web`. The extra folder above
is only for captured console logs.

### Linux/macOS: build release package

```bash
export RS_PUB_KEY='your_rs_pub_key'
export RENDEZVOUS_SERVERS='rs1.example.com:21116,rs2.example.com:21116'
export API_SERVER='https://api.example.com'
export APP_NAME='Example Remote Client'
export APP_VERSION='1.0.0'

./flutter/web/tools/build_web.sh --mode release
```

### Linux/macOS: run locally in Chrome

```bash
export RS_PUB_KEY='your_rs_pub_key'
export RENDEZVOUS_SERVERS='rs1.example.com:21116'
export API_SERVER='https://api.example.com'

./flutter/web/tools/build_web.sh --run
```

## Skip flags

Use the skip flags only when the corresponding step has already been prepared.

Example:

```powershell
.\flutter\web\tools\build_web.ps1 -Mode release -SkipJs -SkipDeps
```

This means:
- `-SkipJs`: do not run `npm ci` or rebuild `web/js/dist/web_bridge.js`
- `-SkipDeps`: do not download optional codec/runtime assets

`-SkipJs`/`--skip-js` still requires an existing compiled
`web/js/dist/web_bridge.js`; dependency fallback from `npm ci` to `npm install`
is intentionally not supported.

## Local manual workflow

If you do not want to rely on the helper scripts, the manual flow is:

```powershell
bash flutter/web/tools/prepare_web_deps.sh
cd flutter/web/js
npm ci
npm run build
cd ../..
flutter pub get --enforce-lockfile
flutter build web --release --base-href /
```

When building manually, you must pass the same `--dart-define` values yourself
if your deployment depends on them.

## Environment variables

- `RS_PUB_KEY`: rendezvous public key.
- `RENDEZVOUS_SERVERS`: comma-separated rendezvous server list.
- `API_SERVER`: API server base URL.
- `APP_NAME`: optional web branding / app name override.
- `APP_VERSION`: optional version override. If unset, the script reads the
  version from `flutter/pubspec.yaml`.
- `BUILD_DATE`: explicit single-line build date override.
- `SOURCE_DATE_EPOCH`: reproducible UTC build timestamp used when `BUILD_DATE`
  is unset; defaults to the Git commit timestamp.
- `FLUTTER_BIN`: optional path to the Flutter executable if `flutter` is not in
  `PATH`.

## JS bridge artifacts

- `web/js/src/**` and `web/js/package-lock.json` are source files and should be committed.
- `web/js/node_modules/**` is an install artifact and should not be committed.
- `web/js/dist/web_bridge.js` is a generated artifact and should not be committed.

`web/js/dist/web_bridge.js` must exist before `flutter build web`.

## Optional codec/runtime assets

The bootstrap step may download these ignored assets into `flutter/web`. The
archive URL and SHA-256 are pinned in both build scripts, and its paths and link
types are validated before extraction:
- `ogvjs-*`
- `libopus.js`
- `libopus.wasm`
- `yuv-canvas-*.js`

These files are not source files and are not expected to be committed in the
default bootstrap workflow.

They are still relevant at runtime:
- If they are present, the web client can use the software video fallback path
  for browsers without WebCodecs support.
- If you build with `-SkipDeps` or `--skip-deps` and these files are not already
  present locally, the web client will still build, but that software fallback
  path will be unavailable.

## Notes

- The scripts can be invoked from the repository root with
  `.\flutter\web\tools\build_web.ps1` or `./flutter/web/tools/build_web.sh`.
- Both scripts require `package-lock.json` and use `npm ci`; they never mutate
  dependency locks during a build.
- The deps bootstrap step is skipped automatically when the expected local files
  are already present.
