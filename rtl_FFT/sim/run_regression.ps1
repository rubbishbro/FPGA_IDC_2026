# Regression for the visualization demo.
# Run from rtl_FFT\sim:
#   powershell -ExecutionPolicy Bypass -File .\run_regression.ps1
$ErrorActionPreference = "Stop"

$vlog = "D:\gowin\win64\vlog.exe"
$vsim = "D:\gowin\win64\vsim.exe"
$pkg  = "..\src\ui\ui_pkg.sv"
$shared = @("..\..\rtl\config_pkg.sv", "..\..\rtl\drivers\pkg\joystick_pkg.sv",
            "..\src\ui\sidebar_font_pkg.sv", "..\..\rtl\control_loop.sv",
            "..\..\rtl\config_dispatch.sv", "..\..\rtl\drivers\joystick_adapter.sv")

$src = Get-ChildItem ..\src -Recurse -File -Include *.v,*.sv |
       Where-Object { $_.Name -notlike "*pkg.sv" } |
       ForEach-Object { $_.FullName }

$tb = Get-ChildItem . -File |
      Where-Object { $_.Extension -in ".v",".sv" } |
      ForEach-Object { $_.FullName }

& $vlog -sv $pkg $shared $src
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

if ($failed -ne 0) {
    Write-Host "=== REGRESSION FAILED: $failed test(s) ==="
    exit 1
}

Write-Host "=== REGRESSION PASSED ==="
exit 0
