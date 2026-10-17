# -----------------------------------------------------------------------------
# run_all.ps1 -- 依次跑四套仿真，最后汇总 PASS/FAIL
#
# 用法：pwsh -File rtl/simsynth/tb/run_all.ps1
# -----------------------------------------------------------------------------
param(
    [string]$VivadoBin = 'E:\Xilinx\Vivado\2017.4\bin'
)

$ErrorActionPreference = 'Stop'
$fails = @()
foreach ($s in 'run_xsim.ps1', 'run_xsim_bank.ps1', 'run_xsim_ram.ps1', 'run_xsim_engine7.ps1') {
    Write-Output ''
    Write-Output "==================== $s ===================="
    $out = & pwsh -NoProfile -File (Join-Path $PSScriptRoot $s) -VivadoBin $VivadoBin 2>&1
    $out | Where-Object { $_ -match 'RESULT|=== |mismatch' } | ForEach-Object { $_ }
    if (-not ($out -match 'RESULT: PASS')) { $fails += $s }
}

Write-Output ''
if ($fails.Count -eq 0) { Write-Output 'ALL FOUR SUITES PASS' }
else {
    Write-Output ("FAILED: " + ($fails -join ', '))
    exit 1
}
