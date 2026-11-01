`timescale 1ns/1ps
module tb_shared_engines_post;
    import modal_record_pkg::*;
    localparam int SLOTS=2, MA=48, ME=80, VW=1, MWA=6, MWE=7;
    logic clk=0, rst_n=0;
    logic cfg_we; logic [1:0] cfg_engine; logic [VW-1:0] cfg_voice; logic [MWA-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic clr_we; logic [1:0] clr_engine; logic [VW-1:0] clr_voice; logic [MWA-1:0] clr_mode;
    logic seed_we; logic [1:0] seed_engine; logic [VW-1:0] seed_voice; logic [MWA-1:0] seed_mode; logic [63:0] seed_data;
    logic [SLOTS-1:0] a_ns,a_gate,a_active; logic [SLOTS*32-1:0] a_x; logic [SLOTS*16-1:0] a_xvel; logic [SLOTS*MWA-1:0] a_nm;
    logic [SLOTS*256-1:0] b_ctrl; logic [SLOTS*2-1:0] b_class; logic [SLOTS*16-1:0] b_vel,b_theta;
    logic b_a1_en; logic [15:0] b_ratio; logic [SLOTS-1:0] b_ns,b_gate,b_active; logic [SLOTS*MWA-1:0] b_nm;
    logic [SLOTS-1:0] c_ns,c_choke; logic [SLOTS*20-1:0] c_len; logic [SLOTS*16-1:0] c_svel;
    logic [SLOTS*24-1:0] c_atk,c_rel; logic [SLOTS*MWA-1:0] c_nm; logic c_sld; logic [VW-1:0] c_slv; logic [MWA-1:0] c_sln; logic [15:0] c_sb;
    logic e2_cfg_we; logic [VW-1:0] e2_cfg_voice; logic [MWE-1:0] e2_cfg_mode; logic [REC_W-1:0] e2_cfg_data;
    logic e2_clr_we; logic [VW-1:0] e2_clr_voice; logic [MWE-1:0] e2_clr_mode;
    logic e2_seed_we; logic [VW-1:0] e2_seed_voice; logic [MWE-1:0] e2_seed_mode; logic [63:0] e2_seed_data;
    logic [SLOTS-1:0] e2_active,e2_zero; logic [SLOTS*32-1:0] e2_x; logic [SLOTS*MWE-1:0] e2_nm;
    logic start, ready, busy, done, outv; logic signed [63:0] mix;
    int errors=0;
    logic out_seen;

    shared_engines_top #(.POST_EN(1),.NUM_SLOTS(SLOTS),.N_MODES_ABC(MA),.N_MODES_E2(ME),.LANES(4),.REC_W(REC_W)) dut (
        .clk(clk),.rst_n(rst_n),
        .cfg_we(cfg_we),.cfg_engine(cfg_engine),.cfg_voice(cfg_voice),.cfg_mode(cfg_mode),.cfg_data(cfg_data),
        .clr_we(clr_we),.clr_engine(clr_engine),.clr_voice(clr_voice),.clr_mode(clr_mode),
        .seed_we(seed_we),.seed_engine(seed_engine),.seed_voice(seed_voice),.seed_mode(seed_mode),.seed_data(seed_data),
        .a_note_start(a_ns),.a_gate(a_gate),.a_active(a_active),.a_x(a_x),.a_x_vel(a_xvel),.a_nmodes(a_nm),
        .b_ctrl(b_ctrl),.b_class(b_class),.b_vel(b_vel),.b_theta(b_theta),.b_a1_enable(b_a1_en),.b_ratio(b_ratio),
        .b_note_start(b_ns),.b_gate(b_gate),.b_active(b_active),.b_nmodes(b_nm),.b_x('0),
        .c_note_start(c_ns),.c_choke(c_choke),.c_active('0),.c_len(c_len),.c_seed_vel(c_svel),.c_attack(c_atk),.c_release(c_rel),
        .c_nmodes(c_nm),.c_seed_load_start(c_sld),.c_seed_load_voice(c_slv),.c_seed_load_nmodes(c_sln),.c_seed_base(c_sb),
        .e2_cfg_we(e2_cfg_we),.e2_cfg_voice(e2_cfg_voice),.e2_cfg_mode(e2_cfg_mode),.e2_cfg_data(e2_cfg_data),
        .e2_clr_we(e2_clr_we),.e2_clr_voice(e2_clr_voice),.e2_clr_mode(e2_clr_mode),
        .e2_seed_we(e2_seed_we),.e2_seed_voice(e2_seed_voice),.e2_seed_mode(e2_seed_mode),.e2_seed_data(e2_seed_data),
        .e2_active(e2_active),.e2_zero(e2_zero),.e2_x(e2_x),.e2_nmodes(e2_nm),
        .start(start),.sample_ready(ready),.busy(busy),.done(done),.out_valid(outv),.mix_sum(mix)
    );
    always #5 clk=~clk;
    always @(posedge clk) if (outv) out_seen <= 1'b1;

    task automatic run();
        begin
            wait(ready); @(negedge clk); start=1;
            @(posedge clk); @(negedge clk); start=0;
            wait(done); @(posedge clk); #1;
        end
    endtask

    initial begin
        cfg_we=0;cfg_engine=0;cfg_voice=0;cfg_mode=0;cfg_data=0;clr_we=0;clr_engine=0;clr_voice=0;clr_mode=0;
        seed_we=0;seed_engine=0;seed_voice=0;seed_mode=0;seed_data=0;
        a_ns=0;a_gate=0;a_active=0;a_x=0;a_xvel={SLOTS{16'h8000}};a_nm=0;
        b_ctrl=0;b_class=0;b_vel=0;b_theta=0;b_a1_en=0;b_ratio=16'h8000;b_ns=0;b_gate=0;b_active=0;b_nm=0;
        c_ns=0;c_choke=0;c_len=0;c_svel=0;c_atk=0;c_rel=0;c_nm=0;c_sld=0;c_slv=0;c_sln=0;c_sb=0;
        e2_cfg_we=0;e2_cfg_voice=0;e2_cfg_mode=0;e2_cfg_data=0;e2_clr_we=0;e2_clr_voice=0;e2_clr_mode=0;
        e2_seed_we=0;e2_seed_voice=0;e2_seed_mode=0;e2_seed_data=0;e2_active=0;e2_zero=0;e2_x=0;e2_nm=0;start=0;
        out_seen=0;
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);

        // A only
        cfg_data='0; cfg_data=rec_set(cfg_data,E1_G,32'sh0100_0000);
        @(negedge clk); cfg_we=1; cfg_engine=0; cfg_voice=0; cfg_mode=0;
        @(posedge clk); @(negedge clk); cfg_we=0;
        a_nm[0*MWA +: MWA]=6'd1; a_active=2'b01; a_x[0*32 +: 32]=32'sh1000_0000;
        a_gate=2'b01; a_ns=2'b01;
        @(posedge clk); @(negedge clk); a_ns=0;
        run();
        if (mix <= 0) begin $display("FAIL A mix=%0d",mix); errors++; end
        if (errors==0) $display("PASS tb_shared_engines_post");
        else $display("FAIL tb_shared_engines_post errors=%0d",errors);
        $finish;
    end
endmodule
