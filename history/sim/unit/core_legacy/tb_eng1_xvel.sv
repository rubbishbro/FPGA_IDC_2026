// -----------------------------------------------------------------------------
// tb_eng1_xvel.sv -- A 的 x_vel_vec 缩放
// G=1, x=0.25, vel=0.5 -> mix=0.125
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_eng1_xvel;
    import modal_record_pkg::*;

    localparam int SLOTS=2, MODES=4, LANES=4, VW=1, MW=2, SW=4;
    logic clk=0, rst_n=0;
    logic cfg_we; logic [VW-1:0] cfg_voice; logic [MW-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic [LANES-1:0] rd_re; logic [LANES*1-1:0] rd_addr; logic [LANES*REC_W-1:0] rd_data;
    logic [LANES-1:0] st_we; logic [LANES*1-1:0] st_addr; logic [LANES*64-1:0] st_data;
    logic clr_we; logic [VW-1:0] clr_voice; logic [MW-1:0] clr_mode;
    logic seed_we; logic [VW-1:0] seed_voice; logic [MW-1:0] seed_mode; logic [63:0] seed_data;
    logic [SLOTS-1:0] active;
    logic [SLOTS*32-1:0] x;
    logic [SLOTS*16-1:0] xvel;
    logic [SLOTS*MW-1:0] nm;
    logic start, ready, done, busy, out_valid;
    logic signed [63:0] mix;

    int errors=0;

    eng1_engine_top #(.NUM_SLOTS(SLOTS), .N_MODES(MODES), .LANES(LANES), .REC_W(REC_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0), .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0), .co_field('0), .co_wdata('0),
        .start(start), .active_mask(active), .x_vec(x), .x_vel_vec(xvel),
        .n_modes_vec(nm), .env_gain_vec({SLOTS{16'h8000}}),
        .sample_ready(ready), .done(done), .busy(busy),
        .out_valid(out_valid), .mix_sum(mix), .sat_count(),
        .voice_valid(), .voice_id(), .voice_sum()
    );

    always #5 clk = ~clk;

    initial begin
        cfg_we=0; cfg_voice='0; cfg_mode='0; cfg_data='0;
        clr_we=0; clr_voice='0; clr_mode='0; seed_we=0; seed_voice='0; seed_mode='0; seed_data='0;
        active='0; x='0; xvel={SLOTS{16'h8000}}; nm='0; start=0;

        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        cfg_data=rec_set(0,E1_G,32'h0100_0000);
        @(negedge clk); cfg_we=1; cfg_voice=0; cfg_mode=0;
        @(posedge clk); @(negedge clk); cfg_we=0;

        active=2'b01;
        x[0*32 +: 32]=32'sh1000_0000;
        xvel[0*16 +: 16]=16'h4000; // 0.5
        nm[0*MW +: MW]=2'd1;

        wait (ready);
        start=1; @(posedge clk); @(negedge clk); start=0;
        wait (done); #1;

        if (mix !== 64'sd134217728) begin
            $display("FAIL mix=%0d exp=134217728", mix); errors++;
        end
        if (errors==0) $display("PASS tb_eng1_xvel");
        else           $display("FAIL tb_eng1_xvel errors=%0d", errors);
        $finish;
    end
endmodule
