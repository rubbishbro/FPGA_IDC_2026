`timescale 1ns/1ps
module tb_pitch_excitation;
    logic clk=0,rst_n=0,tick=0;
    always #5 clk=~clk;
    logic [15:0] gate=0,trigger=0,clear=0;
    logic [383:0] delta=0;
    logic [255:0] periods;
    logic signed [15:0][31:0] x;
    logic xv;
    integer fd,rc,gi,ci,ti,ei,di,count=0,pulses=0;
    excitation_gen #(.SLOTS(16),.SUSTAIN_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst_n),.clk_en(tick),.sustain_mode(1'b1),.slot_period(periods),.slot_pitch_delta(delta),
        .SHIFT(6'd16),.RISE_SH(6'd0),.PW_LEN(16'd1),.GAP_LEN(16'd0),.N_PULSE(3'd7),.clear(1'b0),
        .strike_level({16{8'd255}}),.retrigger(trigger),.slot_clear(clear),.note_on(gate),.xmap(x),.xmap_valid(xv));
    initial begin
        fd=$fopen("pitch_phase.txt","r");if(!fd)$fatal(1,"FAIL phase vectors absent");
        for(int s=0;s<16;s++)begin rc=$fscanf(fd,"%d",di);periods[s*16 +:16]=16'(di);end
        repeat(4)@(negedge clk);rst_n=1;
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%d %d %d %d",gi,ci,ti,ei);if(rc!=4)break;
            gate=16'(gi);clear=16'(ci);trigger=16'(ti);
            for(int s=0;s<16;s++)begin rc=$fscanf(fd,"%d",di);delta[s*24 +:24]=24'(di);end
            tick=1;@(negedge clk);tick=0;
            for(int s=0;s<16;s++)begin
                if(x[s] !== (ei[s]?32'sd16711680:32'sd0))$fatal(1,"FAIL pitch phase sample=%d slot=%d x=%d pulse=%b",count,s,x[s],ei[s]);
                if(ei[s])pulses++;
            end
            repeat(2)@(negedge clk);count++;
        end
        if(count!=70000)$fatal(1,"FAIL phase vector coverage");
        $display("PASS tb_pitch_excitation samples=%0d slots=16 pulses=%0d fractional_phase continuity retrigger zero_ratio_legacy",count,pulses);$finish;
    end
    initial begin #4000000;$fatal(1,"FAIL pitch phase timeout");end
endmodule
