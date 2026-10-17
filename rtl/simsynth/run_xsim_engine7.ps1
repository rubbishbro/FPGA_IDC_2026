param([string]$VivadoBin = "E:\Xilinx\Vivado\2017.4\bin")
$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot
try {
    & (Join-Path $VivadoBin "xvlog.bat") -sv (Join-Path $PSScriptRoot '..\math\pkg\fxp_pkg.sv') modal_step_pkg.sv modal_engine7.sv modal_voice_top.sv tb_modal_voice_top.sv
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
    & (Join-Path $VivadoBin "xelab.bat") tb_modal_voice_top -s tb_vt --debug typical -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
    & (Join-Path $VivadoBin "xsim.bat") tb_vt -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed" }
} finally { Pop-Location }
