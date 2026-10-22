# gen_spectrum.ps1 - Generate a demo 128-frame x 128-bar spectrum.mem
# For display-chain bring-up (no Python needed).
# Each frame: 128 bars, 10-bit height (0..1023), log-ish frequency shape.
# Output: spectrum.mem (128 lines, 128 hex values each)
$out = "E:\gowin_fpga\lcd_draw_learn\tools\audio\spectrum.mem"
$NFRAME = 128
$NBAR   = 128

# log frequency shape weight: low bins higher (music-like)
function BarShape([int]$b) {
    # simple spectrum envelope: strong low, weaker high
    if ($b -lt 20) { return 0.9 - $b * 0.01 }
    elseif ($b -lt 60) { return 0.6 - ($b-20) * 0.008 }
    else { return 0.35 - ($b-60) * 0.003 }
}

$sb = New-Object System.Text.StringBuilder
for ($f = 0; $f -lt $NFRAME; $f++) {
    $line = @()
    for ($b = 0; $b -lt $NBAR; $b++) {
        # temporal variation: moving note blobs across bars
        $base = BarShape $b
        $blobCenter = (($f * 3) % 128)
        $blobDist = [Math]::Abs(($b - $blobCenter + 128) % 128 - 0)
        # gaussian-ish blob
        $blob = [Math]::Exp(-$blobDist * $blobDist / 400.0)
        $val = $base * 0.5 + $blob * 0.7
        # quantize to 10-bit, cap 1023
        $v = [int]($val * 900)
        if ($v -gt 1023) { $v = 1023 }
        if ($v -lt 0) { $v = 0 }
        $line += ("{0:X3}" -f $v)
    }
    [void]$sb.AppendLine(($line -join " "))
}
[System.IO.File]::WriteAllText($out, $sb.ToString())
Write-Output "Wrote $out ($NFRAME frames x $NBAR bars)"