# -----------------------------------------------------------------------------
# run_xsim_bank.ps1 -- 跑 TDM bank 的黄金向量比对（xsim）
#
# 用法：pwsh -File _analysis/rtl_modal/run_xsim_bank.ps1
# -----------------------------------------------------------------------------
param(
    [string]$VivadoBin = 'E:\Xilinx\Vivado\2017.4\bin'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Push-Location $here
try {
    foreach ($t in 'xvlog.bat', 'xelab.bat', 'xsim.bat') {
        if (-not (Test-Path (Join-Path $VivadoBin $t))) { throw "not found: $VivadoBin\$t" }
    }

    Write-Output '--- xvlog ---'
    & (Join-Path $VivadoBin 'xvlog.bat') -sv modal_step_pkg.sv modal_bank_seq.sv tb_modal_bank_seq.sv
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($LASTEXITCODE)" }

    Write-Output '--- xelab ---'
    & (Join-Path $VivadoBin 'xelab.bat') tb_modal_bank_seq -s tb_bank --debug typical
    if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }

    Write-Output '--- xsim ---'
    & (Join-Path $VivadoBin 'xsim.bat') tb_bank -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}
