# -----------------------------------------------------------------------------
# run_all.ps1 -- 一键跑 rtl/router 的全部回归
#
#   1. 用一条 xvlog 编译 RTL + 所有 testbench（tb/ 目录）
#   2. 逐个 xelab + xsim，抓每个 TB 的 RESULT
#   3. 汇总 PASS/FAIL；任一 FAIL 就退出码 1
#
# 用法：
#   pwsh -File rtl/router/tools/run_all.ps1
#   pwsh -File rtl/router/tools/run_all.ps1 -SkipMusic     # 跳过 1 秒音频渲染
#   pwsh -File rtl/router/tools/run_all.ps1 -Only tb_reverb
# -----------------------------------------------------------------------------
param(
    [string]$Python = 'python',
    [string]$Vivado = 'E:\Xilinx\Vivado\2017.4\bin',
    [string]$Only   = '',
    [switch]$SkipMusic
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $repo
try {
    $rtl = @(
        'rtl/math/pkg/fxp_pkg.sv',
        'rtl/drivers/pkg/clk_rst_pkg.sv',
        'rtl/drivers/pkg/pad_driver_pkg.sv',
        'rtl/router/pkg/modal_step_pkg.sv',
        'rtl/router/pkg/router_pkg.sv',
        'rtl/router/parts/envelope.sv',
        'rtl/router/parts/excitation.sv',
        'rtl/router/parts/modulation.sv',
        'rtl/router/parts/body_biquad.sv',
        'rtl/router/parts/comb_reverb.sv',
        'rtl/router/engines/eng0.sv',
        'rtl/router/engines/eng1.sv',
        'rtl/router/routers/eng_router.sv',
        'rtl/router/routers/env_router.sv',
        'rtl/router/routers/exc_router.sv',
        'rtl/router/routers/mod_router.sv',
        'rtl/router/routers/body_router.sv',
        'rtl/router/routers/reverb_router.sv',
        'rtl/router/loader.sv',
        'rtl/router/voice_router.sv',
        'rtl/router/fmax_router.sv'
    )
    # TB / 快照名 / 看哪个字符串算 PASS / 说明
    $tbs = @(
        @{ tb='tb_voice_router'; snap='tbv_body'; pat='RESULT: PASS'; note='端到端：直通/混响/清零/吉他/reload' },
        @{ tb='tb_throughput';   snap='tb_tp';    pat='->';           note='每采样拍数（865）' },
        @{ tb='tb_reverb';       snap='tb_rv';    pat='RESULT: PASS'; note='NONE 直通 / 大值 / 切预设' },
        @{ tb='tb_excitation';   snap='tb_ex';    pat='RESULT: PASS'; note='脉冲串 / clear（含非节拍）' },
        @{ tb='tb_envelope';     snap='tb_env';   pat='RESULT: PASS'; note='起音钳位 / dead / dyn0' },
        @{ tb='tb_modulation';   snap='tbma';     pat='RESULT: PASS'; note='系数数值 / 门控 / fmap=0' },
        @{ tb='tb_eng1_g';       snap='tbg';      pat='RESULT: PASS'; note='eng1 golden / 清零 / 64 模态' },
        @{ tb='tb_loader_flash'; snap='tb_ld';    pat='RESULT: PASS'; note='四线 SPI + 逐笔写口' },
        @{ tb='tb_music';        snap='tb_mu';    pat='渲染完成';      note='渲染音频（不是自检）' },
        @{ tb='tb_body_biquad';  snap='tb_bq';    pat='RESULT: PASS'; note='腔体 直通/单段/5段 对 Python 模型' }
    )

    $env:PATH = "$Vivado;" + $env:PATH

    $srcs = @()
    $srcs += $rtl
    foreach ($t in $tbs) { $srcs += "rtl/router/tb/$($t.tb).sv" }
    $srcs += 'rtl/router/tb/tb_body_biquad.sv'
    $srcs += 'rtl/router/tb/tb_fmax_router.sv'

    Write-Output '=== xvlog（一次编译全部）==='
    $log = & cmd /c ("xvlog.bat --nolog -sv " + ($srcs -join ' ') + ' 2>&1')
    $errs = $log | Select-String 'ERROR'
    if ($errs) { $errs | ForEach-Object { $_.Line }; throw 'xvlog failed' }

    $results = @()
    foreach ($t in $tbs) {
        if ($Only -ne '' -and $t.tb -ne $Only) { continue }
        if ($t.tb -eq 'tb_music' -and $SkipMusic) { continue }
        Write-Output "=== $($t.tb)：$($t.note) ==="
        $e = & cmd /c ("xelab.bat --nolog $($t.tb) -s $($t.snap) --debug typical -timescale 1ns/1ps 2>&1")
        $ee = $e | Select-String 'ERROR'
        if ($ee) {
            $ee | ForEach-Object { $_.Line }
            $results += ,@($t.tb, 'ELAB FAIL')
            continue
        }
        $r = & cmd /c ("xsim.bat $($t.snap) --nolog -runall 2>&1")
        $r | Select-String 'TIMEOUT|RESULT|\[|渲染完成|个作业|->' | Select-Object -First 8 | ForEach-Object { "    " + $_.Line.Trim() }
        if ($r | Select-String ([regex]::Escape($t.pat))) { $results += ,@($t.tb, 'PASS') }
        else { $results += ,@($t.tb, 'FAIL') }
    }

    Write-Output ''
    Write-Output '=== 汇总 ==='
    $fail = 0
    foreach ($r in $results) {
        "{0,-20} {1}" -f $r[0], $r[1]
        if ($r[1] -ne 'PASS') { $fail++ }
    }
    if ($fail -eq 0) { Write-Output 'ALL PASS'; exit 0 }
    else { Write-Output "$fail 个没过"; exit 1 }
}
finally {
    Pop-Location
}
