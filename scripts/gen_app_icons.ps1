<#
.SYNOPSIS
    Regenerate every App icon size from the master art, safely.

.DESCRIPTION
    Regenerating the iOS icons takes two steps and one repair:

      1. scripts/make_app_icon.ps1  -> renders assets/icon.png (1024, no alpha)
      2. dart run flutter_launcher_icons -> fans it out to AppIcon.appiconset
      3. repair -> flutter_launcher_icons also rewrites a build setting it has no
         business touching: it sets
             ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = AppIcon
         (confusing it with ASSETCATALOG_COMPILER_APPICON_NAME). The key expects
         YES/NO. Step 3 puts it back, so nobody has to remember this.

    Usage:
      scripts/gen_app_icons.ps1                     # dark variant, zoom 1.25
      scripts/gen_app_icons.ps1 -Variant light      # try a different direction
#>

[CmdletBinding()]
param(
    [ValidateSet('dark', 'light', 'metal')]
    [string]$Variant = 'dark',

    [double]$Zoom = 1.25,

    # Re-render the master from the script. Skip to only re-fan an existing PNG.
    [switch]$SkipMaster
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pbxproj = Join-Path $repoRoot 'ios/Runner.xcodeproj/project.pbxproj'
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not $SkipMaster) {
    # NOTE: $LASTEXITCODE is only set by native executables, not by PowerShell
    # scripts — use $? (and try/catch) or this always looks like a failure.
    try {
        & (Join-Path $PSScriptRoot 'make_app_icon.ps1') -Variant $Variant -Zoom $Zoom
        if (-not $?) { throw 'make_app_icon.ps1 reported an error' }
    }
    catch {
        throw "make_app_icon.ps1 failed: $_"
    }
}

Write-Host ''
Write-Host 'dart run flutter_launcher_icons'
Push-Location $repoRoot
try {
    & dart run flutter_launcher_icons 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'flutter_launcher_icons failed' }
}
finally {
    Pop-Location
}

# Repair the build setting the icon tool corrupts.
$text = [System.IO.File]::ReadAllText($pbxproj)
$fixed = $text -replace 'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = (?!YES;|NO;)[^;]+;', 'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;'
if ($fixed -ne $text) {
    [System.IO.File]::WriteAllText($pbxproj, $fixed, $utf8)
    Write-Host 'Repaired ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS -> YES'
}

# Fail loudly if anything else in the project is off.
$m = [regex]::Match($fixed, '(?m)^\s*PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
if (-not $m.Success) { throw 'Could not read PRODUCT_BUNDLE_IDENTIFIER from project.pbxproj' }
& (Join-Path $PSScriptRoot 'set_ios_signing.ps1') -BundleId $m.Groups[1].Value 2>&1 | Out-Host
