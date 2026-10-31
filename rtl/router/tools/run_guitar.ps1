# -----------------------------------------------------------------------------
# run_guitar.ps1 -- 吉他两个用例：自然衰减 / 力度线性扫（揉弦），各出一个 WAV
#
#   前置：tools/guitar_flash.py 生成过 guitar_flash.mem（脚本会自己重建）
#   用法：
#     pwsh -File rtl/router/tools/run_guitar.ps1
#     pwsh -File rtl/router/tools/run_guitar.ps1 -SkipBuild     # 已经编译过
#     pwsh -File rtl/router/tools/run_guitar.ps1 -Midi 44      # 换音（默认 slot 4）
# -----------------------------------------------------------------------------
param(
    [string]$Python = 'python',
    [string]$Vivado = 'E:\Xilinx\Vivado\2017.4\bin',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $repo
try {
    $env:PATH = "$Vivado;$env:PATH"
    $env:PYTHONIOENCODING = 'utf-8'

    Write-Host '=== 1/3 生成吉他镜像 ===' -ForegroundColor Cyan
    & $Python 'rtl/router/tools/guitar_flash.py' 2>&1 |
        Select-String '镜像|烧写|饱和 [1-9]' | ForEach-Object { "    $_" }
    if ($LASTEXITCODE -ne 0) { throw 'guitar_flash.py 失败' }

    if (-not $SkipBuild) {
        Write-Host '=== 2/3 编译 ===' -ForegroundColor Cyan
        if (Test-Path 'xsim.dir') { Remove-Item -Recurse -Force 'xsim.dir' }
        $srcs = @(
            'rtl/config_pkg.sv',
            'rtl/math/pkg/fxp_pkg.sv',
            'rtl/drivers/pkg/clk_rst_pkg.sv',
            'rtl/drivers/pkg/pad_driver_pkg.sv',
            'rtl/router/pkg/modal_step_pkg.sv',
            'rtl/router/pkg/router_pkg.sv',
            'rtl/router/pkg/sustain_profiles_pkg.sv',
            'rtl/router/pkg/pitch_tables_pkg.sv',
            'rtl/router/parts/envelope.sv',
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
            'rtl/router/tb/w25q_dut.sv',
            'rtl/router/tb/vendor/w25q128/W25Q128JVxIM.v',
            'rtl/router/tb/tb_music.sv'
        )
        foreach ($f in $srcs) {
            $out = & xvlog.bat --nolog -sv $f 2>&1
            if ($LASTEXITCODE -ne 0) { $out | Select-String 'ERROR' | ForEach-Object { "    $_" }; throw "编译失败: $f" }
        }
        $out = & xelab.bat --nolog tb_music -s tb_gt --debug typical -timescale 1ns/1ps 2>&1
        if ($LASTEXITCODE -ne 0) { $out | Select-String 'ERROR' | ForEach-Object { "    $_" }; throw 'xelab 失败' }
    }

    New-Item -ItemType Directory -Force '_analysis' | Out-Null
    & $Python 'rtl/router/tools/gen_mem.py' --src 'rtl/router/tools/guitar_flash.mem' --base 0 --out 'MEM.TXT'
    if ($LASTEXITCODE -ne 0) { throw '吉他MEM生成失败' }
    foreach ($f in @('SECSI.TXT','SFDP.TXT','SREG.TXT')) { Copy-Item "rtl/router/tb/vendor/w25q128/$f" . -Force }
    $failures=0
    Write-Host '=== 3/3 两个用例 ===' -ForegroundColor Cyan
    $cases = @(
        @{ name = 'guitar_dec'; sweep = 0; wav = '_analysis/guitar_dec.wav'; note = '自然衰减（力度不变）' },
        @{ name = 'guitar_vib'; sweep = 1; wav = '_analysis/guitar_vib.wav'; note = '力度线性 200->255->200（揉弦）' }
    )
    foreach ($c in $cases) {
        Write-Host "  -- $($c.name)：$($c.note)" -ForegroundColor DarkGray
        # tb_music 从 _analysis/case.txt 读用例（xsim 的 -testplusarg 在 .bat 里会被 '=' 拆开）
        Set-Content -Path '_analysis/case.txt' -Value @('1', "$($c.sweep)") -Encoding ascii
        $log = & xsim.bat tb_gt --nolog -runall 2>&1
        $log | Select-String '渲染完成|自检|余量|RESULT|INS=' | ForEach-Object { "     $_" }
        if (-not ($log | Select-String 'RESULT: PASS')) {
            Write-Host "     $($c.name) FAIL" -ForegroundColor Red
            $failures++; continue
        }
        # tb_music 固定写 _analysis/music_dec.txt，跑完复制成这个用例的名字
        Copy-Item '_analysis/music_dec.txt' "_analysis/$($c.name)_dec.txt" -Force
        & $Python 'rtl/router/tools/dec2wav.py' "_analysis/$($c.name)_dec.txt" $c.wav '48000' 2>&1 |
            Select-String '采样数|峰值|增益|写出' | ForEach-Object { "     $_" }
    }
    if ($failures -ne 0) { throw "$failures 个吉他用例失败" }
    Write-Host '完成：_analysis/guitar_dec.wav、_analysis/guitar_vib.wav' -ForegroundColor Green
} finally {
    Pop-Location
}
