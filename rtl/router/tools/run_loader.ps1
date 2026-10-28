# -----------------------------------------------------------------------------
# run_loader.ps1 -- 用公开的 W25Q128 行为模型验 weight_loader 的加载数据
#
#   三个用例：钢琴表 / 吉他表 / 空片（全 FF）
#   对每个用例：生成 MEM.TXT（我们自己的镜像）-> 改写 TB 参数 -> 编译 -> 跑 -> 抓 RESULT
#
# 用法：
#   pwsh -File rtl/router/tools/run_loader.ps1
# -----------------------------------------------------------------------------
param(
    [string]$Python  = 'python',
    [string]$Vivado  = 'E:\Xilinx\Vivado\2017.4\bin'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $repo
try {
    $env:PATH = "$Vivado;$env:PATH"
    $env:PYTHONIOENCODING = 'utf-8'

    $vendor = 'rtl/router/tb/vendor/w25q128'
    $tb     = 'rtl/router/tb/tb_loader_ref.sv'

    # 所有 RTL 依赖先编好（TB 每次重编，只改参数）
    Write-Host '=== 1/2 编译 RTL（一次性）===' -ForegroundColor Cyan
    foreach ($f in @(
        'rtl/math/pkg/fxp_pkg.sv',
        'rtl/drivers/pkg/clk_rst_pkg.sv',
        'rtl/router/pkg/modal_step_pkg.sv',
        'rtl/router/pkg/router_pkg.sv',
        'rtl/router/loader.sv',
        'rtl/router/tb/w25q_dut.sv',
        "$vendor/W25Q128JVxIM.v"
    )) {
        $out = & xvlog.bat --nolog $(if ($f -like '*.sv') { @('-sv', $f) } else { @($f) }) 2>&1
        if ($LASTEXITCODE -ne 0) { $out | Select-String 'ERROR' | ForEach-Object { "    $_" }; throw "编译失败: $f" }
    }
    Write-Host '    OK' -ForegroundColor DarkGray

    $cases = @(
        @{ name = '钢琴表'; inst = 0; modes = 64; blank = 0; mem = 'rtl/router/tools/piano_flash.mem'  },
        @{ name = '吉他表'; inst = 1; modes = 20; blank = 0; mem = 'rtl/router/tools/guitar_flash.mem' },
        @{ name = '空片全FF'; inst = 0; modes = 64; blank = 1; mem = 'rtl/router/tools/piano_flash.mem' }
    )

    Write-Host '=== 2/2 三个用例 ===' -ForegroundColor Cyan
    $fail = 0
    foreach ($c in $cases) {
        Write-Host "  -- $($c.name)" -ForegroundColor DarkGray

        # 1) MEM.TXT：空片用例用一张全 FF 的假表
        if ($c.blank) {
            & $Python '_analysis/mk_blank64.py' 2>&1 | Out-Null
            & $Python '_analysis/gen_mem.py' --src '_analysis/blank64k.mem' --base 0 --out "$vendor/MEM.TXT" 2>&1 |
                Select-String '写出' | ForEach-Object { "     $_" }
        } else {
            & $Python '_analysis/gen_mem.py' --src $c.mem --base 0 --out "$vendor/MEM.TXT" 2>&1 |
                Select-String '写出' | ForEach-Object { "     $_" }
        }
        # 模型用**裸文件名**找表，所以拷到仿真工作目录
        foreach ($f in @('MEM.TXT', 'SECSI.TXT', 'SFDP.TXT', 'SREG.TXT')) {
            Copy-Item "$vendor/$f" . -Force
        }

        # 2) 改写 TB 参数
        $s = [IO.File]::ReadAllText((Resolve-Path $tb))
        $s = [regex]::Replace($s, 'localparam int N_MODES = \d+;',       "localparam int N_MODES = $($c.modes);")
        $s = [regex]::Replace($s, 'localparam int INST    = \d+;',       "localparam int INST    = $($c.inst);")
        $s = [regex]::Replace($s, "localparam bit BLANK   = 1'b\d;",     "localparam bit BLANK   = 1'b$($c.blank);")
        $s = [regex]::Replace($s, 'fd = \$fopen\("[^"]+", "r"\);',       "fd = `$fopen(`"$($c.mem)`", `"r`");")
        [IO.File]::WriteAllText((Resolve-Path $tb), $s, (New-Object Text.UTF8Encoding($false)))

        # 3) 编 + 跑
        $snap = "tb_ld_$($c.inst)_$($c.modes)_$($c.blank)"
        $out = & xvlog.bat --nolog -sv $tb 2>&1
        if ($LASTEXITCODE -ne 0) { $out | Select-String 'ERROR' | ForEach-Object { "     $_" }; $fail++; continue }
        $out = & xelab.bat --nolog tb_loader_ref -s $snap --debug typical -timescale 1ns/1ps 2>&1
        if ($LASTEXITCODE -ne 0) { $out | Select-String 'ERROR' | ForEach-Object { "     $_" }; $fail++; continue }
        $log = & xsim.bat $snap --nolog -runall 2>&1
        $log | Select-String '用例：|loader done|写入笔数|RESULT' | ForEach-Object { "     $_" }
        if (-not ($log | Select-String 'RESULT: PASS')) { $fail++ }
    }

    if ($fail -eq 0) { Write-Host '全部 PASS' -ForegroundColor Green }
    else             { Write-Host "$fail 个用例 FAIL" -ForegroundColor Red; exit 1 }
} finally {
    Pop-Location
}
