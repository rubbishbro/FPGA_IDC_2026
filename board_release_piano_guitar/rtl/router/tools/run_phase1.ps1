param([string]$ModelSim='D:/gowin/win64')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$out=Join-Path $root 'build/phase1_sim'
$null=New-Item -ItemType Directory -Force $out
Copy-Item (Join-Path $root 'build/phase1_delivery/MEM.TXT') $out -Force
Copy-Item (Join-Path $root 'build/phase1_delivery/piano_guitar_16.mem') $out -Force
foreach($file in @('SECSI.TXT','SFDP.TXT','SREG.TXT')){Copy-Item (Join-Path $root "rtl/router/tb/vendor/w25q128/$file") $out -Force}
$sources=@()
foreach($line in Get-Content (Join-Path $root 'rtl/platform/tang_mega_138k_pro/sources.f')){
    if($line){$sources+=(Join-Path $root $line)}
    if($line -eq 'rtl/router/midi_voice_top.sv'){break}
}
$sources+=@("$root/rtl/router/tb/vendor/w25q128/W25Q128JVxIM.v","$root/rtl/router/tb/w25q_dut.sv","$root/rtl/router/tb/tb_phase1.sv")
Push-Location $out
try{
    if(!(Test-Path 'work')){& "$ModelSim/vlib.exe" work;if($LASTEXITCODE){throw 'vlib failed'}}
    & "$ModelSim/vlog.exe" -sv -work work @sources *> compile.log
    if($LASTEXITCODE){Get-Content compile.log -Tail 35;throw 'vlog failed'}
    & "$ModelSim/vsim.exe" -c -voptargs=+acc work.tb_phase1 -do 'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0' *> simulation.log
    $code=$LASTEXITCODE
    Get-Content simulation.log -Tail 20
    if($code -or !(Select-String -Path simulation.log -SimpleMatch 'PASS tb_phase1') -or (Select-String -Path simulation.log -Pattern '\*\* (Error|Fatal)|FAIL ')){throw 'phase1 simulation failed'}
}finally{Pop-Location}
