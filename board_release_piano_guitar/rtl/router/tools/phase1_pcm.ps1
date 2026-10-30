param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$metrics=@()
foreach($name in @('piano','guitar','piano_all16','guitar_all16')){
    $path=Join-Path $root "build/phase1_sim/${name}_pcm.txt"
    $values=[IO.File]::ReadAllLines($path)
    $writer=[IO.BinaryWriter]::new([IO.File]::Open((Join-Path $root "build/phase1_delivery/${name}.wav"),[IO.FileMode]::Create))
    $peak=0.0;$clipped=0;$sumSq=0.0
    try{
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([int](36+$values.Length*2))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([int]16)
        $writer.Write([int16]1);$writer.Write([int16]1);$writer.Write([int]48828);$writer.Write([int]97656)
        $writer.Write([int16]2);$writer.Write([int16]16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([int]($values.Length*2))
        foreach($line in $values){
            # Stage1 board PCM_HEADROOM_BITS=4: multiply12, round, shift13.
            $scaled=([long]$line*12+4096) -shr 13
            if($scaled -gt 32767 -or $scaled -lt -32768){$clipped++}
            $sample=[int16][Math]::Clamp([long]$scaled,[long]-32768,[long]32767)
            $writer.Write($sample);$peak=[Math]::Max($peak,[Math]::Abs([int]$sample));$sumSq+=[double]$sample*$sample
        }
    }finally{$writer.Dispose()}
    $metrics+=@{name=$name;samples=$values.Length;peak_pcm=$peak;clipped_samples=$clipped;rms_pcm=[Math]::Sqrt($sumSq/$values.Length);wave_hz=48828;actual_hz=48828.125}
}
$metrics|ConvertTo-Json -Depth 5|Set-Content -Encoding utf8 (Join-Path $root 'build/phase1_delivery/pcm_metrics.json')
Write-Output ($metrics|ConvertTo-Json)
if(($metrics | Where-Object {$_.clipped_samples -gt 0}).Count){throw 'PCM clipping detected'}
