# wav2mem.ps1 - Convert 16bit/48kHz mono WAV PCM to Verilog $readmemh .mem file
# Usage:
#   pwsh wav2mem.ps1 -Wav "synth.wav" -Out "synth.mem" -MaxSamples 384000
#   pwsh wav2mem.ps1 -Wav "gc.wav"    -Out "gc.mem"    -MaxSamples 288000 -Skip 0
param(
    [Parameter(Mandatory=$true)][string]$Wav,
    [Parameter(Mandatory=$true)][string]$Out,
    [int]$MaxSamples = 384000,   # 8 seconds @ 48k = 384000
    [int]$Skip = 0               # samples to skip from start
)

$bytes = [System.IO.File]::ReadAllBytes($Wav)
$dataStart = 44
$totalSamples = [int](($bytes.Length - $dataStart) / 2)

$sr   = [BitConverter]::ToInt32($bytes, 24)
$bps  = [BitConverter]::ToInt16($bytes, 34)
$ch   = [BitConverter]::ToInt16($bytes, 22)
if ($sr -ne 48000 -or $bps -ne 16 -or $ch -ne 1) {
    Write-Error "Need 48kHz/16bit/mono. Got sr=$sr bits=$bps ch=$ch"
    exit 1
}

$n = [Math]::Min($MaxSamples, $totalSamples - $Skip)
Write-Output "Source: $totalSamples samples, exporting $n samples (skip $Skip)"

$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $n; $i++) {
    $idx = $dataStart + ($i + $Skip) * 2
    $v = [BitConverter]::ToInt16($bytes, $idx)
    if ($v -lt 0) { $v = $v + 65536 }   # to unsigned hex
    [void]$sb.AppendLine(("{0:X4}" -f $v))
}
[System.IO.File]::WriteAllText($Out, $sb.ToString())
Write-Output "Wrote $Out : $n lines ($($sb.Length) bytes)"