# -----------------------------------------------------------------------------
# run_xsim.ps1 -- 用 Vivado xsim 跑 string_mode_step 的黄金向量比对
#
# 用法：pwsh -File rtl/simsynth/tb/run_xsim.ps1
#
# 依赖：Vivado（默认 2017.4，用 -VivadoBin 覆盖）。脚本只在 xsim.dir 里留仿真产物。
# -----------------------------------------------------------------------------
param(
    [string]$VivadoBin = 'E:\Xilinx\Vivado\2017.4\bin'
)

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    foreach ($t in 'xvlog.bat', 'xelab.bat', 'xsim.bat') {
        if (-not (Test-Path (Join-Path $VivadoBin $t))) { throw "not found: $VivadoBin\$t" }
    }

    Write-Output '--- xvlog ---'
    & (Join-Path $VivadoBin 'xvlog.bat') -sv `
        (Join-Path $PSScriptRoot '..\..\math\pkg\fxp_pkg.sv') `
        (Join-Path $PSScriptRoot '..\..\math\pkg\fp_intf.sv') `
        (Join-Path $PSScriptRoot '..\modal_step_pkg.sv') `
        (Join-Path $PSScriptRoot '..\string_mode_step.sv') `
        tb_string_mode_step.sv
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($LASTEXITCODE)" }

    Write-Output '--- xelab ---'
    & (Join-Path $VivadoBin 'xelab.bat') tb_string_mode_step -s tb_sim --debug typical -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }

    Write-Output '--- xsim ---'
    & (Join-Path $VivadoBin 'xsim.bat') tb_sim -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}
