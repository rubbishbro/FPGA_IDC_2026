`timescale 1ns/1ps
module tb_router_frontend;
    logic clk=0,rst_n=0,cfg_valid=0,fmap_valid=0,load_req,key_pressed,x_valid;
    logic [3:0] cfg_instrument=0,cfg_voice=0,instrument_id,load_voice;
    logic [6:0] cfg_note=0,load_note;
    logic [7:0] cfg_velocity=0,load_velocity;
    logic [16*8-1:0] fmap=0;
    logic [1:0] engine_sel;
    logic [15:0] coeff_base,ram_base,load_addr,velocity;
    logic signed [31:0] x;
    int errors=0;
    router_frontend u(.clk(clk),.rst_n(rst_n),.cfg_valid(cfg_valid),.cfg_instrument(cfg_instrument),
      .cfg_voice(cfg_voice),.cfg_note(cfg_note),.cfg_velocity(cfg_velocity),.fmap(fmap),.fmap_valid(fmap_valid),
      .instrument_id(instrument_id),.engine_sel(engine_sel),.coeff_base(coeff_base),.ram_base(ram_base),
      .load_req(load_req),.load_voice(load_voice),.load_note(load_note),.load_velocity(load_velocity),.load_addr(load_addr),
      .key_pressed(key_pressed),.velocity(velocity),.x(x),.x_valid(x_valid));
    always #5 clk=~clk;
    initial begin
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        @(negedge clk); cfg_valid=1; cfg_instrument=4'd1; cfg_voice=4'd2; cfg_note=7'd60; cfg_velocity=8'd100;
        fmap[0*8 +: 8]=8'd128; fmap_valid=1;
        @(posedge clk); @(negedge clk); cfg_valid=0;
        @(posedge clk); #1;
        if (instrument_id != 4'd1) begin $display("FAIL id"); errors++; end
        if (engine_sel != 2'd1) begin $display("FAIL engine"); errors++; end
        if (load_voice != 4'd2 || load_note != 7'd60) begin $display("FAIL load"); errors++; end
        if (!key_pressed || !x_valid) begin $display("FAIL pressed/xvalid"); errors++; end
        if (velocity != 16'd16384 || x != 32'sd536870912) begin $display("FAIL vel=%0d x=%0d",velocity,x); errors++; end
        if (errors==0) $display("PASS tb_router_frontend");
        else $display("FAIL tb_router_frontend errors=%0d",errors);
        $finish;
    end
endmodule
