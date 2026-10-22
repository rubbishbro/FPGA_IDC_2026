`timescale 1ns/1ps
module tb_router_system_top;
    import modal_record_pkg::*;
    localparam int SLOTS=2, MA=48, ME=80, VW=1, MWA=6, MWE=7;
    logic clk=0, rst_n=0;
    logic load_valid, load_ready;
    logic [1:0] load_class;
    logic [VW-1:0] load_voice;
    logic [1:0] load_inst;
    logic [6:0] load_note;
    logic [7:0] load_vel;
    logic load_dyn;
    logic [11:0] load_note_id;
    logic load_done; logic [VW-1:0] done_voice; logic [MWA-1:0] lnm; logic load_error;
    logic off_valid; logic [VW-1:0] off_voice;
    logic [SLOTS*32-1:0] a_x;
    logic [SLOTS*16-1:0] a_xvel;
    logic [SLOTS*16-1:0] b_vel;
    logic [15:0] b_ratio;
    logic b_a1_en;
    logic [SLOTS*16-1:0] c_seedvel;
    logic [15:0] c_seed_base;
    logic e2_cfg_we; logic [VW-1:0] e2_cfg_voice; logic [MWE-1:0] e2_cfg_mode; logic [REC_W-1:0] e2_cfg_data;
    logic e2_clr_we; logic [VW-1:0] e2_clr_voice; logic [MWE-1:0] e2_clr_mode;
    logic e2_seed_we; logic [VW-1:0] e2_seed_voice; logic [MWE-1:0] e2_seed_mode; logic [63:0] e2_seed_data;
    logic [SLOTS*32-1:0] e2_x;
    logic [SLOTS*MWE-1:0] e2_nm;
    logic start, ready, busy, done, out_valid;
    logic signed [63:0] mix;
    int errors=0;

    router_system_top #(
        .NUM_SLOTS(SLOTS), .N_MODES_ABC(MA), .N_MODES_E2(ME), .LANES(4), .REC_W(REC_W),
        .A_COEFF_DEPTH(2), .A_INDEX_DEPTH(128),
        .A_COEFF_FILE("sim/unit/core/router_a_coeff.mem"),
        .A_INDEX_FILE("sim/unit/core/router_a_index.mem"),
        .BC_COEFF_DEPTH(8), .BC_INDEX_DEPTH(8192), .BC_CTRL_DEPTH(2), .BC_SEED_DEPTH(24),
        .BC_COEFF_FILE("sim/unit/core/router_bc_coeff.mem"),
        .BC_INDEX_FILE("sim/unit/core/router_bc_index.mem"),
        .BC_CTRL_FILE("sim/unit/core/router_bc_ctrl.mem"),
        .BC_SEED_FILE("sim/unit/core/router_bc_seed.mem"),
        .C_SEED_FILE("sim/unit/core/router_bc_seed.mem"),
        .E2_COEFF_DEPTH(2), .E2_INDEX_DEPTH(8192), .E2_CTRL_DEPTH(2), .E2_SEED_DEPTH(8),
        .E2_COEFF_FILE("sim/unit/core/router_e2_coeff.mem"),
        .E2_INDEX_FILE("sim/unit/core/router_e2_index.mem"),
        .E2_CTRL_FILE("sim/unit/core/router_e2_ctrl.mem"),
        .E2_SEED_FILE("sim/unit/core/router_e2_seed.mem"),
        .E2_L72_FILE("sim/unit/core/router_e2_l72.mem")
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready), .load_class(load_class),
        .load_voice(load_voice), .load_inst(load_inst), .load_note(load_note),
        .load_vel(load_vel), .load_dyn(load_dyn), .load_note_id(load_note_id),
        .rcfg_valid(1'b0), .rcfg_instrument(4'd0), .rcfg_voice(4'd0), .rcfg_note(7'd0),
        .rcfg_velocity(8'd0), .fmap(128'd0), .fmap_valid(1'b0),
        .load_done(load_done), .done_voice(done_voice), .loaded_n_modes(lnm), .load_error(load_error),
        .off_valid(off_valid), .off_voice(off_voice),
        .a_x(a_x), .a_x_vel(a_xvel),
        .b_vel(b_vel), .b_ratio(b_ratio), .b_a1_enable(b_a1_en),
        .c_seed_vel(c_seedvel), .c_seed_base(c_seed_base),
        .e2_cfg_we(e2_cfg_we), .e2_cfg_voice(e2_cfg_voice), .e2_cfg_mode(e2_cfg_mode), .e2_cfg_data(e2_cfg_data),
        .e2_clr_we(e2_clr_we), .e2_clr_voice(e2_clr_voice), .e2_clr_mode(e2_clr_mode),
        .e2_seed_we(e2_seed_we), .e2_seed_voice(e2_seed_voice), .e2_seed_mode(e2_seed_mode), .e2_seed_data(e2_seed_data),
        .e2_x(e2_x), .e2_nmodes(e2_nm),
        .start(start), .sample_ready(ready), .busy(busy), .done(done), .out_valid(out_valid), .mix_sum(mix)
    );

    always #5 clk=~clk;

    initial begin
        load_valid=0; load_class=0; load_voice=0; load_inst=0; load_note=0; load_vel=0; load_dyn=0; load_note_id=0;
        off_valid=0; off_voice=0;
        a_x='0; a_xvel={SLOTS{16'h8000}}; b_vel='0; b_ratio=16'h8000; b_a1_en=0;
        c_seedvel='0; c_seed_base=0;
        e2_cfg_we=0; e2_cfg_voice=0; e2_cfg_mode=0; e2_cfg_data=0;
        e2_clr_we=0; e2_clr_voice=0; e2_clr_mode=0;
        e2_seed_we=0; e2_seed_voice=0; e2_seed_mode=0; e2_seed_data=0;
        e2_x='0; e2_nm='0; start=0;

        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        a_x[0*32 +: 32]=32'sh1000_0000; // 0.25

        @(negedge clk); load_valid=1; load_class=0; load_voice=0;
        load_inst=0; load_note=7'd60; load_vel=8'd255; load_dyn=1; load_note_id=0;
        @(posedge clk); @(negedge clk); load_valid=0;
        wait (load_done); @(posedge clk); #1;
        if (load_error) begin $display("FAIL load_error"); errors++; end

        wait (ready);
        start=1; @(posedge clk); @(negedge clk); start=0;
        wait (done); @(posedge clk); #1;

        if (mix !== 64'sd536870912) begin // 2 modes * 0.25
            $display("FAIL mix=%0d exp=536870912", mix); errors++;
        end
        if (errors==0) $display("PASS tb_router_system_top");
        else           $display("FAIL tb_router_system_top errors=%0d", errors);
        $finish;
    end
endmodule
