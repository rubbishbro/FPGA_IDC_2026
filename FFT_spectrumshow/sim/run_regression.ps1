# Regression for the visualization demo.
# Run from FFT_spectrumshow\sim:
#   powershell -ExecutionPolicy Bypass -File .\run_regression.ps1
$ErrorActionPreference = "Stop"

$vlog = "D:\gowin\win64\vlog.exe"
$vsim = "D:\gowin\win64\vsim.exe"
$pkg  = "..\src\ui\ui_pkg.sv"

$src = Get-ChildItem ..\src -Recurse -File -Include *.v,*.sv |
       Where-Object { $_.Name -ne "ui_pkg.sv" } |
       ForEach-Object { $_.FullName }

$tb = Get-ChildItem . -File |
      Where-Object { $_.Extension -in ".v",".sv" } |
      ForEach-Object { $_.FullName }

& $vlog -sv $pkg $src
if ($LASTEXITCODE -eq 0) {
    & $vlog -sv $tb
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "COMPILE FAILED"
    exit 1
}

$tests = @(
    "sweep_source_tb",
    "spectrum_map_tb",
    "wave_capture_tb",
    "waterfall_tb",
    "trail_calc_tb",
    "curve_calc_tb",
    "lcd_curve_spectrum_tb",
    "lcd_ui_tb",
    "lcd_effects_tb",
    "ui_key_ctrl_tb",
    "ui_dual_key_tb",
    "lcd_fft_tb",
    "lcd_fft_align_tb",
    "chain_tb"
)

$failed = 0
foreach ($t in $tests) {
    $out = & $vsim -c -do "run -all; quit" $t 2>&1
    $line = $out | Select-String -Pattern "TEST (PASSED|FAILED)|CHAIN TEST (PASSED|FAILED)"
    if (!$line -or ($out -match "TEST FAILED|CHAIN TEST FAILED")) {
        Write-Host ("{0,-28} FAIL" -f $t)
        $failed++
    }
    else {
        Write-Host ("{0,-28} PASS" -f $t)
    }
}

# Diagnostic-only FFT impulse test; it has no pass/fail print.
& $vlog -sv ..\src\fft\fft1024_iter.sv .\fft1024_check_tb.sv | Out-Null
$out = & $vsim -c -do "run -all; quit" fft1024_check_tb 2>&1
if ($out -match "TEST FAILED") {
    Write-Host "fft1024_check_tb              FAIL"
    $failed++
}

if ($failed -ne 0) {
    Write-Host "=== REGRESSION FAILED: $failed test(s) ==="
    exit 1
}

Write-Host "=== REGRESSION PASSED ==="
exit 0
