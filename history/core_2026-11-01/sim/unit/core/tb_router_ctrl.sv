`timescale 1ns/1ps
module tb_router_ctrl;
    logic clk=0,rst_n=0,cfg_valid=0,fmap_valid=0,load_req,key_pressed;
    logic [3:0] cfg_instrument=0,cfg_voice=0,instrument_id,load_voice;
    logic [6:0] cfg_note=0,load_note;
    logic [7:0] cfg_velocity=0,load_velocity;
    logic [16*8-1:0] fmap=0;
    logic [1:0] engine_sel;
    logic [15:0] coeff_base,ram_base,load_addr;
    int errors=0;
    router_ctrl u(.clk(clk),.rst_n(rst_n),.cfg_valid(cfg_valid),.cfg_instrument(cfg_instrument),
      .cfg_voice(cfg_voice),.cfg_note(cfg_note),.cfg_velocity(cfg_velocity),.fmap(fmap),.fmap_valid(fmap_valid),
      .instrument_id(instrument_id),.engine_sel(engine_sel),.coeff_base(coeff_base),.ram_base(ram_base),
      .load_req(load_req),.load_voice(load_voice),.load_note(load_note),.load_velocity(load_velocity),.load_addr(load_addr),
      .key_pressed(key_pressed));
    always #5 clk=~clk;
    initial begin
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        @(negedge clk); cfg_valid=1; cfg_instrument=4'd1; cfg_voice=4'd2; cfg_note=7'd60; cfg_velocity=8'd100;
        @(posedge clk); @(negedge clk); cfg_valid=0;
        @(posedge clk); #1;
        if (instrument_id != 4'd1) begin $display("FAIL id=%0d",instrument_id); errors++; end
        if (engine_sel != 2'd1) begin $display("FAIL engine=%0d",engine_sel); errors++; end
        if (coeff_base != 16'd8192) begin $display("FAIL coeff=%0d",coeff_base); errors++; end
        if (ram_base != 16'd320) begin $display("FAIL ram=%0d",ram_base); errors++; end
        if (load_voice != 4'd2 || load_note != 7'd60 || load_velocity != 8'd100) begin $display("FAIL load fields"); errors++; end
        @(negedge clk); fmap[0*8 +: 8]=8'h40; @(posedge clk); #1;
        if (!key_pressed) begin $display("FAIL key_pressed"); errors++; end
        if (errors==0) $display("PASS tb_router_ctrl");
        else $display("FAIL tb_router_ctrl errors=%0d",errors);
        $finish;
    end
endmodule
