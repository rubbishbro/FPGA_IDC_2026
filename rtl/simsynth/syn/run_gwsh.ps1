# -----------------------------------------------------------------------------
# run_gwsh.ps1 -- 用 Gowin gw_sh 做综合检查（并打印资源占用）
#
# 用法：pwsh -File rtl/simsynth/syn/run_gwsh.ps1            # 三个顶层都综合
#       pwsh -File rtl/simsynth/syn/run_gwsh.ps1 -Only bank # 只综合某一个
#
# 说明：此版本 gw_sh 不接受 `gw_sh script.tcl`（不会执行脚本），必须从 stdin source。
# 依赖：Gowin，默认 E:\Gowin\Gowin_V1.9.12_x64
# -----------------------------------------------------------------------------
param(
    [string]$GowinHome = 'E:\Gowin\Gowin_V1.9.12_x64',
    [ValidateSet('all', 'step', 'bank', 'probe')]
    [string]$Only = 'all'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$syn  = 'rtl/simsynth/syn'
$gwsh = Join-Path $GowinHome 'IDE\bin\gw_sh.exe'
if (-not (Test-Path $gwsh)) { throw "gw_sh not found: $gwsh" }

$targets = @()
if ($Only -in 'all', 'step')  { $targets += @{ Tcl = "$syn/synth.tcl";          Rpt = 'build/modal_step_syn/modal_step_syn/impl/gwsynthesis/modal_step_syn_syn.rpt.html' } }
if ($Only -in 'all', 'bank')  { $targets += @{ Tcl = "$syn/synth_bank.tcl";     Rpt = 'build/modal_bank_syn/modal_bank_syn/impl/gwsynthesis/modal_bank_syn_syn.rpt.html' } }
if ($Only -in 'all', 'probe') { $targets += @{ Tcl = "$syn/synth_dsp_probe.tcl"; Rpt = 'build/dsp_probe_syn/dsp_probe_syn/impl/gwsynthesis/dsp_probe_syn_syn.rpt.html' } }

Push-Location $repo
try {
    foreach ($t in $targets) {
        Write-Output "--- gw_sh: source $($t.Tcl) ---"
        "source $($t.Tcl)" | & $gwsh -nocomp 2>&1 |
            Where-Object { $_ -match 'GowinSynthesis finish|SYN_DONE|ERROR|error|WARN' } |
            ForEach-Object { $_ }
        if ($LASTEXITCODE -ne 0) { throw "gw_sh failed ($LASTEXITCODE) on $($t.Tcl)" }

        $rpt = Join-Path $repo $t.Rpt
        if (Test-Path $rpt) {
            python -c @"
import re, html
t = open(r'$rpt', encoding='utf-8', errors='ignore').read()
rows = re.findall(r'(?is)<tr[^>]*>(.*?)</tr>', t)
for r in rows:
    cells = [html.unescape(re.sub('<[^>]+>', '', c)).strip() for c in re.findall(r'(?is)<t[dh][^>]*>(.*?)</t[dh]>', r)]
    line = ' | '.join(x for x in cells if x)
    if re.search(r'(?i)^(Logic|Register|LUT|ALU|DSP|BSRAM|SPX9|pROM|SDPB|MULT27X36)\b', line):
        print('   ', line)
"@
        }
    }
}
finally {
    Pop-Location
}
