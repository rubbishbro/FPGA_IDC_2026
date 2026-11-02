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
    pad_led_effects dut(.cr(cr),.force_map(force_map),.led_busy(busy),
        .led_frame_done(frame_done),.leds(leds));
    integer i, seen;
    initial begin
        repeat(10) @(posedge clk); rst_n=1;
        repeat(2000) @(posedge clk);
        force_values[8*5 +: 8] = 8'd160;
        repeat(4000) @(posedge clk);
        if(!dut.wave_valid[0]) $fatal(1,"no wave record");
        if(dut.wave_ram[0]===54'd0) $fatal(1,"wave RAM empty");
        // wait for a rendered wave slot: R_DISTANCE=7, wave 0, pad 5
        seen=0;
        for(i=0;i<130000;i=i+1) begin
            @(posedge clk);
            if(dut.state==7 && dut.wave_idx==0 && dut.wave_q[3:0]==4'd5) seen=1;
        end
        if(!seen) $fatal(1,"wave RAM record never reached R_DISTANCE");
        $display("PASS tb_led_ram_scan wave_valid=%h wave0=%h seen=%0d",dut.wave_valid,dut.wave_ram[0],seen);
        $finish;
    end
endmodule
