<#
.SYNOPSIS
    Set the iOS Bundle ID, Apple Developer Team ID and device family in the
    Xcode project. Idempotent: safe to run again with different values.

.DESCRIPTION
    Xcode keeps these values in ios/Runner.xcodeproj/project.pbxproj in three
    build configurations (Debug/Release/Profile) for the Runner target plus
    three more for RunnerTests. Editing them by hand is where people usually
    break the project file, so this script does the whole set at once and
    validates that the expected number of edits happened.

    It also drops a matching ios/ExportOptions.plist for `xcodebuild -exportArchive`
    / `flutter build ipa`, which is what actually uploads to App Store Connect.

.PARAMETER BundleId
    Reverse-DNS identifier, e.g. com.zivigo.cameraapp. Must be unique inside
    your developer account. Cannot be changed after the first App Store release.

.PARAMETER TeamId
    10-character Apple Developer Team ID (Apple Developer portal -> Membership).
    Leave empty to keep whatever is currently in the project.

.PARAMETER DeviceFamily
    1 = iPhone only, 2 = iPad only, "1,2" = universal. Default 1.

.EXAMPLE
    pwsh scripts/set_ios_signing.ps1 -BundleId com.zivigo.cameraapp -TeamId ABCDE12345

.EXAMPLE
    # Change the bundle id only (team id stays as-is)
    pwsh scripts/set_ios_signing.ps1 -BundleId com.acme.cameraapp
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]*$')]
    [string]$BundleId,

    [ValidatePattern('^[A-Z0-9]{10}$')]
    [string]$TeamId,

    [ValidateSet('1', '2', '1,2')]
    [string]$DeviceFamily = '1'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pbxproj = Join-Path $repoRoot 'ios/Runner.xcodeproj/project.pbxproj'
$exportOptions = Join-Path $repoRoot 'ios/ExportOptions.plist'

if (-not (Test-Path $pbxproj)) {
    throw "Not found: $pbxproj"
}

$original = [System.IO.File]::ReadAllText($pbxproj)
$text = $original

# ---------------------------------------------------------------- bundle id --
# Matches the Runner target value (exactly, so RunnerTests is not touched while
# we are still renaming) and the RunnerTests value.
$runnerPattern = 'PRODUCT_BUNDLE_IDENTIFIER = [^;]+;(\s*\r?\n\s*PRODUCT_NAME = "\$\(TARGET_NAME\)";\s*\r?\n\s*SWIFT_OBJC_BRIDGING_HEADER)'
$matches = [regex]::Matches($text, $runnerPattern)
if ($matches.Count -ne 3) {
    throw "Expected 3 Runner build configurations, found $($matches.Count). Aborting so the project file is left untouched."
}

$text = [regex]::Replace($text, $runnerPattern, "PRODUCT_BUNDLE_IDENTIFIER = $BundleId;`$1")

# RunnerTests is not needed for App Store builds, but keep it consistent so
# Xcode does not complain about a missing Test Host.
$text = [regex]::Replace(
    $text,
    'PRODUCT_BUNDLE_IDENTIFIER = [^;]*\.RunnerTests;',
    "PRODUCT_BUNDLE_IDENTIFIER = $BundleId.RunnerTests;")

# ------------------------------------------------------------- device family --
$text = [regex]::Replace($text, 'TARGETED_DEVICE_FAMILY = [^;]+;', "TARGETED_DEVICE_FAMILY = `"$DeviceFamily`";")

# ------------------------------------------------------------------ signing --
# Rewrite the signing settings from scratch so repeated runs are idempotent:
# drop every existing DEVELOPMENT_TEAM / CODE_SIGN_STYLE line first, then put
# back exactly one of each where it belongs.
$text = [regex]::Replace($text, '[ \t]*DEVELOPMENT_TEAM = [^;]+;\r?\n', '')
$text = [regex]::Replace($text, '[ \t]*CODE_SIGN_STYLE = [^;]+;\r?\n', '')

$signingLines = 'CODE_SIGN_STYLE = Automatic;'
if ($TeamId) { $signingLines = "CODE_SIGN_STYLE = Automatic;`n`$1DEVELOPMENT_TEAM = $TeamId;" }

# Runner target: the three configs whose product is the app itself.
$text = [regex]::Replace(
    $text,
    "(?m)^(\s*)PRODUCT_BUNDLE_IDENTIFIER = $([regex]::Escape($BundleId));",
    "`$1$signingLines`n`$1PRODUCT_BUNDLE_IDENTIFIER = $BundleId;")

# RunnerTests target: keep it consistent so Xcode does not complain about a
# missing test host bundle id.
$text = [regex]::Replace(
    $text,
    "(?m)^(\s*)PRODUCT_BUNDLE_IDENTIFIER = $([regex]::Escape("$BundleId.RunnerTests"));",
    "`$1$signingLines`n`$1PRODUCT_BUNDLE_IDENTIFIER = $BundleId.RunnerTests;")

# ------------------------------------------------------------------- write --
if ($text -ne $original) {
    # UTF8 without BOM: Xcode writes plain UTF-8 and a BOM confuses the parser.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($pbxproj, $text, $utf8)
    Write-Host "Updated $pbxproj"
}
else {
    Write-Host "No changes needed in $pbxproj"
}

# ------------------------------------------------------------------ validate --
# `dart run flutter_launcher_icons` rewrites this key's *value* to "AppIcon"
# (it confuses it with ASSETCATALOG_COMPILER_APPICON_NAME). The key expects
# YES/NO, so catch it here instead of shipping a weird archive setting.
$badAssetSymbol = Select-String -Path $pbxproj -Pattern 'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = (?!YES;|NO;)' -ErrorAction SilentlyContinue
if ($badAssetSymbol) {
    throw "project.pbxproj has a corrupt ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS value (usually left behind by flutter_launcher_icons). Set every occurrence back to YES; and re-run."
}

$broken = $false
for ($i = 0; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq [char]0) { $broken = $true; break }
}
if ($broken) { throw 'project.pbxproj contains NUL bytes — restore it from git.' }

# --------------------------------------------------------- ExportOptions.plist --
if (-not $TeamId) {
    Write-Warning 'No -TeamId given: ios/ExportOptions.plist not written. Signing in Xcode will still work, but `flutter build ipa` needs it.'
}
else {
    $plist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Generated by scripts/set_ios_signing.ps1 - regenerate instead of editing. -->
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store</string>
	<key>teamID</key>
	<string>$TeamId</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>destination</key>
	<string>upload</string>
</dict>
</plist>
"@
    [System.IO.File]::WriteAllText($exportOptions, $plist, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $exportOptions"
}

Write-Host ''
Write-Host 'Current values:'
Select-String -Path $pbxproj -Pattern 'PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|TARGETED_DEVICE_FAMILY|CODE_SIGN_STYLE' |
    ForEach-Object { '  ' + $_.Line.Trim() } |
    Sort-Object -Unique
