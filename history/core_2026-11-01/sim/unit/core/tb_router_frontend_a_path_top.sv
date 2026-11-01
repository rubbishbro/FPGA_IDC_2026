`timescale 1ns/1ps
module tb_router_frontend_a_path_top;
    import modal_record_pkg::*;
    logic clk=0,rst_n=0; logic cfg_valid=0,fmap_valid=0,a_start=0; logic [3:0] ci=0,cv=0; logic [6:0] cn=0; logic [7:0] cvel=0;
    logic [16*8-1:0] fmap=0; logic [3:0] ii; logic [1:0] es; logic kp; logic [15:0] vel; logic signed [31:0] x;
    logic a_cfg=0,a_clr=0,a_seed=0; logic [0:0] av=0,acv=0,asv=0; logic [5:0] am=0,acm=0,asm=0; logic [287:0] ad=0; logic [63:0] asd=0;
    logic [1:0] aact=0; logic [11:0] anm=0;
    logic e2_cfg=0,e2_clr=0,e2_seed=0; logic [0:0] ev=0,ecv=0,esv=0; logic [6:0] em=0,ecm=0,esm=0; logic [287:0] ed=0; logic [63:0] esd=0;
    logic [1:0] eact=0,ez=0; logic [63:0] ex=0; logic [13:0] enm=0;
    logic ready,busy,done,outv; logic signed [63:0] mix; int errors=0;
    router_frontend_a_path_top #(.NUM_SLOTS(2),.N_MODES_ABC(48),.N_MODES_E2(80),.LANES(4),.REC_W(288)) dut(
      .clk(clk),.rst_n(rst_n),.cfg_valid(cfg_valid),.cfg_instrument(ci),.cfg_voice(cv),.cfg_note(cn),.cfg_velocity(cvel),.fmap(fmap),.fmap_valid(fmap_valid),
      .a_cfg_we(a_cfg),.a_cfg_voice(av),.a_cfg_mode(am),.a_cfg_data(ad),.a_clr_we(a_clr),.a_clr_voice(acv),.a_clr_mode(acm),
      .a_seed_we(a_seed),.a_seed_voice(asv),.a_seed_mode(asm),.a_seed_data(asd),.a_start(a_start),.a_active(aact),.a_nmodes(anm),
      .e2_cfg_we(e2_cfg),.e2_cfg_voice(ev),.e2_cfg_mode(em),.e2_cfg_data(ed),.e2_clr_we(e2_clr),.e2_clr_voice(ecv),.e2_clr_mode(ecm),
      .e2_seed_we(e2_seed),.e2_seed_voice(esv),.e2_seed_mode(esm),.e2_seed_data(esd),.e2_start(0),.e2_active(eact),.e2_zero(ez),.e2_x(ex),.e2_nmodes(enm),
      .sample_ready(ready),.busy(busy),.done(done),.out_valid(outv),.mix_sum(mix),.instrument_id(ii),.engine_sel(es),.key_pressed(kp),.velocity(vel),.x(x));
    always #5 clk=~clk;
    initial begin
      repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
      ad=0; ad=rec_set(ad,E1_G,32'sh0100_0000); am=0; av=0;
      @(negedge clk); a_cfg=1; @(posedge clk); @(negedge clk); a_cfg=0;
      fmap[0*8 +:8]=8'd128; fmap_valid=1; cfg_valid=1; ci=4'd0; cv=0; cn=7'd60; cvel=8'd128;
      aact=2'b01; anm[0*6 +:6]=6'd1;
      @(posedge clk); @(negedge clk); cfg_valid=0;
      wait(ready); @(negedge clk); a_start=1; @(posedge clk); @(negedge clk); a_start=0;
      wait(done); @(posedge clk); #1;
      if (mix == 0) begin $display("FAIL mix=0"); errors++; end
      if (!kp) begin $display("FAIL kp"); errors++; end
      if (errors==0) $display("PASS tb_router_frontend_a_path_top"); else $display("FAIL tb_router_frontend_a_path_top errors=%0d",errors);
      $finish;
    end
endmodule
