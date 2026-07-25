# Build a release APK for Piposh 3D Alpha (Godot 4.7 Android export).
#
# Prerequisites:
#   1. Godot 4.7.x (same minor as project.godot / android/.build_version)
#   2. Android export templates installed (Editor → Manage Export Templates)
#   3. JDK 17+, Android SDK (Editor → Editor Settings → Export → Android)
#   4. Optional: set GODOT_PATH to Godot_v4.7*_win64.exe
#
# Usage (from repo root):
#   powershell -ExecutionPolicy Bypass -File tools\build_apk.ps1
#   powershell -File tools\build_apk.ps1 -Debug
#   powershell -File tools\build_apk.ps1 -Godot "C:\path\Godot_v4.7.1-stable_win64.exe"

param(
    [string]$Godot = "",
    [switch]$Debug,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

function Find-Godot {
    param([string]$Hint)
    if ($Hint -and (Test-Path $Hint)) { return (Resolve-Path $Hint).Path }
    if ($env:GODOT_PATH -and (Test-Path $env:GODOT_PATH)) { return $env:GODOT_PATH }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd4 = Get-Command godot4 -ErrorAction SilentlyContinue
    if ($cmd4) { return $cmd4.Source }

    # Prefer console binary for headless CI logs (WinGet Godot package).
    $wingetGodot = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine*" -Filter "Godot_v4*_console.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($wingetGodot) { return $wingetGodot.FullName }
    $wingetGodot2 = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine*" -Filter "Godot_v4*.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "console" } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($wingetGodot2) { return $wingetGodot2.FullName }

    $candidates = @(
        "$env:LOCALAPPDATA\Godot\*"
        "$env:ProgramFiles\Godot\*"
        "$env:ProgramFiles\Godot_*\*"
        "${env:ProgramFiles(x86)}\Godot\*"
        "$env:USERPROFILE\Downloads\Godot*"
        "$env:USERPROFILE\Desktop\Godot*"
        "C:\Godot\*"
        "D:\Godot\*"
        "E:\Godot\*"
    )
    foreach ($pat in $candidates) {
        $hits = @(Get-ChildItem -Path $pat -Filter "Godot*.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "4\.7" -and $_.Name -notmatch "console" } |
            Select-Object -First 3)
        if ($hits.Count -gt 0) { return $hits[0].FullName }
    }
    # Broader fallback (any Godot 4)
    foreach ($pat in $candidates) {
        $hits = @(Get-ChildItem -Path $pat -Filter "Godot_v4*.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch "console" } |
            Select-Object -First 1)
        if ($hits.Count -gt 0) { return $hits[0].FullName }
    }
    return $null
}

$godotExe = Find-Godot -Hint $Godot
if (-not $godotExe) {
    Write-Host @"
ERROR: Could not find Godot 4.7.

Install Godot 4.7.x, then either:
  - Add it to PATH as 'godot', or
  - Set GODOT_PATH to the .exe, or
  - Pass -Godot 'C:\path\to\Godot_v4.7.1-stable_win64.exe'

Also install Android export templates matching that Godot version
(Editor → Manage Export Templates) and configure the Android SDK
(Editor → Editor Settings → Export → Android).
"@ -ForegroundColor Red
    exit 1
}

Write-Host "Using Godot: $godotExe" -ForegroundColor Cyan

$presetPath = Join-Path $Root "export_presets.cfg"
if (-not (Test-Path $presetPath)) {
    Write-Host "Creating export_presets.cfg (Android)..." -ForegroundColor Yellow
    $presetBody = @'
[preset.0]

name="Android"
platform="Android"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="*.json, *.mdlanim, *.skins"
exclude_filter=""
export_path="build/android/Piposh3DAlpha.apk"
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.0.options]

custom_template/debug=""
custom_template/release=""
gradle_build/use_gradle_build=true
gradle_build/gradle_build_directory=""
gradle_build/android_source_template=""
gradle_build/compress_native_libraries=false
gradle_build/export_format=0
gradle_build/min_sdk=""
gradle_build/target_sdk=""
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
version/code=1
version/name="0.1.0"
package/unique_name="com.piposh.piposh3dalpha"
package/name="Piposh 3D Alpha"
package/signed=true
package/app_category=2
package/retain_data_on_uninstall=false
package/exclude_from_recents=false
launcher_icons/main_192x192=""
launcher_icons/adaptive_foreground_432x432=""
launcher_icons/adaptive_background_432x432=""
graphics/opengl_debug=false
xr_features/xr_mode=0
gesture/swipe_to_dismiss=false
screen/immersive_mode=true
screen/support_small=true
screen/support_normal=true
screen/support_large=true
screen/support_xlarge=true
user_data_backup/allow=false
command_line/extra_args=""
apk_expansion/enable=false
apk_expansion/SALT=""
apk_expansion/public_key=""
permissions/custom_permissions=PackedStringArray()
permissions/access_network_state=false
permissions/internet=false
permissions/vibrate=false
'@
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($presetPath, $presetBody, $utf8)
}

$outRoot = if ($OutDir) { $OutDir } else { Join-Path $Root "build\android" }
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
$apkName = if ($Debug) { "Piposh3DAlpha-debug.apk" } else { "Piposh3DAlpha.apk" }
$apkPath = Join-Path $outRoot $apkName

# Keep preset export_path in sync (UTF-8 **without** BOM — Godot rejects BOM presets).
$rel = "build/android/$apkName"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$presetText = [System.IO.File]::ReadAllText($presetPath)
# Strip accidental BOM from earlier PowerShell Set-Content runs.
if ($presetText.Length -gt 0 -and [int][char]$presetText[0] -eq 0xFEFF) {
    $presetText = $presetText.Substring(1)
}
$presetText = $presetText -replace 'export_path="[^"]*"', "export_path=`"$rel`""
[System.IO.File]::WriteAllText($presetPath, $presetText, $utf8NoBom)

$exportFlag = if ($Debug) { "--export-debug" } else { "--export-release" }
Write-Host "Exporting Android ($exportFlag) → $apkPath" -ForegroundColor Cyan

& $godotExe --path $Root --headless $exportFlag "Android" $apkPath
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host @"

Godot export failed (exit $code).

Checklist:
  1. Open the project once in the Godot editor (imports assets).
  2. Editor → Manage Export Templates → install 4.7.x templates.
  3. Project → Export → Android → fix any red errors (SDK / keystore).
  4. This project uses gradle_build (android/build). First export may
     download Gradle deps — needs network.

Then re-run: powershell -File tools\build_apk.ps1
"@ -ForegroundColor Red
    exit $code
}

if (Test-Path $apkPath) {
    $size = (Get-Item $apkPath).Length
    Write-Host "OK: $apkPath ($([math]::Round($size/1MB, 2)) MB)" -ForegroundColor Green
} else {
    # Gradle builds sometimes write under android/build/outputs
    $alt = Get-ChildItem -Path (Join-Path $Root "android") -Filter "*.apk" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($alt) {
        Copy-Item $alt.FullName $apkPath -Force
        Write-Host "OK (from gradle): $apkPath" -ForegroundColor Green
    } else {
        Write-Host "Export finished but APK not found at $apkPath" -ForegroundColor Yellow
        exit 2
    }
}
