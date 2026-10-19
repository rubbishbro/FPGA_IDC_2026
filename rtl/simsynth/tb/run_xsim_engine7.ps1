param([string]$VivadoBin = "E:\Xilinx\Vivado\2017.4\bin")
$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot
try {
    foreach ($t in 'xvlog.bat', 'xelab.bat', 'xsim.bat') {
        if (-not (Test-Path (Join-Path $VivadoBin $t))) { throw "not found: $VivadoBin\$t" }
    }

    Write-Output '--- xvlog ---'
    & (Join-Path $VivadoBin "xvlog.bat") -sv `
        (Join-Path $PSScriptRoot '..\..\math\pkg\fxp_pkg.sv') `
        (Join-Path $PSScriptRoot '..\modal_step_pkg.sv') `
        (Join-Path $PSScriptRoot '..\modal_engine7.sv') `
        (Join-Path $PSScriptRoot '..\modal_voice_top.sv') `
        (Join-Path $PSScriptRoot '..\modal_voice_top_ab.sv') `
        tb_modal_voice_top.sv tb_modal_voice_top_ab.sv
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }

    Write-Output '--- xelab/xsim: 单份状态版 ---'
    & (Join-Path $VivadoBin "xelab.bat") tb_modal_voice_top -s tb_vt --debug typical -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
    & (Join-Path $VivadoBin "xsim.bat") tb_vt -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed" }

    Write-Output '--- xelab/xsim: 固定角色 A/B 版 ---'
    & (Join-Path $VivadoBin "xelab.bat") tb_modal_voice_top_ab -s tb_vtab --debug typical -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
    & (Join-Path $VivadoBin "xsim.bat") tb_vtab -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed" }
}
finally {
    Pop-Location
}
