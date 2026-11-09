param(
  [ValidateSet('release', 'profile', 'debug')]
  [string]$Mode = 'release',
  [string]$BaseHref = '/',
  [switch]$Run,
  [switch]$SkipJs,
  [switch]$SkipDeps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Command {
  param([string]$Name, [string]$Hint)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing '$Name'. $Hint"
  }
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code $LASTEXITCODE`: $Command $($Arguments -join ' ')"
  }
}

function Test-WebDepsValid {
  param(
    [Parameter(Mandatory = $true)][string]$WebDir,
    [Parameter(Mandatory = $true)][string]$ManifestPath
  )
  if (-not (Test-Path -Path $ManifestPath -PathType Leaf)) {
    return $false
  }
  try {
    $manifest = Get-Content -Path $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest.files) {
      return $false
    }
    foreach ($prop in $manifest.files.PSObject.Properties) {
      $relPath = $prop.Name.Replace('/', [IO.Path]::DirectorySeparatorChar)
      $targetFile = Join-Path $WebDir $relPath
      if (-not (Test-Path -Path $targetFile -PathType Leaf)) {
        return $false
      }
      $item = Get-Item -Path $targetFile
      if ($item.Length -ne $prop.Value.size) {
        return $false
      }
      $actualHash = (Get-FileHash -Path $targetFile -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualHash -ne $prop.Value.sha256.ToLowerInvariant()) {
        return $false
      }
    }
    return $true
  }
  catch {
    return $false
  }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$flutterRoot = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
Set-Location $flutterRoot

$flutter = $env:FLUTTER_BIN
if ([string]::IsNullOrWhiteSpace($flutter)) {
  $flutter = 'flutter'
}
Ensure-Command $flutter "Install Flutter and ensure it is in PATH, or set FLUTTER_BIN."

$webDir = Join-Path $flutterRoot 'web'
$webJsDir = Join-Path $webDir 'js'
$webJsPkg = Join-Path $webJsDir 'package.json'
$webJsLock = Join-Path $webJsDir 'package-lock.json'
$repoRoot = (Resolve-Path (Join-Path $flutterRoot '..')).Path
$pubspecPath = Join-Path $flutterRoot 'pubspec.yaml'
$codecManifestPath = Join-Path $scriptDir 'web_codec_manifest.json'

$webDepsUrl = 'https://github.com/rustdesk/doc.rustdesk.com/releases/download/console/web_deps.tar.gz'
$webDepsSha256 = 'b66011c4fc066b90c46ba0c78884fe5d1a7e5a7fad3dce401300ad893de63818'

if (Test-Path -Path $codecManifestPath -PathType Leaf) {
  try {
    $parsedManifest = Get-Content -Path $codecManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($parsedManifest.archive -and $parsedManifest.archive.url) {
      $webDepsUrl = $parsedManifest.archive.url
    }
    if ($parsedManifest.archive -and $parsedManifest.archive.sha256) {
      $webDepsSha256 = $parsedManifest.archive.sha256.ToLowerInvariant()
    }
  }
  catch {
    # Keep fallback pinned defaults
  }
}

$appVersion = $env:APP_VERSION
$appName = $env:APP_NAME
if ([string]::IsNullOrWhiteSpace($appVersion) -and (Test-Path $pubspecPath)) {
  $versionLine = Select-String -Path $pubspecPath -Pattern '^\s*version:\s*(.+)\s*$' | Select-Object -First 1
  if ($versionLine) {
    $appVersion = $versionLine.Matches[0].Groups[1].Value.Trim()
  }
}

$requiredWebAssets = @(
  'index.html',
  'manifest.json',
  'favicon.svg',
  'favicon.png',
  'icons\Icon-192.png',
  'icons\Icon-512.png',
  'icons\Icon-maskable-192.png',
  'icons\Icon-maskable-512.png'
)
foreach ($requiredAsset in $requiredWebAssets) {
  $requiredPath = Join-Path $webDir $requiredAsset
  if (-not (Test-Path -Path $requiredPath -PathType Leaf)) {
    throw "Missing web asset: $requiredPath"
  }
}

# 1. Prepare and verify codec dependencies with SHA-256 validation BEFORE JS build
if (-not $SkipDeps) {
  if (Test-WebDepsValid -WebDir $webDir -ManifestPath $codecManifestPath) {
    Write-Host "Web codec assets verified against web_codec_manifest.json, skipping download."
  }
  else {
    Ensure-Command tar 'Install tar to extract the checksum-verified web codec archive.'
    $depsTar = Join-Path $webDir ".web-deps.$([Guid]::NewGuid().ToString('N')).tar.gz"
    Write-Host "Downloading web deps: $webDepsUrl"
    try {
      Invoke-WebRequest -Uri $webDepsUrl -OutFile $depsTar
      $actualSha256 = (Get-FileHash -Path $depsTar -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualSha256 -ne $webDepsSha256) {
        throw "Web deps checksum mismatch: expected $webDepsSha256, got $actualSha256"
      }

      $archiveEntries = & tar -tzf $depsTar
      if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the web deps archive.'
      }
      foreach ($entry in $archiveEntries) {
        if (
          $entry.StartsWith('/') -or
          $entry -match '(^|/)\.\.($|/)' -or
          $entry -notmatch '^(ogvjs-1\.8\.6/|libopus\.js$|libopus\.wasm$|yuv-canvas-1\.2\.6\.js$)'
        ) {
          throw "Web deps archive contains an unsafe or unexpected path: $entry"
        }
      }
      $verboseEntries = & tar -tvzf $depsTar
      if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect web deps archive entry types.'
      }
      if ($verboseEntries | Where-Object { $_ -match '^[lh]' }) {
        throw 'Web deps archive must not contain symbolic or hard links.'
      }

      Invoke-Checked -Command 'tar' -Arguments @('-xzf', $depsTar, '-C', $webDir)

      if (-not (Test-WebDepsValid -WebDir $webDir -ManifestPath $codecManifestPath)) {
        throw "Web codec assets failed manifest verification after extraction."
      }
    }
    finally {
      if (Test-Path $depsTar) {
        Remove-Item $depsTar -Force
      }
    }
  }
}

# 2. Resolve Flutter packages
Invoke-Checked -Command $flutter -Arguments @('pub', 'get', '--enforce-lockfile')

# 3. Build JS bridge (check-web-build.mjs will verify bundle against OGV codec assets)
if (-not $SkipJs) {
  if (-not (Test-Path $webJsPkg)) {
    throw "Missing '$webJsPkg'. Add the web JS bridge toolchain, or use -SkipJs."
  }
  if (-not (Test-Path $webJsLock)) {
    throw "Missing '$webJsLock'. Web builds require the committed npm lockfile."
  }
  Ensure-Command npm "Install Node.js (npm) to build web JS dependencies."
  Push-Location $webJsDir
  try {
    Invoke-Checked -Command 'npm' -Arguments @('ci', '--no-fund', '--no-audit')
    Invoke-Checked -Command 'npm' -Arguments @('run', 'build')
  }
  finally {
    Pop-Location
  }
}

$compiledBridge = Join-Path $webJsDir 'dist\web_bridge.js'
if (-not (Test-Path -Path $compiledBridge -PathType Leaf)) {
  throw "Missing compiled JS bridge: $compiledBridge"
}

# 4. Flutter build web
$buildDate = $env:BUILD_DATE
if ([string]::IsNullOrWhiteSpace($buildDate)) {
  $sourceDateEpoch = $env:SOURCE_DATE_EPOCH
  if ([string]::IsNullOrWhiteSpace($sourceDateEpoch)) {
    Ensure-Command git 'Install Git or set SOURCE_DATE_EPOCH explicitly.'
    $sourceDateEpoch = (& git -C $repoRoot show -s --format=%ct HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
      throw 'Unable to read the source commit timestamp.'
    }
  }
  [long]$parsedEpoch = 0
  if (-not [long]::TryParse($sourceDateEpoch, [ref]$parsedEpoch) -or $parsedEpoch -lt 0) {
    throw 'SOURCE_DATE_EPOCH must be a non-negative integer.'
  }
  $env:SOURCE_DATE_EPOCH = $parsedEpoch.ToString()
  $buildDate = [DateTimeOffset]::FromUnixTimeSeconds($parsedEpoch).UtcDateTime.ToString("yyyy-MM-dd HH:mm 'UTC'")
}
if ($buildDate.Contains("`n") -or $buildDate.Contains("`r")) {
  throw 'BUILD_DATE must be a single line.'
}

function Get-SetState {
  param([AllowEmptyString()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return 'unset' }
  return 'set'
}

Write-Host "Web build configuration: mode=$Mode base_href=$BaseHref run=$Run version=$appVersion build_date=$buildDate"
Write-Host "Endpoint configuration: RS_PUB_KEY=$(Get-SetState $env:RS_PUB_KEY) RENDEZVOUS_SERVERS=$(Get-SetState $env:RENDEZVOUS_SERVERS) API_SERVER=$(Get-SetState $env:API_SERVER) APP_NAME=$(Get-SetState $env:APP_NAME)"

$flutterArgs = @()
if ($Run) {
  $flutterArgs = @("run", "-d", "chrome", "-v")
  if ($Mode -eq 'release') {
    $flutterArgs += "--release"
  }
  elseif ($Mode -eq 'profile') {
    $flutterArgs += "--profile"
  }
}
else {
  $flutterArgs = @("build", "web", "--$Mode", "--no-wasm-dry-run")
  if (-not [string]::IsNullOrWhiteSpace($BaseHref)) {
    $flutterArgs += "--base-href=$BaseHref"
  }
  if ($Mode -eq 'release') {
    $flutterArgs += '--csp'
  }
}
if (-not [string]::IsNullOrWhiteSpace($env:RS_PUB_KEY)) {
  $flutterArgs += "--dart-define=RS_PUB_KEY=$($env:RS_PUB_KEY)"
}
if (-not [string]::IsNullOrWhiteSpace($env:RENDEZVOUS_SERVERS)) {
  $flutterArgs += "--dart-define=RENDEZVOUS_SERVERS=$($env:RENDEZVOUS_SERVERS)"
}
if (-not [string]::IsNullOrWhiteSpace($env:API_SERVER)) {
  $flutterArgs += "--dart-define=API_SERVER=$($env:API_SERVER)"
}
if (-not [string]::IsNullOrWhiteSpace($appName)) {
  $flutterArgs += "--dart-define=APP_NAME=$appName"
}
if (-not [string]::IsNullOrWhiteSpace($appVersion)) {
  $flutterArgs += "--dart-define=APP_VERSION=$appVersion"
}
$flutterArgs += "--dart-define=BUILD_DATE=$buildDate"

Invoke-Checked -Command $flutter -Arguments $flutterArgs

if (-not $Run) {
  $flutterBootstrap = Join-Path $flutterRoot 'build\web\flutter_bootstrap.js'
  if (-not (Test-Path $flutterBootstrap)) {
    throw 'Incomplete Flutter web build configuration.'
  }
  $bootstrapContent = Get-Content -Path $flutterBootstrap -Raw
  if ($bootstrapContent -notmatch '"compileTarget":"dart2js"') {
    throw 'Incomplete Flutter web build configuration.'
  }
  if ($bootstrapContent -match '"builds":\[[^\]]*(?:\{\},|,\{\})') {
    throw 'Flutter web build contains an empty target configuration.'
  }

  Ensure-Command git 'Install Git to record build provenance.'
  $sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $sourceRevision -notmatch '^[0-9a-f]{40,64}$') {
    throw 'Unable to determine the source revision.'
  }
  $trackedChanges = (& git -C $repoRoot status --porcelain --untracked-files=no) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw 'Unable to determine the source worktree state.'
  }
  $sourceState = if ([string]::IsNullOrWhiteSpace($trackedChanges)) { 'clean' } else { 'dirty' }
  $sourceRevisionPath = Join-Path $flutterRoot 'build\web\.source_revision'
  [IO.File]::WriteAllText(
    $sourceRevisionPath,
    "$sourceRevision $sourceState`n",
    [Text.UTF8Encoding]::new($false)
  )

  # Generate canonical build_manifest.json
  $webBuildDir = Join-Path $flutterRoot 'build\web'
  $manifestFiles = @{}
  $allFiles = Get-ChildItem -Path $webBuildDir -File -Recurse
  foreach ($file in $allFiles) {
    $rel = $file.FullName.Substring($webBuildDir.Length).TrimStart('\', '/').Replace('\', '/')
    if ($rel -eq '.source_revision' -or $rel -eq 'build_manifest.json') {
      continue
    }
    $sha = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestFiles[$rel] = @{
      size = $file.Length
      sha256 = $sha
    }
  }
  [string[]]$sortedKeys = @($manifestFiles.Keys)
  [Array]::Sort($sortedKeys, [System.StringComparer]::Ordinal)
  $digestLines = $sortedKeys | ForEach-Object { "$_`:$($manifestFiles[$_].size)`:$($manifestFiles[$_].sha256)" }
  $rawDigestString = $digestLines -join "`n"
  $hasher = [Security.Cryptography.SHA256]::Create()
  $rootDigestBytes = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($rawDigestString))
  $rootDigest = ($rootDigestBytes | ForEach-Object { $_.ToString('x2') }) -join ''

  $orderedFiles = [ordered]@{}
  foreach ($key in $sortedKeys) {
    $orderedFiles[$key] = $manifestFiles[$key]
  }

  $buildManifest = [ordered]@{
    schema_version = 1
    source_revision = $sourceRevision
    source_state = $sourceState
    base_href = $BaseHref
    root_digest = $rootDigest
    files = $orderedFiles
  }
  $manifestJson = ConvertTo-Json -InputObject $buildManifest -Depth 4
  [IO.File]::WriteAllText(
    (Join-Path $webBuildDir 'build_manifest.json'),
    "$manifestJson`n",
    [Text.UTF8Encoding]::new($false)
  )
}
