# -----------------------------------------------------------------------------
# run_xsim.ps1 -- rtl/math 新增算子与舍入变体的验证（Vivado xsim）
#   用法：pwsh -File rtl/math/tb/run_xsim.ps1
# -----------------------------------------------------------------------------
param(
    [string]$VivadoBin = 'E:\Xilinx\Vivado\2017.4\bin'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
$math = Join-Path $repo 'rtl\math'
$sim  = Join-Path $repo 'rtl\simsynth'

Push-Location $here
try {
    foreach ($t in 'xvlog.bat', 'xelab.bat', 'xsim.bat') {
        if (-not (Test-Path (Join-Path $VivadoBin $t))) { throw "not found: $VivadoBin\$t" }
    }

    Write-Output '--- xvlog ---'
    & (Join-Path $VivadoBin 'xvlog.bat') -sv `
        (Join-Path $math 'pkg\fxp_pkg.sv') `
        (Join-Path $math 'pkg\fp_intf.sv') `
        (Join-Path $math 'pkg\fp_ops.sv') `
        (Join-Path $sim  'modal_step_pkg.sv') `
        (Join-Path $here 'tb_fp_ops.sv')
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($LASTEXITCODE)" }

    Write-Output '--- xelab ---'
    & (Join-Path $VivadoBin 'xelab.bat') tb_fp_ops -s tb_fp --debug typical -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }

    Write-Output '--- xsim ---'
    & (Join-Path $VivadoBin 'xsim.bat') tb_fp -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}
