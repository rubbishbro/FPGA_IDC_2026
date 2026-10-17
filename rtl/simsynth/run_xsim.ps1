# -----------------------------------------------------------------------------
# run_xsim.ps1 -- 用 Vivado xsim 跑 string_mode_step 的黄金向量比对
#
# 用法（在本目录或任意位置）：
#     pwsh -File _analysis/rtl_modal/run_xsim.ps1
#
# 依赖：Vivado（默认 2017.4，用 -VivadoBin 覆盖）。脚本只在 xsim.dir 里留仿真产物，
# 不产生综合输出。
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
    & (Join-Path $VivadoBin 'xvlog.bat') -sv modal_step_pkg.sv string_mode_step.sv tb_string_mode_step.sv
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($LASTEXITCODE)" }

    Write-Output '--- xelab ---'
    & (Join-Path $VivadoBin 'xelab.bat') tb_string_mode_step -s tb_sim --debug typical
    if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }

    Write-Output '--- xsim ---'
    & (Join-Path $VivadoBin 'xsim.bat') tb_sim -R
    if ($LASTEXITCODE -ne 0) { throw "xsim failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}
