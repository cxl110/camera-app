<#
.SYNOPSIS
    Render the 1024x1024 App Store master icon to assets/icon.png.

.DESCRIPTION
    The product is a small, wide, titanium-shelled camera, so the icon is a
    compact rounded rectangle seen face-on: large lens, one flash window, two
    screws. Nothing else - details disappear below ~60px and make the icon look
    busy on the App Store grid.

    Titanium is a *warm, dark* grey-silver. Bright cold silver reads as plastic
    or aluminium at icon size, so the body uses a warm gunmetal ramp with a
    narrow specular band, and the background stays darker than the body in every
    variant so the silhouette survives the small sizes.

      dark   Titanium on the app's deep navy (default).
      light  Titanium on a soft warm-grey studio backdrop.
      metal  Titanium on a brushed metal plate (full-bleed).

    App Store constraints handled here:
      * no alpha channel in the master (24bpp bitmap) - transparency is rejected;
      * exactly 1024x1024.

    Usage:
      scripts/make_app_icon.ps1                                  # assets/icon.png
      scripts/make_app_icon.ps1 -Variant light -OutFile tmp/x.png

    Then `dart run flutter_launcher_icons` fans the master out to every size.
#>

[CmdletBinding()]
param(
    [ValidateSet('dark', 'light', 'metal')]
    [string]$Variant = 'dark',

    # >1 crops into the body (product-macro framing). 1.0 shows the whole camera.
    # 1.25 is the shipped framing: the body fills the tile but stays complete, so
    # the iOS corner mask never cuts through a bezel.
    [double]$Zoom = 1.25,

    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutFile) { $OutFile = Join-Path $repoRoot 'assets/icon.png' }

$size = 1024
# 24bpp = no alpha channel, which is what App Store Connect requires.
$bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

# ---------------------------------------------------------------- utilities --
function C([int]$r, [int]$g2, [int]$b, [int]$a = 255) {
    return [System.Drawing.Color]::FromArgb($a, $r, $g2, $b)
}

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Multi-stop gradient. The alternating bands are what reads as brushed metal:
# a two-stop ramp just looks like moulded plastic.
function New-StopsBrush([System.Drawing.Rectangle]$rect, [System.Drawing.Color[]]$colors, [single[]]$stops, [single]$angle) {
    $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $colors[0], $colors[$colors.Length - 1], $angle)
    $cb = New-Object System.Drawing.Drawing2D.ColorBlend($colors.Length)
    $cb.Colors = $colors
    $cb.Positions = $stops
    $b.InterpolationColors = $cb
    return $b
}

function New-SolidBrushC([System.Drawing.Color]$c) {
    return New-Object System.Drawing.SolidBrush($c)
}

# ------------------------------------------------------------- palettes ------
# Titanium ramp: cool enough to read as metal, warm enough to not read as chrome.
$ti = @((C 232 230 226), (C 186 183 178), (C 138 136 132), (C 170 167 162), (C 104 102 99), (C 142 139 135))
$tiStops = @(0.00, 0.14, 0.38, 0.52, 0.82, 1.00)

switch ($Variant) {
    'dark' {
        $bgA = C 12 14 19
        $bgB = C 30 34 45
        $bgGlow = C 56 189 248
        $bgGlowAlpha = 0
        $body = $ti
        $bodyStops = $tiStops
        $edge = C 74 72 69
        $shadowAlpha = 150
        $glass = @((C 96 196 240), (C 34 122 214), (C 16 44 120))
        $accent = C 255 138 76
    }
    'light' {
        $bgA = C 244 242 238
        $bgB = C 206 204 199
        $bgGlow = C 120 160 190
        $bgGlowAlpha = 0
        $body = $ti
        $bodyStops = $tiStops
        $edge = C 74 72 69
        $shadowAlpha = 110
        $glass = @((C 92 190 236), (C 32 116 208), (C 14 40 114))
        $accent = C 240 120 60
    }
    'metal' {
        $bgA = C 196 193 188
        $bgB = C 150 148 144
        $bgGlow = C 120 160 190
        $bgGlowAlpha = 0
        $body = @((C 246 245 242), (C 198 195 190), (C 148 145 141), (C 182 179 174), (C 112 110 106), (C 154 151 147))
        $bodyStops = $tiStops
        $edge = C 84 82 79
        $shadowAlpha = 130
        $glass = @((C 96 196 240), (C 34 122 214), (C 16 44 120))
        $accent = C 240 120 60
    }
}

# --------------------------------------------------------------- background --
$bgRect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
$g.FillRectangle((New-StopsBrush $bgRect @($bgA, $bgB) @(0.0, 1.0) 55), $bgRect)

# A single soft light source behind the body. Kept very low: anything stronger
# reads as a light leak around the silhouette rather than as lighting.
if ($bgGlowAlpha -gt 0) {
    $glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $glowPath.AddEllipse(210, 240, 620, 560)
    $glow = New-Object System.Drawing.Drawing2D.PathGradientBrush($glowPath)
    $glow.CenterColor = [System.Drawing.Color]::FromArgb($bgGlowAlpha, $bgGlow.R, $bgGlow.G, $bgGlow.B)
    $glow.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $bgGlow.R, $bgGlow.G, $bgGlow.B))
    $g.FillPath($glow, $glowPath)
}

# ------------------------------------------------------------- camera body --
# Fills most of the tile: the silhouette has to survive 40px, and a small body
# floating in a big field of background is what made the first attempt look
# generic. -Zoom > 1 crops into the body around the lens centre for a product
# macro framing (the sides run off the tile instead of leaving dead space).
if ($Zoom -ne 1.0) {
    $g.TranslateTransform(466.0, 578.0)
    $g.ScaleTransform([single]$Zoom, [single]$Zoom)
    $g.TranslateTransform(-466.0, -578.0)
}

$bodyW = 748
$bodyH = 486
$bodyX = ($size - $bodyW) / 2
$bodyY = 300
$bodyR = 92
$bodyRect = New-Object System.Drawing.Rectangle([int]$bodyX, [int]$bodyY, $bodyW, $bodyH)
$bodyPath = New-RoundedPath $bodyX $bodyY $bodyW $bodyH $bodyR

# Contact shadow. Offsets with decreasing alpha stack into a soft edge; drawing
# them at *the same size* matters, otherwise the outlines show up as ghost
# rectangles around the body.
for ($i = 5; $i -ge 1; $i--) {
    $sp = New-RoundedPath ($bodyX + 6) ($bodyY + 10 + $i * 3) $bodyW ($bodyH + $i * 2) $bodyR
    $a = [int]($shadowAlpha / ($i * 4.5))
    $g.FillPath((New-SolidBrushC (C 0 0 0 $a)), $sp)
    $sp.Dispose()
}

# The machined shell.
$g.FillPath((New-StopsBrush $bodyRect $body $bodyStops 62), $bodyPath)

# Cylindrical rounding + edge occlusion, clipped to the body.
$g.SetClip($bodyPath)
$shadeRect = $bodyRect
$shade = New-Object System.Drawing.Drawing2D.LinearGradientBrush($shadeRect, (C 255 255 255 0), (C 0 0 0 0), 90)
$scb = New-Object System.Drawing.Drawing2D.ColorBlend(4)
$scb.Colors = @((C 255 255 255 46), (C 255 255 255 6), (C 0 0 0 8), (C 0 0 0 78))
$scb.Positions = @(0.0, 0.24, 0.55, 1.0)
$shade.InterpolationColors = $scb
$g.FillRectangle($shade, $shadeRect)

# Fine vertical brushing. Nearly invisible on its own, but it stops the body
# from looking like a flat gradient when the icon is displayed at 1024px.
$brushPen = New-Object System.Drawing.Pen((C 255 255 255 8), 1.5)
for ($i = 0; $i -lt 300; $i++) {
    $x = $bodyX + ($i * ($bodyW / 300))
    $g.DrawLine($brushPen, [single]$x, [single]$bodyY, [single]$x, [single]($bodyY + $bodyH))
}
$g.ResetClip()

# Bevel: one gradient stroke around the path gives a lit top-left edge and a
# dark bottom-right edge in a single pass.
$bevelRect = $bodyRect
$bevelBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($bevelRect, (C 255 255 255 190), (C 30 28 26 150), 62)
$bevelCb = New-Object System.Drawing.Drawing2D.ColorBlend(4)
$bevelCb.Colors = @((C 255 255 255 190), (C 255 255 255 30), (C 70 66 62 60), (C 24 22 20 170))
$bevelCb.Positions = @(0.0, 0.35, 0.62, 1.0)
$bevelBrush.InterpolationColors = $bevelCb
$bevelPen = New-Object System.Drawing.Pen($bevelBrush, 6)
$g.DrawPath($bevelPen, $bodyPath)

# Crisp outer contour so the edge survives downscaling.
$contour = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(84, $edge.R, $edge.G, $edge.B), 3)
$g.DrawPath($contour, $bodyPath)

# --------------------------------------------------------------- top plate --
# Nothing here on purpose. A parting line across the face read as a scratch once
# the icon was scaled down; the bevel and the lens do that job already.

# -------------------------------------------------------------------- lens --
$lensCx = 466.0
$lensCy = 578.0
$lensR  = 172.0

# Barrel: dark machined ring, lit from the top.
$barrelPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$barrelPath.AddEllipse([single]($lensCx - $lensR), [single]($lensCy - $lensR), [single]($lensR * 2), [single]($lensR * 2))
$barrelRect = New-Object System.Drawing.Rectangle([int]($lensCx - $lensR), [int]($lensCy - $lensR), [int]($lensR * 2), [int]($lensR * 2))
$g.FillPath((New-StopsBrush $barrelRect @((C 96 93 89), (C 52 50 48), (C 26 25 24), (C 44 42 40)) @(0.0, 0.42, 0.78, 1.0) 62), $barrelPath)

# Barrel lip: a dim ring all the way round plus one brighter arc across the top,
# so the highlight does not end in a hard stop that reads as a scratch.
$lipDim = New-Object System.Drawing.Pen((C 255 255 255 34), 4)
$g.DrawEllipse($lipDim, [single]($lensCx - $lensR + 8), [single]($lensCy - $lensR + 8), [single]($lensR * 2 - 16), [single]($lensR * 2 - 16))
$lipPen = New-Object System.Drawing.Pen((C 255 255 255 96), 5)
$g.DrawArc($lipPen, [single]($lensCx - $lensR + 8), [single]($lensCy - $lensR + 8), [single]($lensR * 2 - 16), [single]($lensR * 2 - 16), 202, 136)

# Glass.
$glassR = 128
$glassRect = New-Object System.Drawing.Rectangle([int]($lensCx - $glassR), [int]($lensCy - $glassR), [int]($glassR * 2), [int]($glassR * 2))
$glassPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$glassPath.AddEllipse([single]($lensCx - $glassR), [single]($lensCy - $glassR), [single]($glassR * 2), [single]($glassR * 2))
$g.FillPath((New-StopsBrush $glassRect $glass @(0.0, 0.5, 1.0) 55), $glassPath)

# Aperture ring + the dark centre, so the glass has depth.
$g.DrawEllipse((New-Object System.Drawing.Pen((C 8 18 44 150), 14)), [single]($lensCx - 84), [single]($lensCy - 84), [single]168, [single]168)
$g.DrawEllipse((New-Object System.Drawing.Pen((C 6 14 36 170), 10)), [single]($lensCx - 54), [single]($lensCy - 54), [single]108, [single]108)

# Specular highlight, upper-left. One soft shape only: two overlapping ellipses
# read as a sticker rather than a reflection.
$hiPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$hiPath.AddEllipse([single]($lensCx - 100), [single]($lensCy - 112), [single]86, [single]72)
$hiBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($hiPath)
$hiBrush.CenterColor = (C 255 255 255 168)
$hiBrush.SurroundColors = @((C 255 255 255 22))
$g.FillPath($hiBrush, $hiPath)

# ------------------------------------------------------- flash and details --
# Flash window, right of the lens. Deliberately dimmer than the glass: a bright
# white pill competes with the lens and breaks the hierarchy.
$flashPath = New-RoundedPath 700 452 96 62 24
$g.FillPath((New-StopsBrush (New-Object System.Drawing.Rectangle(700, 452, 96, 62)) @((C 232 238 246), (C 168 176 188), (C 210 218 228)) @(0.0, 0.6, 1.0) 90), $flashPath)
$g.DrawPath((New-Object System.Drawing.Pen((C 48 46 44 150), 4)), $flashPath)

# Status LED: one warm dot gives the metal face a focal point.
$g.FillEllipse((New-SolidBrushC $accent), [single]728, [single]352, [single]20, [single]20)
$g.FillEllipse((New-SolidBrushC (C 255 255 255 170)), [single]733, [single]356, [single]8, [single]8)

# Two screws only: enough to read as machined, not busy at 40px.
foreach ($pt in @(@(238, 344), @(786, 344))) {
    $g.FillEllipse((New-SolidBrushC (C 108 105 101)), [single]($pt[0] - 12), [single]($pt[1] - 12), [single]24, [single]24)
    $g.FillEllipse((New-SolidBrushC (C 62 60 57)), [single]($pt[0] - 5), [single]($pt[1] - 5), [single]10, [single]10)
}

# ------------------------------------------------------------------- save --
$g.ResetTransform()
$g.Dispose()
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$info = Get-Item $OutFile
Write-Host "Wrote $($info.FullName) ($($info.Length) bytes, 1024x1024, no alpha, variant=$Variant)"
