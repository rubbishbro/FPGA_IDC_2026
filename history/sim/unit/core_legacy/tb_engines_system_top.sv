// -----------------------------------------------------------------------------
// tb_engines_system_top.sv -- 事件 + router + 四引擎 A-only 冒烟
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_engines_system_top;
    import modal_record_pkg::*;

    localparam int SLOTS=2, MA=4, ME=4, VW=1, MWA=2, MWE=3;
    logic clk=0, rst_n=0;

    logic note_on, note_off;
    logic [VW-1:0] nvoice;
    logic [1:0] nclass;

    logic [SLOTS*32-1:0] a_x;
    logic [SLOTS*16-1:0] a_xvel;
    logic [SLOTS*MWA-1:0] a_nm;
    logic [SLOTS*256-1:0] b_ctrl;
    logic [SLOTS*16-1:0] b_vel, b_theta;
    logic b_a1_en; logic [15:0] b_ratio;
    logic [SLOTS*MWA-1:0] b_nm;
    logic [SLOTS*20-1:0] c_len;
    logic [SLOTS*16-1:0] c_seedvel;
    logic [SLOTS*24-1:0] c_atk, c_rel;
    logic [SLOTS*MWA-1:0] c_nm;

    logic cfg_we; logic [1:0] cfg_engine; logic [VW-1:0] cfg_voice; logic [MWA-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic clr_we; logic [1:0] clr_engine; logic [VW-1:0] clr_voice; logic [MWA-1:0] clr_mode;
    logic seed_we; logic [1:0] seed_engine; logic [VW-1:0] seed_voice; logic [MWA-1:0] seed_mode; logic [63:0] seed_data;

    logic e2_cfg_we; logic [VW-1:0] e2_cfg_voice; logic [MWE-1:0] e2_cfg_mode; logic [REC_W-1:0] e2_cfg_data;
    logic e2_clr_we; logic [VW-1:0] e2_clr_voice; logic [MWE-1:0] e2_clr_mode;
    logic e2_seed_we; logic [VW-1:0] e2_seed_voice; logic [MWE-1:0] e2_seed_mode; logic [63:0] e2_seed_data;
    logic [SLOTS*32-1:0] e2_x;
    logic [SLOTS*MWE-1:0] e2_nm;

    logic start, ready, busy, done, out_valid;
    logic signed [63:0] mix;

    int errors=0;

    engines_system_top #(
        .NUM_SLOTS(SLOTS), .N_MODES_ABC(MA), .N_MODES_E2(ME), .LANES(4), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .note_on(note_on), .note_off(note_off), .note_voice(nvoice), .note_class(nclass),
        .a_x(a_x), .a_x_vel(a_xvel), .a_nmodes(a_nm),
        .b_ctrl(b_ctrl), .b_vel(b_vel), .b_theta(b_theta), .b_a1_enable(b_a1_en), .b_ratio(b_ratio), .b_nmodes(b_nm),
        .c_len(c_len), .c_seed_vel(c_seedvel), .c_attack(c_atk), .c_release(c_rel), .c_nmodes(c_nm),
        .c_seed_base(16'd0),
        .cfg_we(cfg_we), .cfg_engine(cfg_engine), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_engine(clr_engine), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_engine(seed_engine), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .e2_cfg_we(e2_cfg_we), .e2_cfg_voice(e2_cfg_voice), .e2_cfg_mode(e2_cfg_mode), .e2_cfg_data(e2_cfg_data),
        .e2_clr_we(e2_clr_we), .e2_clr_voice(e2_clr_voice), .e2_clr_mode(e2_clr_mode),
        .e2_seed_we(e2_seed_we), .e2_seed_voice(e2_seed_voice), .e2_seed_mode(e2_seed_mode), .e2_seed_data(e2_seed_data),
        .e2_x(e2_x), .e2_nmodes(e2_nm),
        .start(start), .sample_ready(ready), .busy(busy), .done(done), .out_valid(out_valid), .mix_sum(mix)
    );

    always #5 clk = ~clk;

    initial begin
        note_on=0; note_off=0; nvoice='0; nclass='0;
        a_x='0; a_xvel={SLOTS{16'h8000}}; a_nm='0;
        b_ctrl='0; b_vel='0; b_theta='0; b_a1_en=0; b_ratio=16'h8000; b_nm='0;
        c_len='0; c_seedvel='0; c_atk='0; c_rel='0; c_nm='0;
        cfg_we=0; cfg_engine='0; cfg_voice='0; cfg_mode='0; cfg_data='0;
        clr_we=0; clr_engine='0; clr_voice='0; clr_mode='0;
        seed_we=0; seed_engine='0; seed_voice='0; seed_mode='0; seed_data='0;
        e2_cfg_we=0; e2_cfg_voice='0; e2_cfg_mode='0; e2_cfg_data='0;
        e2_clr_we=0; e2_clr_voice='0; e2_clr_mode='0;
        e2_seed_we=0; e2_seed_voice='0; e2_seed_mode='0; e2_seed_data='0;
        e2_x='0; e2_nm='0; start=0;

        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        cfg_data=rec_set(0,E1_G,32'h0100_0000);
        @(negedge clk); cfg_we=1; cfg_engine=0; cfg_voice=0; cfg_mode=0;
        @(posedge clk); @(negedge clk); cfg_we=0;

        a_x[0*32 +: 32]=32'sh1000_0000;
        a_nm[0*MWA +: MWA]=2'd1;

        @(negedge clk); note_on=1; nvoice=0; nclass=0;
        @(posedge clk); @(negedge clk); note_on=0;

        wait (ready);
        start=1; @(posedge clk); @(negedge clk); start=0;
        wait (done); #1;

        if (mix !== 64'sd268435456) begin
            $display("FAIL mix=%0d exp=268435456", mix); errors++;
        end
        if (errors==0) $display("PASS tb_engines_system_top");
        else           $display("FAIL tb_engines_system_top errors=%0d", errors);
        $finish;
    end
endmodule
