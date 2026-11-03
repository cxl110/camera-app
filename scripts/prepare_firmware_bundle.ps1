# Prepares the firmware bundle for a field-service (OTA) build.
#
#   .\scripts\prepare_firmware_bundle.ps1 -Source C:\H3\APP\firmware
#
# Expects the three artifacts produced by the firmware repo's build_firmware.sh:
#
#   <Source>\manifest.json   {"version":"V0.5-20261031","boot_size":4102144,"rootfs_size":5496938}
#   <Source>\boot.img        Android boot image (starts with "ANDROID!")
#   <Source>\rootfs.img      root filesystem image
#
# They are validated and copied into assets/firmware/, which is gitignored.
# A single Allwinner "IMAGEWTY" full-flash .img is NOT accepted: that container
# wraps the partition images with an undocumented header, and hand-splitting it is
# how you brick a camera. Get boot.img/rootfs.img from the build machine's
# out/v821/perf2b/openwrt/ directory instead.
[CmdletBinding()]
param(
    [string]$Source = 'C:\H3\APP\firmware',
    [string]$Dest
)

$ErrorActionPreference = 'Stop'
# NB: $PSScriptRoot is still empty while a param default is evaluated, so a default
# built from it collapses to "<drive>:\assets\firmware". Resolve it here instead.
if ([string]::IsNullOrWhiteSpace($Dest)) {
    $Dest = Join-Path $PSScriptRoot '..\assets\firmware'
}
$Dest = [System.IO.Path]::GetFullPath($Dest)
function Say($m) { Write-Host $m }

Say "source: $Source"
if (-not (Test-Path $Source)) { throw "source directory not found: $Source" }

$manifestPath = Join-Path $Source 'manifest.json'
$bootPath     = Join-Path $Source 'boot.img'
$rootfsPath   = Join-Path $Source 'rootfs.img'

$missing = @()
foreach ($p in @($manifestPath, $bootPath, $rootfsPath)) {
    if (-not (Test-Path $p)) { $missing += (Split-Path $p -Leaf) }
}

if ($missing.Count -gt 0) {
    Say ""
    Say "缺少文件: $($missing -join ', ')"
    Say ""
    $imgs = Get-ChildItem $Source -Filter *.img -ErrorAction SilentlyContinue
    if ($imgs) {
        Say "目录里只有整包容器："
        $imgs | ForEach-Object { Say ("  {0}  ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
        Say ""
        Say "整包是 Allwinner LiveSuit 容器（IMAGEWTY），不是 OTA 用的分区镜像。"
        Say "请从固件编译机取这三个文件："
        Say "  SDK/out/v821/perf2b/openwrt/manifest.json"
        Say "  SDK/out/v821/perf2b/openwrt/boot.img"
        Say "  SDK/out/v821/perf2b/openwrt/rootfs.img"
        Say ""
        Say "放到 $Source 后重跑本脚本。"
    }
    exit 1
}

# ── validate ──
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$bootInfo = Get-Item $bootPath
$rootfsInfo = Get-Item $rootfsPath

Say ""
Say "manifest:"
Say "  version     : $($manifest.version)"
Say "  boot_size   : $($manifest.boot_size)"
Say "  rootfs_size : $($manifest.rootfs_size)"
Say "actual:"
Say ("  boot.img    : {0} bytes ({1:N2} MB)" -f $bootInfo.Length, ($bootInfo.Length / 1MB))
Say ("  rootfs.img  : {0} bytes ({1:N2} MB)" -f $rootfsInfo.Length, ($rootfsInfo.Length / 1MB))

$problems = @()
if ($bootInfo.Length -ne [int64]$manifest.boot_size) {
    $problems += "manifest.boot_size ($($manifest.boot_size)) != actual boot.img size ($($bootInfo.Length))"
}
if ($rootfsInfo.Length -ne [int64]$manifest.rootfs_size) {
    $problems += "manifest.rootfs_size ($($manifest.rootfs_size)) != actual rootfs.img size ($($rootfsInfo.Length))"
}
if ([string]::IsNullOrWhiteSpace($manifest.version)) {
    $problems += "manifest.version is empty"
}
if ($manifest.version -notmatch '^V\d+\.\d+-\d{8}$') {
    $problems += "manifest.version '$($manifest.version)' does not look like V<major>.<minor>-<YYYYMMDD>"
}

# boot.img must be an Android boot image; a wrong file here bricks the camera.
$head = New-Object byte[] 8
$fs = [System.IO.File]::OpenRead($bootPath)
try { $null = $fs.Read($head, 0, 8) } finally { $fs.Close() }
$magic = [System.Text.Encoding]::ASCII.GetString($head)
if ($magic -ne 'ANDROID!') {
    $problems += "boot.img does not start with 'ANDROID!' (found '$magic') — refusing to bundle"
}

if ($problems.Count -gt 0) {
    Say ""
    Say "校验失败:"
    $problems | ForEach-Object { Say "  - $_" }
    exit 1
}

# ── copy ──
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Copy-Item $manifestPath $Dest -Force
Copy-Item $bootPath     $Dest -Force
Copy-Item $rootfsPath   $Dest -Force

Say ""
Say "已就绪 -> $((Resolve-Path $Dest).Path)"
Get-ChildItem $Dest -File | Where-Object { $_.Name -ne '.gitkeep' } |
    ForEach-Object { Say ("  {0,-14} {1,12:N0} bytes" -f $_.Name, $_.Length) }
Say ""
Say "下一步（内测包，OTA 按钮可见）:"
Say "  bash scripts/build_adhoc_ios.sh --dev-tools"
