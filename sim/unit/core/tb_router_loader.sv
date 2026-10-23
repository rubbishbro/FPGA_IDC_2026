`timescale 1ns/1ps
module tb_router_loader;
    import modal_record_pkg::*;
    localparam int SLOTS=2, MODES=4, VW=1, MW=3;
    logic clk=0, rst_n=0;
    logic load_valid, load_ready;
    logic [1:0] load_class; logic [VW-1:0] load_voice; logic [1:0] load_inst;
    logic [6:0] load_note; logic [7:0] load_vel; logic load_dyn; logic [11:0] load_note_id;
    logic a_cfg_we; logic [VW-1:0] a_cfg_voice; logic [MW-1:0] a_cfg_mode; logic [REC_W-1:0] a_cfg_data;
    logic a_clr_we; logic [VW-1:0] a_clr_voice; logic a_ready,a_done,a_err;
    logic [VW-1:0] a_done_voice; logic [MW-1:0] a_n; logic [2:0] a_ecode;
    logic bc_cfg_we,bc_clr_we,bc_seed_valid,bc_ready,bc_done,bc_err;
    logic [VW-1:0] bc_cfg_voice,bc_clr_voice,bc_seed_voice,bc_done_voice;
    logic [MW-1:0] bc_cfg_mode,bc_seed_mode,bc_n; logic [REC_W-1:0] bc_cfg_data;
    logic [63:0] bc_seed_word; logic [255:0] bc_ctrl; logic [15:0] bc_theta; logic [1:0] bc_class; logic [2:0] bc_ecode;
    logic e2_cfg_we,e2_clr_we,e2_seed_valid,e2_ready,e2_done,e2_err;
    logic [VW-1:0] e2_cfg_voice,e2_clr_voice,e2_seed_voice,e2_done_voice;
    logic [MW-1:0] e2_cfg_mode,e2_seed_mode,e2_n; logic [REC_W-1:0] e2_cfg_data;
    logic [63:0] e2_seed_word; logic [15:0] e2_theta; logic [2:0] e2_ecode;
    int errors=0, cfg_cnt=0;
    logic [REC_W-1:0] cfgs[0:7];

    router_loader #(.NUM_SLOTS(SLOTS),.N_MODES_ABC(MODES),.N_MODES_E2(MODES),.REC_W(REC_W),
      .A_COEFF_DEPTH(2),.A_INDEX_DEPTH(128),.A_COEFF_FILE("sim/unit/core/router_a_coeff.mem"),
      .A_INDEX_FILE("sim/unit/core/router_a_index.mem"),
      .BC_COEFF_DEPTH(2),.BC_INDEX_DEPTH(16),.BC_CTRL_DEPTH(2),.BC_SEED_DEPTH(4),
      .BC_COEFF_FILE("sim/unit/core/router_bc_coeff.mem"),.BC_INDEX_FILE("sim/unit/core/router_bc_index.mem"),
      .BC_CTRL_FILE("sim/unit/core/router_bc_ctrl.mem"),.BC_SEED_FILE("sim/unit/core/router_bc_seed.mem"),
      .E2_COEFF_DEPTH(2),.E2_INDEX_DEPTH(16),.E2_CTRL_DEPTH(2),.E2_SEED_DEPTH(4),
      .E2_COEFF_FILE("sim/unit/core/router_e2_coeff.mem"),.E2_INDEX_FILE("sim/unit/core/router_e2_index.mem"),
      .E2_CTRL_FILE("sim/unit/core/router_e2_ctrl.mem"),.E2_SEED_FILE("sim/unit/core/router_e2_seed.mem"),
      .E2_L72_FILE("sim/unit/core/router_e2_l72.mem")) dut (
      .clk(clk),.rst_n(rst_n),.load_valid(load_valid),.load_ready(load_ready),
      .load_class(load_class),.load_voice(load_voice),.load_inst(load_inst),.load_note(load_note),
      .load_vel(load_vel),.load_dyn(load_dyn),.load_note_id(load_note_id),
      .a_cfg_we(a_cfg_we),.a_cfg_voice(a_cfg_voice),.a_cfg_mode(a_cfg_mode),.a_cfg_data(a_cfg_data),
      .a_clr_we(a_clr_we),.a_clr_voice(a_clr_voice),.a_ready(a_ready),.a_done(a_done),.a_err(a_err),
      .a_done_voice(a_done_voice),.a_n(a_n),.a_ecode(a_ecode),
      .bc_cfg_we(bc_cfg_we),.bc_cfg_voice(bc_cfg_voice),.bc_cfg_mode(bc_cfg_mode),.bc_cfg_data(bc_cfg_data),
      .bc_clr_we(bc_clr_we),.bc_clr_voice(bc_clr_voice),.bc_seed_valid(bc_seed_valid),.bc_seed_voice(bc_seed_voice),
      .bc_seed_mode(bc_seed_mode),.bc_seed_word(bc_seed_word),.bc_ctrl(bc_ctrl),.bc_theta(bc_theta),
      .bc_class(bc_class),.bc_ready(bc_ready),.bc_done(bc_done),.bc_err(bc_err),.bc_done_voice(bc_done_voice),
      .bc_n(bc_n),.bc_ecode(bc_ecode),
      .e2_cfg_we(e2_cfg_we),.e2_cfg_voice(e2_cfg_voice),.e2_cfg_mode(e2_cfg_mode),.e2_cfg_data(e2_cfg_data),
      .e2_clr_we(e2_clr_we),.e2_clr_voice(e2_clr_voice),.e2_seed_valid(e2_seed_valid),.e2_seed_voice(e2_seed_voice),
      .e2_seed_mode(e2_seed_mode),.e2_seed_word(e2_seed_word),.e2_ready(e2_ready),.e2_done(e2_done),
      .e2_err(e2_err),.e2_done_voice(e2_done_voice),.e2_n(e2_n),.e2_theta(e2_theta),.e2_ecode(e2_ecode));
    always #5 clk=~clk;
    always_ff @(posedge clk) if (a_cfg_we) begin cfgs[cfg_cnt] <= a_cfg_data; cfg_cnt <= cfg_cnt+1; end
    initial begin
      load_valid=0; load_class=0; load_voice=0; load_inst=0; load_note=0; load_vel=255; load_dyn=0; load_note_id=0;
      repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
      @(negedge clk); load_valid=1; load_class=0; load_voice=0; load_note=7'd60; load_dyn=1;
      @(posedge clk); @(negedge clk); load_valid=0;
      wait(a_done); @(posedge clk); #1;
      if (a_err) begin $display("FAIL err=%0d",a_ecode); errors++; end
      if (cfg_cnt != 2) begin $display("FAIL cfg=%0d",cfg_cnt); errors++; end
      if (a_n != 3'd2) begin $display("FAIL n=%0d",a_n); errors++; end
      if (rec_get(cfgs[0],E1_G) !== 32'h01000000) begin $display("FAIL G=%h",rec_get(cfgs[0],E1_G)); errors++; end
      if (errors==0) $display("PASS tb_router_loader"); else $display("FAIL tb_router_loader errors=%0d",errors);
      $finish;
    end
endmodule
