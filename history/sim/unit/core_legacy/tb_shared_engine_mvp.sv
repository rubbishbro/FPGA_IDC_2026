`timescale 1ns/1ps
module tb_shared_engine_mvp;
    import modal_record_pkg::*;
    localparam int SLOTS = 2;
    localparam int MA = 48, ME = 80, LANES = 4;
    localparam int VW = 1, MWA = 6, MWE = 7;

    logic clk=0, rst_n=0;
    logic sel_e2;
    // A load
    logic a_cfg_we; logic [VW-1:0] a_cfg_voice; logic [MWA-1:0] a_cfg_mode; logic [REC_W-1:0] a_cfg_data;
    logic a_clr_we; logic [VW-1:0] a_clr_voice; logic [MWA-1:0] a_clr_mode;
    logic a_seed_we; logic [VW-1:0] a_seed_voice; logic [MWA-1:0] a_seed_mode; logic [63:0] a_seed_data;
    logic a_start; logic [SLOTS-1:0] a_active; logic [SLOTS*32-1:0] a_x;
    logic [SLOTS*16-1:0] a_xvel, a_env; logic [SLOTS*MWA-1:0] a_nm;
    // E2 load
    logic e2_cfg_we; logic [VW-1:0] e2_cfg_voice; logic [MWE-1:0] e2_cfg_mode; logic [REC_W-1:0] e2_cfg_data;
    logic e2_clr_we; logic [VW-1:0] e2_clr_voice; logic [MWE-1:0] e2_clr_mode;
    logic e2_seed_we; logic [VW-1:0] e2_seed_voice; logic [MWE-1:0] e2_seed_mode; logic [63:0] e2_seed_data;
    logic e2_start; logic [SLOTS-1:0] e2_active, e2_zero; logic [SLOTS*32-1:0] e2_x;
    logic [SLOTS*MWE-1:0] e2_nm;

    logic ready, busy, done, out_valid; logic signed [63:0] mix;
    int errors=0;
    logic signed [63:0] mix_a;
    logic out_seen;

    shared_engine_mvp #(
        .NUM_SLOTS(SLOTS), .N_MODES_ABC(MA), .N_MODES_E2(ME), .LANES(LANES), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n), .sel_e2(sel_e2),
        .a_cfg_we(a_cfg_we), .a_cfg_voice(a_cfg_voice), .a_cfg_mode(a_cfg_mode), .a_cfg_data(a_cfg_data),
        .a_clr_we(a_clr_we), .a_clr_voice(a_clr_voice), .a_clr_mode(a_clr_mode),
        .a_seed_we(a_seed_we), .a_seed_voice(a_seed_voice), .a_seed_mode(a_seed_mode), .a_seed_data(a_seed_data),
        .a_start(a_start), .a_active(a_active), .a_x(a_x), .a_x_vel(a_xvel), .a_nmodes(a_nm), .a_env_gain(a_env),
        .e2_cfg_we(e2_cfg_we), .e2_cfg_voice(e2_cfg_voice), .e2_cfg_mode(e2_cfg_mode), .e2_cfg_data(e2_cfg_data),
        .e2_clr_we(e2_clr_we), .e2_clr_voice(e2_clr_voice), .e2_clr_mode(e2_clr_mode),
        .e2_seed_we(e2_seed_we), .e2_seed_voice(e2_seed_voice), .e2_seed_mode(e2_seed_mode), .e2_seed_data(e2_seed_data),
        .e2_start(e2_start), .e2_active(e2_active), .e2_zero(e2_zero), .e2_x(e2_x), .e2_nmodes(e2_nm),
        .sample_ready(ready), .busy(busy), .done(done), .out_valid(out_valid), .mix_sum(mix)
    );

    always #5 clk=~clk;
    always @(posedge clk) if (out_valid) out_seen <= 1'b1;

    task automatic a_cfg(input int v, input int m, input logic signed [31:0] g);
        logic [REC_W-1:0] r;
        begin
            @(negedge clk); a_cfg_we=1; a_cfg_voice=v[VW-1:0]; a_cfg_mode=m[MWA-1:0];
            r='0; r=rec_set(r,E1_G,g); a_cfg_data=r;
            @(posedge clk); @(negedge clk); a_cfg_we=0;
        end
    endtask

    task automatic run_a();
        begin
            wait(ready); @(negedge clk); a_start=1;
            @(posedge clk); @(negedge clk); a_start=0;
            wait(done); @(posedge clk); #1;
        end
    endtask

    task automatic run_e2();
        begin
            wait(ready); @(negedge clk); e2_start=1;
            @(posedge clk); @(negedge clk); e2_start=0;
            wait(done); @(posedge clk); #1;
        end
    endtask

    initial begin
        sel_e2=0; a_cfg_we=0; a_cfg_voice=0; a_cfg_mode=0; a_cfg_data=0;
        a_clr_we=0; a_clr_voice=0; a_clr_mode=0; a_seed_we=0; a_seed_voice=0; a_seed_mode=0; a_seed_data=0;
        a_start=0; a_active=0; a_x=0; a_xvel={SLOTS{16'h8000}}; a_env={SLOTS{16'h8000}}; a_nm=0;
        e2_cfg_we=0; e2_cfg_voice=0; e2_cfg_mode=0; e2_cfg_data=0;
        e2_clr_we=0; e2_clr_voice=0; e2_clr_mode=0; e2_seed_we=0; e2_seed_voice=0; e2_seed_mode=0; e2_seed_data=0;
        e2_start=0; e2_active=0; e2_zero=0; e2_x=0; e2_nm=0;
        out_seen=0;
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);

        // A: 2 voices, 5 modes, G=1.0
        for (int m=0;m<5;m++) begin a_cfg(0,m,32'sh0100_0000); a_cfg(1,m,32'sh0100_0000); end
        a_nm[0*MWA +: MWA]=6'd5; a_nm[1*MWA +: MWA]=6'd5;
        a_active=2'b11; a_x[0*32 +: 32]=32'sh1000_0000; a_x[1*32 +: 32]=32'sh0800_0000;
        run_a(); mix_a=mix;
        if (mix_a != 64'sd2013265920) begin $display("FAIL A mix=%0d",mix_a); errors++; end
        if (!out_seen) begin $display("FAIL A out_valid"); errors++; end

        // E2: one voice/mode, same shared RAM; A idle
        sel_e2=1; a_start=0;
        e2_cfg_data='0;
        e2_cfg_data=rec_set(e2_cfg_data,E2_GQ,32'h7FFF_FFFF);
        e2_cfg_data=rec_set(e2_cfg_data,E2_WO,32'h0000_8000);
        @(negedge clk); e2_cfg_we=1; e2_cfg_voice=0; e2_cfg_mode=0;
        @(posedge clk); @(negedge clk); e2_cfg_we=0;
        e2_nm[0*MWE +: MWE]=7'd1; e2_active=2'b01; e2_x[0*32 +: 32]=32'sh1000_0000;
        e2_zero=2'b01; run_e2();
        if (mix != 0) begin $display("FAIL E2 first mix=%0d",mix); errors++; end
        e2_zero=0; run_e2();
        if (mix == 0) begin $display("FAIL E2 second mix=0"); errors++; end
        if (!out_seen) begin $display("FAIL E2 out_valid"); errors++; end

        if (errors==0) $display("PASS tb_shared_engine_mvp");
        else $display("FAIL tb_shared_engine_mvp errors=%0d",errors);
        $finish;
    end
endmodule
