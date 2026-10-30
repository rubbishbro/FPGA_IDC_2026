param([string]$PnrDir='', [string]$ProjectName='phase1_piano_guitar')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$out=Join-Path $root 'build/phase1_delivery'
if(!$PnrDir){throw 'Specify -PnrDir and -ProjectName for the matching Flash-base build; do not implicitly reuse the legacy zero-base FS.'}
$pnr=(Resolve-Path $PnrDir).Path
$htmlPath=Join-Path $pnr ($ProjectName+'_tr_content.html')
$html=Get-Content $htmlPath -Raw
$result=[ordered]@{status='pending';report=$htmlPath;checks=@{};clocks=@{}}
foreach($kind in @('Setup','Hold')){
    $match=[regex]::Match($html,"Numbers of $kind Violated Endpoints</td>\s*<td>(\d+)</td>")
    if(!$match.Success){throw "Missing $kind violation count"}
    $result.checks[$kind.ToLowerInvariant()+'_violations']=[int]$match.Groups[1].Value
    if([int]$match.Groups[1].Value -ne 0){throw "$kind timing violations; no release FS copied"}
}
$anchors=@('Setup_Slack_Table','Hold_Slack_Table','Recovery_Slack_Table','Removal_Slack_Table','MIN_PULSE_WIDTH_TABLE')
for($i=0;$i -lt $anchors.Count;$i++){
    $start=$html.IndexOf('name="'+$anchors[$i]+'"')
    if($start -lt 0){throw "Missing $($anchors[$i])"}
    $end=if($i+1 -lt $anchors.Count){$html.IndexOf('name="'+$anchors[$i+1]+'"')}else{$html.IndexOf('</table>',$start)+8}
    $section=$html.Substring($start,$end-$start)
    $values=@([regex]::Matches($section,'<tr>\s*<td>\d+</td>\s*<td>(-?\d+\.\d+)</td>') | ForEach-Object {[double]::Parse($_.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)})
    if(!$values.Count){throw "No recognized slack rows in $($anchors[$i])"}
    $min=($values|Measure-Object -Minimum).Minimum
    $result.checks[$anchors[$i]]=@{worst_slack_ns=$min;rows=$values.Count}
    if($min -lt 0){throw "Negative $($anchors[$i]) slack=$min; no release FS copied"}
}
$clockMatches=[regex]::Matches($html,'<td>(clk50|clk_core|clk_audio|clk_pix)</td>\s*<td>([\d.]+)\(MHz\)</td>\s*<td>([\d.]+)\(MHz\)</td>')
$expected=@{clk50=50.0;clk_core=50.0;clk_audio=12.5;clk_pix=33.333}
foreach($match in $clockMatches){
    $name=$match.Groups[1].Value;$target=[double]$match.Groups[2].Value;$actual=[double]$match.Groups[3].Value
    if([Math]::Abs($target-$expected[$name]) -gt 0.002 -or $actual -lt $target){throw "Clock $name fails: target=$target Fmax=$actual"}
    $result.clocks[$name]=@{target_mhz=$target;fmax_mhz=$actual}
}
if($result.clocks.Count -ne 4){throw 'Missing clock timing summary'}
$sim=Get-Content (Join-Path $root 'build/phase1_sim/simulation.log') -Raw
if($sim -notmatch 'PASS tb_phase1' -or $sim -match '\*\* (Error|Fatal)|FAIL '){throw 'Simulation has not passed'}
$stability=Get-Content (Join-Path $out 'stability.json') -Raw | ConvertFrom-Json
if(!$stability.guitar_passed){throw 'Guitar stability has not passed'}
$metrics=Get-Content (Join-Path $out 'pcm_metrics.json') -Raw | ConvertFrom-Json
if(@($metrics).Count -ne 4 -or @($metrics|Where-Object {$_.clipped_samples -gt 0}).Count){throw 'PCM headroom check has not passed'}
$sourceList=Get-Content (Join-Path $root 'rtl/platform/tang_mega_138k_pro/sources.f')|Where-Object {$_}
if(($sourceList|Select-Object -Unique).Count -ne $sourceList.Count){throw 'Duplicate production source'}
foreach($line in $sourceList){if(!(Test-Path (Join-Path $root $line))){throw "Missing production source: $line"}}
$cst=Get-Content (Join-Path $root 'rtl/platform/tang_mega_138k_pro/instrument_board.cst') -Raw
$locs=[regex]::Matches($cst,'IO_LOC\s+"([^"]+)"\s+(\w+);')
if(@($locs|ForEach-Object {$_.Groups[1].Value}|Select-Object -Unique).Count -ne $locs.Count -or @($locs|ForEach-Object {$_.Groups[2].Value}|Select-Object -Unique).Count -ne $locs.Count){throw 'Duplicate pin assignment'}
$result.status='passed'
$result.simulation=([regex]::Match($sim,'PASS tb_phase1[^\r\n]*')).Value
$result.simulation_scope='Existing phase1 regression uses FLASH_BASE=0; it does not validate the relocated board address.'
$result.board_validation='User reported programming validation passed after the Flash-base fix; not independently repeated by this script.'
$resources=Get-Content (Join-Path $out 'resources.json') -Raw | ConvertFrom-Json
$result.flash_start_address=$resources.flash_start_address
$result.bitstream_source=Join-Path $pnr ($ProjectName+'.fs')
$result.stability='Guitar passed; marginal piano baseline poles recorded in stability.json'
$result|ConvertTo-Json -Depth 8|Set-Content -Encoding utf8 (Join-Path $out 'verification.json')
Copy-Item $result.bitstream_source (Join-Path $out 'phase1_piano_guitar.fs') -Force
Copy-Item $htmlPath (Join-Path $out 'timing_report.html') -Force
$fingerprints=@()
foreach($line in Get-Content (Join-Path $root 'rtl/platform/tang_mega_138k_pro/sources.f')){
    if($line){$fingerprints+=@{file=$line;sha256=(Get-FileHash (Join-Path $root $line) -Algorithm SHA256).Hash.ToLowerInvariant()}}
}
$fingerprints|ConvertTo-Json -Depth 4|Set-Content -Encoding utf8 (Join-Path $out 'source_hashes.json')
$hashLines=Get-FileHash (Join-Path $out '*.bin'),(Join-Path $out '*.fs') -Algorithm SHA256 | ForEach-Object {'{0}  {1}' -f $_.Hash.ToLowerInvariant(),(Split-Path $_.Path -Leaf)}
$hashLines|Set-Content -Encoding ascii (Join-Path $out 'SHA256.txt')
Write-Output ($result|ConvertTo-Json -Depth 8)
