# -----------------------------------------------------------------------------
# run_xsim_engine7.ps1 -- 7 乘法器引擎 + 声部层（modal_voice_top）的作业级比对
#
# 覆盖：4 条黄金向量（单声部逐位）、2 声部并行、A/B ping-pong（含运行中装载）。
#
# 用法：pwsh -File rtl/simsynth/tb/run_xsim_engine7.ps1
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
        (Join-Path $PSScriptRoot '..\modal_step_pkg.sv') `
        (Join-Path $PSScriptRoot '..\modal_engine7.sv') `
        (Join-Path $PSScriptRoot '..\modal_voice_top.sv') `
        tb_modal_voice_top.sv
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($LASTEXITCODE)" }

    Write-Output '--- xelab ---'
    & (Join-Path $VivadoBin 'xelab.bat') tb_modal_voice_top -s tb_vt --debug typical -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }

    Write-Output '--- xsim ---'
    & (Join-Path $VivadoBin 'xsim.bat') tb_vt -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}
