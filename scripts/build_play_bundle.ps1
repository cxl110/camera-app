# Build the Google Play upload artifact.
#
#   powershell -File scripts\build_play_bundle.ps1
#
# Differences from a plain `flutter build appbundle`:
#   * PLAY_BUNDLE=1 drops x86_64 native libs (emulator-only ABI; TFLite's x86_64
#     prebuilts are still 4 KB page aligned and would fail Play's 16 KB check)
#   * --target-platform keeps Flutter from building Dart AOT for x86_64
#   * the finished bundle is re-inspected; the script fails if any 64-bit .so is
#     not 16 KB page aligned
#
# Requires android/key.properties + android/upload-keystore.jks (not in git).
# Without them Gradle silently falls back to the debug key and Play rejects it,
# so the signature is checked below.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$keyProps = Join-Path $repo "android\key.properties"
if (-not (Test-Path $keyProps)) {
    throw "android\key.properties is missing - the bundle would be debug-signed and Play would reject it."
}

$env:PLAY_BUNDLE = "1"
$env:Path = "C:\flutter\bin;" + $env:Path

flutter build appbundle --release --target-platform android-arm,android-arm64
if ($LASTEXITCODE -ne 0) { throw "flutter build appbundle failed" }

$aab = Join-Path $repo "build\app\outputs\bundle\release\app-release.aab"
if (-not (Test-Path $aab)) { throw "app-release.aab not found at $aab" }

python scripts\inspect_play_readiness.py
if ($LASTEXITCODE -ne 0) { throw "inspect_play_readiness.py failed" }

$jarsigner = Join-Path (Split-Path -Parent (Get-Command java).Source) "jarsigner.exe"
if (Test-Path $jarsigner) {
    # Exit code is the only locale-independent verdict: on a zh-CN JDK the
    # "jar verified." line comes back translated, so grepping for it fails.
    & $jarsigner -verify $aab | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "app-release.aab signature did not verify (jarsigner exit $LASTEXITCODE)" }
    Write-Host "signature verified" -ForegroundColor Green
} else {
    Write-Warning "jarsigner not found next to java - skipping signature check"
}

$mb = [math]::Round((Get-Item $aab).Length / 1MB, 1)
Write-Host "play bundle ready: $aab ($mb MB)" -ForegroundColor Green
