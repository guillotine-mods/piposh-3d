# Build a Windows release EXE for Piposh 3D Alpha (Godot 4.7).
#
# Prerequisites:
#   1. Godot 4.7.x
#   2. Windows export templates installed (Editor → Manage Export Templates)
#
# Usage (from repo root):
#   powershell -ExecutionPolicy Bypass -File tools\build_exe.ps1
#   powershell -File tools\build_exe.ps1 -Godot "C:\path\Godot_v4.7.1-stable_win64.exe"

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
        "$env:USERPROFILE\Downloads\Godot*"
        "C:\Godot\*"
        "D:\Godot\*"
        "E:\Godot\*"
    )
    foreach ($pat in $candidates) {
        $hits = @(Get-ChildItem -Path $pat -Filter "Godot_v4*.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "4\.7" -and $_.Name -notmatch "console" } |
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

Also install Windows export templates matching that Godot version
(Editor → Manage Export Templates).
"@
    exit 1
}

Write-Host "Using Godot: $godotExe"

if (-not $OutDir) {
    $OutDir = Join-Path $Root "build\windows"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outExe = Join-Path $OutDir "Piposh3DAlpha.exe"

$mode = if ($Debug) { "--export-debug" } else { "--export-release" }
Write-Host "Exporting Windows Desktop ($mode) → $outExe"

# Import resources once so .glb/.import are ready, then export.
& $godotExe --headless --path $Root --import 2>&1 | Out-Host
$importCode = $LASTEXITCODE
if ($importCode -ne 0 -and $importCode -ne $null) {
    Write-Host "Note: editor import exited $importCode (continuing to export)"
}

& $godotExe --headless --path $Root $mode "Windows Desktop" $outExe 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host @"

Godot export failed (exit $LASTEXITCODE).

Checklist:
  1. Open the project once in the Godot editor (imports assets).
  2. Editor → Manage Export Templates → install 4.7.x templates.
  3. Project → Export → Windows Desktop preset exists.

Then re-run: powershell -File tools\build_exe.ps1
"@
    exit $LASTEXITCODE
}

if (-not (Test-Path $outExe)) {
    Write-Host "ERROR: Export reported success but $outExe was not created."
    exit 1
}

$sizeMb = [math]::Round((Get-Item $outExe).Length / 1MB, 1)
Write-Host ""
Write-Host "OK: $outExe ($sizeMb MB)"
Get-ChildItem $OutDir | Format-Table Name, Length -AutoSize
