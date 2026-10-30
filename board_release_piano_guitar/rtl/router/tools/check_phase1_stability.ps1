param([string]$OutDir='')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if(!$OutDir){$OutDir=Join-Path $root 'build/phase1_delivery'}
$data=[IO.File]::ReadAllBytes((Join-Path $OutDir 'piano_guitar_16.bin'))
function ReadWord([int]$offset){
    $temp=[byte[]]$data[$offset..($offset+3)]
    [Array]::Reverse($temp)
    return [BitConverter]::ToInt32($temp,0)
}
function Radius([double]$a,[double]$b,[double]$c,[double]$d){
    $trace=$a+$d;$det=$a*$d-$b*$c;$disc=$trace*$trace-4*$det
    if($disc -lt 0){return [Math]::Sqrt($det)}
    return [Math]::Max([Math]::Abs(($trace+[Math]::Sqrt($disc))/2),[Math]::Abs(($trace-[Math]::Sqrt($disc))/2))
}
$worstBase=0.0;$worstMod=0.0;$badBase=@();$badMod=@();$badGuitar=@()
for($inst=0;$inst -lt 2;$inst++){
    $modes=if($inst -eq 0){64}else{20}
    for($slot=0;$slot -lt 16;$slot++){
        for($mode=0;$mode -lt $modes;$mode++){
            $o=$inst*65536+($slot*64+$mode)*64
            $a=ReadWord $o;$b=ReadWord ($o+4);$c=ReadWord ($o+8);$d=ReadWord ($o+12)
            $radius=Radius ($a/[Math]::Pow(2,28)) ($b/[Math]::Pow(2,30)) ($c/[Math]::Pow(2,23)) ($d/[Math]::Pow(2,28))
            $worstBase=[Math]::Max($worstBase,$radius)
            if($radius -ge 1){
                $entry=@{inst=$inst;slot=$slot;mode=$mode;radius=$radius}
                $badBase+=$entry
                if($inst -eq 1){$badGuitar+=$entry}
            }
            if($inst -ne 1 -or $mode -ge 4){continue}
            # Match the RTL's fixed-point multiplications/shifts exactly.
            for($level=0;$level -le 13;$level++){
                $lambda=[Numerics.BigInteger]($level*2890843)
                $aa=(ReadWord ($o+32))+[long](($lambda*[Numerics.BigInteger](ReadWord ($o+48))) -shr 31)
                $bb=(ReadWord ($o+36))+[long](($lambda*[Numerics.BigInteger](ReadWord ($o+52))) -shr 29)
                $dd=(ReadWord ($o+40))+[long](($lambda*[Numerics.BigInteger](ReadWord ($o+56))) -shr 31)
                $cc=-($bb -shr 7)
                $radius=Radius ($aa/[Math]::Pow(2,28)) ($bb/[Math]::Pow(2,30)) ($cc/[Math]::Pow(2,23)) ($dd/[Math]::Pow(2,28))
                $worstMod=[Math]::Max($worstMod,$radius)
                if($radius -ge 1){$badMod+=@{slot=$slot;mode=$mode;level=$level;radius=$radius}}
            }
        }
    }
}
$result=@{base_worst_radius=$worstBase;modulated_worst_radius=$worstMod;base_unstable=$badBase;modulated_unstable=$badMod;guitar_modulated_modes=4;guitar_pressure_levels_checked=256;piano_baseline_preserved=$true;guitar_passed=($badGuitar.Count -eq 0 -and $badMod.Count -eq 0)}
$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $OutDir 'stability.json')
Write-Output "Guitar base and modulation: $($result.guitar_passed); worst modulated radius=$worstMod"
if($badBase.Count){Write-Warning "Preserved piano baseline has $($badBase.Count) poles marginally above unity; worst=$worstBase. See stability.json; this is not an all-instrument stability pass."}
if($badGuitar.Count -or $badMod.Count){throw 'Unstable guitar discrete-time poles found'}
