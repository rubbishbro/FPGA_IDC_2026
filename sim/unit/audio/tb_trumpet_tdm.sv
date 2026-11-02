`timescale 1ns/1ps
module tb_trumpet_tdm;
logic clk=0,rst_n=0,tick=0,enable=1,clear=0;
always #10 clk=~clk;
logic [255:0] periods='0;
logic [383:0] pitch='0;
logic [127:0] level='0;
logic [15:0] gate=0,trigger=0,slot_clear=0;
logic signed [15:0][31:0] x;
logic valid;
trumpet_excitation dut(.clk(clk),.rst_n(rst_n),.clk_en(tick),.enable(enable),.clear(clear),
.slot_period(periods),.slot_pitch_delta(pitch),.strike_level(level),.note_on(gate),
.retrigger(trigger),.slot_clear(slot_clear),.xmap(x),.xmap_valid(valid));
integer f,rc,action,g,t,c,n,value,cycles,max_cycles=0,frames=0,expected[16];
logic [511:0] before_publish;
logic [255:0] saved_periods;
logic [127:0] saved_level;
initial begin
repeat(3)@(negedge clk);rst_n=1;
f=$fopen("vectors.txt","r");if(!f)$fatal(1,"vectors missing");
while(!$feof(f))begin
rc=$fscanf(f,"%d %d %d %d",action,g,t,c);if(rc!=4)begin if($feof(f))break;else $fatal(1,"vector header");end
if(action!=0)begin
    // Abort an in-flight job without a sample tick, or disable between ticks.
    if(action==3)begin tick=1;@(negedge clk);tick=0;repeat(9)@(negedge clk);end
    if(action==2)enable=0;else clear=1;
    @(negedge clk);
    if(x!==512'd0 || valid)$fatal(1,"clear/disable did not cancel");
    clear=0;enable=1;repeat(200)begin @(negedge clk);if(valid)$fatal(1,"cancelled frame published");end
end
for(n=0;n<16;n++)begin rc=$fscanf(f,"%d",value);periods[n*16 +:16]=16'(value);end
for(n=0;n<16;n++)begin rc=$fscanf(f,"%d",value);level[n*8 +:8]=8'(value);end
for(n=0;n<16;n++)begin rc=$fscanf(f,"%d",value);pitch[n*24 +:24]=24'(value);end
for(n=0;n<16;n++)rc=$fscanf(f,"%d",expected[n]);
gate=16'(g);trigger=16'(t);slot_clear=16'(c);
saved_periods=periods;saved_level=level;before_publish=dut.published_x;
tick=1;@(negedge clk);tick=0;cycles=0;
while(!valid && cycles<208)begin
    if(dut.published_x!==before_publish)$fatal(1,"partial frame visible");
    // Perturb live inputs after capture: the result must use the held frame.
    periods='0;level='0;
    @(negedge clk);cycles++;
end
periods=saved_periods;level=saved_level;
if(!valid)$fatal(1,"missed excitation budget");
if(cycles>max_cycles)max_cycles=cycles;
for(n=0;n<16;n++)if(x[n]!==expected[n])$fatal(1,"frame=%d slot=%d got=%d expected=%d",frames,n,x[n],expected[n]);
frames++;repeat(3)@(negedge clk);
if(valid)$fatal(1,"completion not a single pulse");
end
$fclose(f);
if(frames!=6500)$fatal(1,"incomplete vectors");
$display("PASS tb_trumpet_tdm frames=%d slots=16 checks=%d max_cycles=%d atomic snapshot clear abort disable random pitch all32periods",frames,frames*16,max_cycles);
$finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule
