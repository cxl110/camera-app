# Sign the HarmonyOS HAP with the OpenHarmony test PKI that ships with DevEco SDK.
#
#   powershell -File scripts\sign_ohos_hap.ps1
#
# Why this exists: `flutter build hap` only emits entry-default-unsigned.hap
# because ohos/build-profile.json5 has an empty signingConfigs list.
#
# IMPORTANT: the chain used here is the public OpenHarmony *test* root
# (toolchains/lib/OpenHarmony.p12). OpenHarmony devices and emulators accept it.
# A retail HarmonyOS NEXT phone does NOT: it only trusts profiles issued by
# Huawei for that account and bound to the device UDID. For a real Huawei phone,
# generate signing configs once in DevEco Studio (Signing Configs ->
# "Automatically generate signature", requires a Huawei ID + connected device)
# and then just run `flutter build hap --release`.
#
# English comments only: a BOM-less UTF-8 .ps1 is read as ANSI by PowerShell 5.1
# and Chinese text in it turns into mojibake.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$sdkLib = "C:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib"
$java = "C:\Huawei\DevEco Studio\jbr\bin\java.exe"
$signTool = Join-Path $sdkLib "hap-sign-tool.jar"
$keystore = Join-Path $sdkLib "OpenHarmony.p12"
$profileCert = Join-Path $sdkLib "OpenHarmonyProfileRelease.pem"
$storePwd = "123456"

foreach ($p in @($java, $signTool, $keystore, $profileCert)) {
    if (-not (Test-Path $p)) { throw "missing toolchain file: $p" }
}

$unsigned = Join-Path $repo "build\ohos\hap\entry-default-unsigned.hap"
if (-not (Test-Path $unsigned)) {
    throw "no unsigned HAP at $unsigned - run 'flutter build hap --release' first (see docs/HARMONYOS_BUILD.md)"
}

$out = Join-Path $repo "build\ohos\signing"
New-Item -ItemType Directory -Force -Path $out | Out-Null

Write-Host "1/4 building provision profile..." -ForegroundColor Cyan
python scripts\make_ohos_profile.py
if ($LASTEXITCODE -ne 0) { throw "make_ohos_profile.py failed" }

Write-Host "2/4 assembling app certificate chain..." -ForegroundColor Cyan
python scripts\build_ohos_cert_chain.py
if ($LASTEXITCODE -ne 0) { throw "build_ohos_cert_chain.py failed" }

$profileJson = Join-Path $out "sqcam-profile-release.json"
$p7b = Join-Path $out "sqcam.p7b"
$chain = Join-Path $out "app-chain.pem"

Write-Host "3/4 signing profile..." -ForegroundColor Cyan
& $java -jar $signTool sign-profile -mode localSign `
    -keyAlias "openharmony application profile release" -keyPwd $storePwd `
    -profileCertFile $profileCert -inFile $profileJson -signAlg SHA256withECDSA `
    -keystoreFile $keystore -keystorePwd $storePwd -outFile $p7b
if ($LASTEXITCODE -ne 0) { throw "sign-profile failed" }

Write-Host "4/4 signing HAP..." -ForegroundColor Cyan
$signed = Join-Path $repo "build\ohos\hap\entry-default-signed.hap"
& $java -jar $signTool sign-app -mode localSign `
    -keyAlias "openharmony application release" -keyPwd $storePwd `
    -appCertFile $chain -profileFile $p7b -inFile $unsigned -signAlg SHA256withECDSA `
    -keystoreFile $keystore -keystorePwd $storePwd -outFile $signed -compatibleVersion 12
if ($LASTEXITCODE -ne 0) { throw "sign-app failed" }

Write-Host "verifying..." -ForegroundColor Cyan
& $java -jar $signTool verify-app -inFile $signed `
    -outCertChain (Join-Path $out "verify-chain.cer") -outProfile (Join-Path $out "verify-profile.p7b")
if ($LASTEXITCODE -ne 0) { throw "verify-app failed" }

$mb = [math]::Round((Get-Item $signed).Length / 1MB, 1)
Write-Host "signed HAP ready: $signed ($mb MB)" -ForegroundColor Green
Write-Host "install with: hdc install $signed" -ForegroundColor Green
