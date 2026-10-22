# gen_bin2bar.ps1 - Generate bin2bar.mem (log-frequency-axis bin->bar mapping)
# Rewritten: direct per-bin computation, no array juggling.
# bar n frequency range: f_low*(f_high/f_low)^(n/128) .. (n+1)/128
# bin k frequency: k * 46.875 Hz (48k/1024)
$out = "E:\gowin_fpga\lcd_draw_learn\tools\audio\bin2bar.mem"
$fs = 48000.0
$N  = 1024
$NBAR = 128
$f_low  = 200.0
$f_high = 24000.0     # up to Nyquist (24k); no bins "out of range" to fold
$ratio = $f_high / $f_low
$bin_hz = $fs / $N   # 46.875

# precompute bar boundary frequencies
$bounds = @()
for ($n = 0; $n -le $NBAR; $n++) {
    $bounds += ($f_low * [Math]::Pow($ratio, $n / $NBAR))
}

# count bins per bar (for sanity report)
$cnt = @{}
for ($i = 0; $i -lt $NBAR; $i++) { $cnt[$i] = 0 }

$sb = New-Object System.Text.StringBuilder
for ($k = 0; $k -lt 512; $k++) {
    $freq = $k * $bin_hz
    # f_high = 24k = Nyquist, so no bin exceeds f_high; normal mapping.
    # (safety: freq >= f_high shouldn't happen, but clamp to last bar)
    if ($freq -lt $bounds[0]) {
        $bar = 0                       # below f_low -> lowest bar
    } else {
        $bar = $NBAR - 1
        for ($n = 0; $n -lt $NBAR; $n++) {
            if ($freq -ge $bounds[$n] -and $freq -lt $bounds[$n+1]) { $bar = $n; break }
        }
    }
    $cnt[$bar]++
    [void]$sb.AppendLine(("{0:X2}" -f $bar))
}
[System.IO.File]::WriteAllText($out, $sb.ToString())

# report
$line = "bar0={0} bar5={1} bar20={2} bar60={3} bar100={4} bar127={5}" -f $cnt[0],$cnt[5],$cnt[20],$cnt[60],$cnt[100],$cnt[127]
Write-Output "Wrote $out (512 bins -> 128 bars)"
Write-Output $line
Write-Output ("boundary freqs: bar0 up to {0:N0}Hz, bar127 starts {1:N0}Hz" -f $bounds[1], $bounds[127])