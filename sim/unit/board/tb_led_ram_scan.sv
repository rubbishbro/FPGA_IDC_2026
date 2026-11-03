`timescale 1ns/1ps
module tb_led_ram_scan;
    import clk_rst_pkg::*;
    import pad_driver_pkg::*;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    int div=0;
    wire ce=div==3;
    always @(posedge clk) if(!rst_n||ce) div<=0; else div<=div+1;
    clk_rst cr; assign cr={clk,ce,rst_n};
    logic [127:0] force_values=0;
    mat4x4 force_map; assign force_map=force_values;
    led_param leds;
    wire busy, frame_done;
    assign busy=1'b0;
    assign frame_done=1'b0;
    pad_led_effects dut(.cr(cr),.force_map(force_map),.led_busy(busy),
        .led_frame_done(frame_done),.leds(leds));
    integer i, seen;
    integer dx,dy,addr,checks=0;
    logic [2:0] seen_slots=0;
    // Check the distance actually consumed, including transitions between
    // different wave origins. Correct record storage alone cannot catch this.
    always @(posedge clk) if(rst_n && dut.state==dut.R_DISTANCE) begin
        dx=2*int'(dut.pixel_idx[2:0])-(4*int'(dut.wave_q[1:0])+1);
        dy=2*int'(dut.pixel_idx[5:3])-(4*int'(dut.wave_q[3:2])+1);
        if(dx<0) dx=-dx;
        if(dy<0) dy=-dy;
        addr=(dy/2)*8+dx/2;
        if(dut.distance_q !== dut.distance_rom[addr])
            $fatal(1,"stale wave distance slot=%0d pad=%0d pixel=%0d",dut.wave_idx,dut.wave_q[3:0],dut.pixel_idx);
        checks=checks+1;
        if(dut.wave_idx<3) seen_slots[dut.wave_idx]=1'b1;
    end
    initial begin
        repeat(10) @(negedge clk); rst_n=1;
        repeat(2000) @(negedge clk);
        force_values[8*0 +: 8] = 8'd160;
        repeat(40) @(negedge clk);
        force_values=0;
        force_values[8*15 +: 8] = 8'd160;
        repeat(40) @(negedge clk);
        force_values=0;
        force_values[8*3 +: 8] = 8'd160;
        repeat(4000) @(negedge clk);
        if(!dut.wave_valid[0]) $fatal(1,"no wave record");
        if(dut.wave_valid[2:0]!==3'b111 || dut.wave_ram[0][3:0]!==4'd0 ||
           dut.wave_ram[1][3:0]!==4'd15 || dut.wave_ram[2][3:0]!==4'd3)
            $fatal(1,"wave RAM origins do not match consecutive strikes");
        // Wait for all three distinct origins to reach distance consumption.
        seen=0;
        for(i=0;i<130000;i=i+1) begin
            @(posedge clk);
            if(dut.state==dut.R_DISTANCE && dut.wave_idx==0 && dut.wave_q[3:0]==4'd0) seen=1;
        end
        if(!seen) $fatal(1,"wave RAM record never reached R_DISTANCE");
        if(seen_slots!==3'b111 || checks<192) $fatal(1,"insufficient multi-origin distance coverage");
        $display("PASS tb_led_ram_scan wave_valid=%h wave0=%h seen=%0d",dut.wave_valid,dut.wave_ram[0],seen);
        $finish;
    end
endmodule
