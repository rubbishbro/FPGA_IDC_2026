// -----------------------------------------------------------------------------
// tb_eng2_engine_top.sv -- ENG2 9×32 RAM 适配冒烟
// 1 voice / 1 mode；gq 驱动 q，第二帧 wo*q 输出非零。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_eng2_engine_top;
    import modal_record_pkg::*;

    localparam int SLOTS = 2;
    localparam int MODES = 4;
    localparam int VW = 1;
    localparam int MW = 3;

    logic clk=0, rst_n=0;

    logic cfg_we; logic [VW-1:0] cfg_voice; logic [MW-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic clr_we; logic [VW-1:0] clr_voice; logic [MW-1:0] clr_mode;
    logic seed_we; logic [VW-1:0] seed_voice; logic [MW-1:0] seed_mode; logic [63:0] seed_data;

    logic start;
    logic [SLOTS-1:0] active_mask, zero_mask;
    logic [SLOTS*32-1:0] x_vec;
    logic [SLOTS*MW-1:0] n_modes_vec;
    logic sample_ready, done, busy;
    logic out_valid;
    logic signed [63:0] mix_sum;
    logic voice_valid;
    logic [VW-1:0] voice_id;
    logic signed [63:0] voice_sum;

    int errors=0;
    logic signed [63:0] mix1, mix2;

    eng2_engine_top #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .start(start), .active_mask(active_mask), .zero_mask(zero_mask),
        .x_vec(x_vec), .n_modes_vec(n_modes_vec),
        .sample_ready(sample_ready), .done(done), .busy(busy),
        .out_valid(out_valid), .mix_sum(mix_sum),
        .voice_valid(voice_valid), .voice_id(voice_id), .voice_sum(voice_sum)
    );

    always #5 clk = ~clk;

    task automatic run_sample();
        begin
            wait (sample_ready);
            @(negedge clk); start=1;
            @(posedge clk); @(negedge clk); start=0;
            wait (done); #1;
        end
    endtask

    initial begin
        cfg_we=0; cfg_voice='0; cfg_mode='0; cfg_data='0;
        clr_we=0; clr_voice='0; clr_mode='0;
        seed_we=0; seed_voice='0; seed_mode='0; seed_data='0;
        start=0; active_mask='0; zero_mask='0; x_vec='0; n_modes_vec='0;

        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        // a11..a22=0, gq=max, gv=0, wo=0x8000
        cfg_data='0;
        cfg_data=rec_set(cfg_data,E2_GQ,32'h7FFF_FFFF);
        cfg_data=rec_set(cfg_data,E2_WO,32'h0000_8000);
        @(negedge clk); cfg_we=1; cfg_voice=0; cfg_mode=0;
        @(posedge clk); @(negedge clk); cfg_we=0;

        active_mask=2'b01;
        n_modes_vec[0*MW +: MW] = 3'd1;
        x_vec[0*32 +: 32] = 32'sh1000_0000;

        zero_mask=2'b01;   // first sample: zero state
        run_sample();
        mix1 = mix_sum;

        zero_mask='0;
        run_sample();
        mix2 = mix_sum;

        if (mix1 !== 0) begin
            $display("FAIL first mix=%0d exp=0", mix1); errors++;
        end
        if (mix2 == 0) begin
            $display("FAIL second mix=0"); errors++;
        end
        if (!out_valid) begin $display("FAIL out_valid"); errors++; end

        if (errors==0) $display("PASS tb_eng2_engine_top");
        else           $display("FAIL tb_eng2_engine_top errors=%0d", errors);
        $finish;
    end
endmodule
