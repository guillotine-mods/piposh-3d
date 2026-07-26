# Run pipeline contract checks (docs/CONTRACT.md).
$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

$failed = 0

function Invoke-Step([string]$Title, [scriptblock]$Block) {
    Write-Host "==> $Title" -ForegroundColor Cyan
    & $Block
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        Write-Host "FAIL: $Title (exit $LASTEXITCODE)" -ForegroundColor Red
        $script:failed++
    } else {
        Write-Host "OK: $Title" -ForegroundColor Green
    }
}

Invoke-Step "extract_wdl_meta" { python tools/extract_wdl_meta.py }
Invoke-Step "verify_mdl_facing" { python tools/verify_mdl_facing.py }
Invoke-Step "verify_entity_basis" { python tools/verify_entity_basis.py }
Invoke-Step "verify_feet_snap_policy" { python tools/verify_feet_snap_policy.py }
Invoke-Step "verify_level_pack --spine" { python tools/verify_level_pack.py --spine }
Invoke-Step "build_level_board" { python tools/build_level_board.py }

if (Test-Path "tools/verify_transforms.py") {
    Invoke-Step "verify_transforms" { python tools/verify_transforms.py }
}

if ($failed -gt 0) {
    Write-Host "`n$failed check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll checks passed." -ForegroundColor Green
exit 0
