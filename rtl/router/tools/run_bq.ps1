# -----------------------------------------------------------------------------
# run_bq.ps1 -- body_biquad（Q4.27，5 段）一键回归
#
#   1. bq_gen.py：重算 Q4.27 系数并与 body_router.INST_GUITAR 的字面量对账，
#      重新生成 bq_stim.mem / bq_exp_*.mem
#   2. xvlog + xelab + xsim：跑 直通 / 单段 / 5 段 三个用例，逐样本比对
#
# 用法：pwsh -File rtl/router/tools/run_bq.ps1
#       pwsh -File rtl/router/tools/run_bq.ps1 -SkipGen   # 只跑仿真
# -----------------------------------------------------------------------------
param(
    [string]$Python = 'python',
    [string]$Vivado = 'E:\Xilinx\Vivado\2017.4\bin',
    [switch]$SkipGen
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $repo
try {
    if (-not $SkipGen) {
        Write-Output '--- bq_gen.py（系数对账 + 生成向量）---'
        & $Python rtl/router/tools/bq_gen.py
        if ($LASTEXITCODE -ne 0) { throw "bq_gen failed ($LASTEXITCODE)" }
    }

    $env:PATH = "$Vivado;" + $env:PATH
    Write-Output '--- xvlog / xelab / xsim ---'
    & cmd /c 'xvlog.bat --nolog -sv rtl/math/pkg/fxp_pkg.sv rtl/router/pkg/router_pkg.sv rtl/router/parts/body_biquad.sv rtl/router/routers/body_router.sv rtl/router/tb/tb_body_biquad.sv 2>&1'
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($LASTEXITCODE)" }
    & cmd /c 'xelab.bat --nolog tb_body_biquad -s tb_bq --debug typical -timescale 1ns/1ps 2>&1' |
        Select-String 'ERROR|Built'
    if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }
    $log = & cmd /c 'xsim.bat tb_bq --nolog -runall 2>&1'
    $log | Select-String 'samples|合计|MISMATCH|RESULT|body_biquad：|stimulus:'
    if ($log -match 'RESULT: PASS') { exit 0 } else { exit 1 }
}
finally {
    Pop-Location
}
