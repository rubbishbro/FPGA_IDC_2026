`timescale 1ns/1ps
module tb_shared_modal_ram;
    import modal_record_pkg::*;
    localparam SLOTS=2, MODES=80, LANES=4;
    logic clk=0,rst_n=0;
    logic [3:0] state_first;
    logic cfg_we; logic [0:0] cfg_voice; logic [6:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic [LANES-1:0] st_we,rd_re; logic [LANES*6-1:0] st_addr,rd_addr;
    logic [LANES*64-1:0] st_data; logic [LANES*REC_W-1:0] rd_data;
    logic clr_we; logic [0:0] clr_voice; logic [6:0] clr_mode;
    logic seed_we; logic [0:0] seed_voice; logic [6:0] seed_mode; logic [63:0] seed_data;
    logic aux_re; logic [0:0] aux_voice; logic [6:0] aux_mode; logic [REC_W-1:0] aux_data; logic aux_valid;
    logic co_we; logic [0:0] co_voice; logic [6:0] co_mode; logic [3:0] co_field; logic [31:0] co_wdata;
    int errors=0;
    shared_modal_ram #(.SLOTS(SLOTS),.MODES(MODES),.LANES(LANES),.REC_W(REC_W)) dut (
      .clk(clk),.rst_n(rst_n),.cfg_first(state_first),.st_first(state_first),
      .cfg_we(cfg_we),.cfg_voice(cfg_voice),.cfg_mode(cfg_mode),.cfg_data(cfg_data),
      .st_we(st_we),.st_addr(st_addr),.st_data(st_data),
      .rd_re(rd_re),.rd_addr(rd_addr),.rd_data(rd_data),
      .clr_we(clr_we),.clr_voice(clr_voice),.clr_mode(clr_mode),
      .seed_we(seed_we),.seed_voice(seed_voice),.seed_mode(seed_mode),.seed_data(seed_data),
      .aux_re(aux_re),.aux_voice(aux_voice),.aux_mode(aux_mode),.aux_data(aux_data),.aux_valid(aux_valid),
      .co_we(co_we),.co_voice(co_voice),.co_mode(co_mode),.co_field(co_field),.co_wdata(co_wdata)
    );
    always #5 clk=~clk;
    initial begin
      cfg_we=0;cfg_voice=0;cfg_mode=0;cfg_data=0;st_we=0;st_addr=0;st_data=0;rd_re=0;rd_addr=0;
      clr_we=0;clr_voice=0;clr_mode=0;seed_we=0;seed_voice=0;seed_mode=0;seed_data=0;
      aux_re=0;aux_voice=0;aux_mode=0;co_we=0;co_voice=0;co_mode=0;co_field=0;co_wdata=0;state_first=3;
      repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
      cfg_data='0; cfg_data=rec_set(cfg_data,E1_G,32'sh0100_0000);
      @(negedge clk); cfg_we=1; cfg_voice=0; cfg_mode=0;
      @(posedge clk); @(negedge clk); cfg_we=0;
      @(negedge clk); rd_re=4'b0001; rd_addr[0*6 +: 6]=0;
      @(posedge clk); @(posedge clk); #1;
      if (rd_data[0*REC_W +: 32] !== 32'sh0100_0000) begin $display("FAIL cfg read=%h",rd_data[0*32 +:32]);errors++;end
      // seed A fields3/4
      @(negedge clk); seed_we=1; seed_voice=0; seed_mode=0; seed_data={32'sh22222222,32'sh11111111};
      @(posedge clk); @(negedge clk); seed_we=0;
      @(negedge clk); rd_re=4'b0001; rd_addr[0*6 +: 6]=0;
      @(posedge clk); @(posedge clk); #1;
      if (rd_data[3*32 +: 32] !== 32'sh11111111 || rd_data[4*32 +: 32] !== 32'sh22222222) begin $display("FAIL seed A %h %h",rd_data[3*32+:32],rd_data[4*32+:32]);errors++;end
      // E2 seed fields7/8
      state_first=7;
      @(negedge clk); seed_we=1; seed_voice=0; seed_mode=0; seed_data={32'sh44444444,32'sh33333333};
      @(posedge clk); @(negedge clk); seed_we=0;
      @(negedge clk); rd_re=4'b0001; rd_addr[0*6 +: 6]=0;
      @(posedge clk); @(posedge clk); #1;
      if (rd_data[7*32 +: 32] !== 32'sh33333333 || rd_data[8*32 +: 32] !== 32'sh44444444) begin $display("FAIL seed E2 %h %h",rd_data[7*32+:32],rd_data[8*32+:32]);errors++;end
      if(errors==0) $display("PASS tb_shared_modal_ram"); else $display("FAIL tb_shared_modal_ram errors=%0d",errors);
      $finish;
    end
endmodule
