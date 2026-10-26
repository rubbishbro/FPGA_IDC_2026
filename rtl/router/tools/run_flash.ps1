# -----------------------------------------------------------------------------
# run_flash.ps1 -- weight_loader（W25Q64 SPI 读）一键回归
#
#   1. flash_image.py --selftest：打包/解析自检
#   2. flash_image.py --demo：生成 tb 用的字节文件 flash_demo.{bin,mem}
#   3. xvlog + xelab + xsim：跑 tb_loader_flash（含 W25Q64 行为模型）
#      - 用 Python 打包的表加载一遍：写口 32 笔全部对、err=0
#      - 把片子填 FF 再加载：err=1
#
# 用法：pwsh -File rtl/router/tools/run_flash.ps1
# -----------------------------------------------------------------------------
param(
    [string]$Python = 'python',
    [string]$Vivado = 'E:\Xilinx\Vivado\2017.4\bin'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $repo
try {
    Write-Output '--- flash_image.py（自检 + 生成 tb 用的字节文件）---'
    & $Python rtl/router/tools/flash_image.py --selftest
    if ($LASTEXITCODE -ne 0) { throw "selftest failed ($LASTEXITCODE)" }
    # tb 里用的是 SLOTS=4 / N_MODES=4 / inst=2，这里必须一致
    & $Python rtl/router/tools/flash_image.py --demo rtl/router/tools/flash_demo.bin `
        --modes 4 --slots 4 --inst 2 --mem-out rtl/router/tools/flash_demo.mem
    if ($LASTEXITCODE -ne 0) { throw "demo failed ($LASTEXITCODE)" }

    $env:PATH = "$Vivado;" + $env:PATH
    Write-Output '--- xvlog / xelab / xsim ---'
    & cmd /c 'xvlog.bat --nolog -sv rtl/math/pkg/fxp_pkg.sv rtl/router/pkg/modal_step_pkg.sv rtl/router/pkg/router_pkg.sv rtl/router/loader.sv rtl/router/tb/tb_loader_flash.sv 2>&1'
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($LASTEXITCODE)" }
    & cmd /c 'xelab.bat --nolog tb_loader_flash -s tb_ld --debug typical -timescale 1ns/1ps 2>&1' |
        Select-String 'ERROR|Built'
    if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }
    $log = & cmd /c 'xsim.bat tb_ld --nolog -runall 2>&1'
    $log | Select-String 'weight_loader|表来自|good|blank|每模态|RESULT|BAD'
    if ($log -match 'RESULT: PASS') { exit 0 } else { exit 1 }
}
finally {
    Pop-Location
}
