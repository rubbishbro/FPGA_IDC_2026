# -----------------------------------------------------------------------------
# run_all.ps1 -- rtl/router 的压力垫音乐回归：**渲染一段音频**（tb_music）
#
#   模块级 TB 已经全部删掉（见 README §7.0）：它们要跟着内部信号改，同步成本高，
#   而且照样漏 bug。本脚本保留压力垫端到端路径（MIDI 见 sim/run_router_midi.py）：
#     喂 fmap -> voice_router -> 收 y_valid/y_data -> 自检 + 输出音频数据
#
#   步骤：
#     1. 生成系数镜像：tools/piano_flash.py -> tools/piano_flash.mem
#     2. 编译 RTL + tb/tb_music.sv（**逐个文件**编译：一次传入大量文件时
#        xvlog 偶发长时间不返回，逐个编稳定在 1 s/个）
#     3. xelab + xsim，抓 "RESULT: PASS"
#     4. 判 RESULT: PASS
#
# 用法：
#   pwsh -File rtl/router/tools/run_all.ps1
#   pwsh -File rtl/router/tools/run_all.ps1 -SkipBuild    # 只跑，不重新编译
#   pwsh -File rtl/router/tools/run_all.ps1 -SkipFlash    # 镜像已存在，不重新生成
# -----------------------------------------------------------------------------
param(
    [string]$Python = 'python',
    [string]$Vivado = 'E:\Xilinx\Vivado\2017.4\bin',
    [switch]$SkipBuild,
    [switch]$SkipFlash           # 不重新生成 piano_flash.mem（镜像已存在时）
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $repo
try {
    $env:PATH = "$Vivado;$env:PATH"
    $env:PYTHONIOENCODING = "utf-8"      # 让 python 的中文输出不乱码

    # ---- 1) 系数镜像 --------------------------------------------------------
    $mem = 'rtl/router/tools/piano_flash.mem'
    if (-not $SkipFlash) {
        Write-Host '=== 1/4 生成系数镜像 (piano_flash.py) ===' -ForegroundColor Cyan
        & $Python 'rtl/router/tools/piano_flash.py' 2>&1 |
            Select-String '归一化|饱和|镜像|烧写地址' | ForEach-Object { "    $_" }
        if ($LASTEXITCODE -ne 0) { throw "piano_flash.py 失败（exit $LASTEXITCODE）" }
    }
    if (-not (Test-Path $mem)) { throw "缺系数镜像 $mem（去掉 -SkipFlash 重跑）" }
    $memLines = (Get-Content $mem | Measure-Object -Line).Lines
    Write-Host "    $mem : $memLines 字节" -ForegroundColor DarkGray

    # ---- 2) 编译 ------------------------------------------------------------
    if (-not $SkipBuild) {
        Write-Host '=== 2/4 编译 RTL + tb_music（逐个文件） ===' -ForegroundColor Cyan
        if (Test-Path 'xsim.dir') { Remove-Item -Recurse -Force 'xsim.dir' }
        $srcs = @(
            'rtl/config_pkg.sv',
            'rtl/math/pkg/fxp_pkg.sv',
            'rtl/drivers/pkg/clk_rst_pkg.sv',
            'rtl/drivers/pkg/pad_driver_pkg.sv',
            'rtl/router/pkg/modal_step_pkg.sv',
            'rtl/router/pkg/router_pkg.sv',
            'rtl/router/pkg/performance_gain_pkg.sv',
            'rtl/router/pkg/sustain_profiles_pkg.sv',
            'rtl/router/pkg/pitch_tables_pkg.sv',
            'rtl/router/parts/envelope.sv',
            'rtl/router/parts/polyphony_gain.sv',
            'rtl/router/parts/excitation.sv',
            'rtl/router/parts/modulation.sv',
            'rtl/router/parts/eng1_pitch.sv',
            'rtl/router/parts/body_biquad.sv',
            'rtl/router/parts/comb_reverb.sv',
            'rtl/router/engines/eng0.sv',
            'rtl/router/engines/eng1.sv',
            'rtl/router/routers/eng_router.sv',
            'rtl/router/routers/performance_input_mux.sv',
            'rtl/router/routers/env_router.sv',
            'rtl/router/routers/exc_router.sv',
            'rtl/router/routers/mod_router.sv',
            'rtl/router/routers/body_router.sv',
            'rtl/router/routers/reverb_router.sv',
            'rtl/router/loader.sv',
            'rtl/router/voice_router.sv',
            'rtl/audio/audio_async_fifo.sv',
            'rtl/audio/i2s_amp_tx.sv',
            'rtl/audio/pt8211_tx.sv',
            'rtl/audio/stereo_spatializer.sv',
            'rtl/audio/i2s_audio_output.sv',
            'rtl/router/tb/w25q_dut.sv',
            'rtl/router/tb/vendor/w25q128/W25Q128JVxIM.v',
            'rtl/router/tb/tb_music.sv'
        )
        foreach ($f in $srcs) {
            $out = & xvlog.bat --nolog -sv $f 2>&1
            if ($LASTEXITCODE -ne 0) {
                $out | Select-String 'ERROR' | ForEach-Object { "    $_" }
                throw "编译失败: $f"
            }
        }
        Write-Host "    $($srcs.Count) 个文件 OK" -ForegroundColor DarkGray

        $out = & xelab.bat --nolog tb_music -s tb_mu --debug typical -timescale 1ns/1ps 2>&1
        if ($LASTEXITCODE -ne 0) {
            $out | Select-String 'ERROR' | ForEach-Object { "    $_" }
            throw 'xelab 失败'
        }
    }

    # Prepare a fresh private model image before running music.
    $vendor = 'rtl/router/tb/vendor/w25q128'
    $musicMem=$mem
    if (Test-Path '_analysis/case.txt') {
        $caseInstrument=(Get-Content '_analysis/case.txt' | Select-Object -First 1).Trim()
        if ($caseInstrument -eq '1') { $musicMem='rtl/router/tools/guitar_flash.mem' }
    }
    New-Item -ItemType Directory -Force '_analysis' | Out-Null
    & $Python 'rtl/router/tools/gen_mem.py' --src $musicMem --base 0 --out 'MEM.TXT'
    if ($LASTEXITCODE -ne 0) { throw 'gen_mem.py 失败' }
    foreach ($f in @('SECSI.TXT','SFDP.TXT','SREG.TXT')) { Copy-Item "$vendor/$f" . -Force }

    # ---- 3) 跑 --------------------------------------------------------------
    Write-Host '=== 3/4 仿真（渲染音频） ===' -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $log = & xsim.bat tb_mu --nolog -runall 2>&1
    $sw.Stop()
    $log | Select-String '渲染完成|自检|余量|按 slot|同时|RESULT' | ForEach-Object { "    $_" }
    Write-Host ("    仿真墙钟 {0:N0} s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    # ---- 4) 汇总 ------------------------------------------------------------
    Write-Host '=== 4/4 汇总 ===' -ForegroundColor Cyan
    $pass = ($log | Select-String 'RESULT: PASS').Count -gt 0
    if ($pass) {
        Write-Host 'tb_music             PASS' -ForegroundColor Green

        # ---- 5) 导出 WAV --------------------------------------------------
        Write-Host '=== 5/5 导出 WAV ===' -ForegroundColor Cyan
        & $Python 'rtl/router/tools/dec2wav.py' '_analysis/music_dec.txt' '_analysis/music.wav' '48000' 2>&1 |
            ForEach-Object { "    $_" }
        if ($LASTEXITCODE -eq 0) {
            Write-Host '    -> _analysis/music.wav' -ForegroundColor Green
        } else {
            Write-Host '    dec2wav 失败（仿真结论仍算 PASS，只是音频没导出）' -ForegroundColor Yellow
        }
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run_loader.ps1') -Python $Python -Vivado $Vivado
        if ($LASTEXITCODE -ne 0) { throw 'run_loader.ps1 失败' }
        exit 0
    } else {
        Write-Host 'tb_music             FAIL' -ForegroundColor Red
        $log | Select-String 'RESULT|ERROR|FATAL' | Select-Object -Last 8 | ForEach-Object { "    $_" }
        exit 1
    }
} finally {
    Pop-Location
}
