param([string]$VivadoBin = "E:\Xilinx\Vivado\2017.4\bin")
$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot
try {
    & (Join-Path $VivadoBin "xvlog.bat") -sv modal_step_pkg.sv modal_bank_ram.sv tb_modal_bank_ram.sv
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
    & (Join-Path $VivadoBin "xelab.bat") tb_modal_bank_ram -s tb_ram --debug typical
    if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
    & (Join-Path $VivadoBin "xsim.bat") tb_ram -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed" }
} finally { Pop-Location }
