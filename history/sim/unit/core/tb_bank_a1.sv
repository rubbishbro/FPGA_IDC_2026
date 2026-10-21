`timescale 1ns/1ps
module tb_bank_a1;
    localparam int NV = 2, NM = 4;
    logic clk=0, rst_n=0;
    always #5 clk = ~clk;

    logic cfg_valid=0, cfg_ready;
    logic [0:0] cfg_voice=0;
    logic [2:0] cfg_mode=0;
    logic [71:0] cfg_word=0;
    logic seed_valid=0, seed_ready;
    logic [0:0] seed_voice=0; logic [2:0] seed_mode=0; logic [63:0] seed_word=0;
    logic a1_we=0, a1_ready; logic [0:0] a1_voice=0; logic [2:0] a1_mode=0;
    logic [21:0] a1_data=0; logic a1_done; logic [NV-1:0] b_mask=2'b01;
    logic coeff_rd_en=0, coeff_rd_valid;
    logic [0:0] coeff_rd_voice=0; logic [2:0] coeff_rd_mode=0;
    logic [71:0] coeff_rd_data;
    logic clear_valid=0, clear_ready, clear_done;
    logic [0:0] clear_voice=0;
    logic sample_valid=0, sample_ready, busy, out_valid;
    logic [NV-1:0] active_mask=0; logic [NV*6-1:0] n_modes_vec=0;
    logic [NV*32-1:0] x_vec=0;
    logic signed [63:0] mix_sum; logic [5:0] sat_count;
    logic voice_valid; logic [0:0] voice_id; logic signed [63:0] voice_sum;
    logic error_valid; logic [1:0] error_code;
    logic [3:0] commit_valid; logic [4*1-1:0] commit_voice;
    logic [4*3-1:0] commit_mode; logic [127:0] commit_y1, commit_y2;
    logic [3:0] commit_sat;

    modal_poly_bank #(.NUM_VOICES(NV), .N_MODES(NM)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_voice(cfg_voice),
        .cfg_mode(cfg_mode), .cfg_word(cfg_word),
        .seed_valid(seed_valid), .seed_ready(seed_ready), .seed_voice(seed_voice),
        .seed_mode(seed_mode), .seed_word(seed_word),
        .a1_we(a1_we), .a1_ready(a1_ready), .a1_voice(a1_voice),
        .a1_mode(a1_mode), .a1_data(a1_data), .a1_done(a1_done), .b_mask(b_mask),
        .coeff_rd_en(coeff_rd_en), .coeff_rd_valid(coeff_rd_valid),
        .coeff_rd_voice(coeff_rd_voice), .coeff_rd_mode(coeff_rd_mode),
        .coeff_rd_data(coeff_rd_data),
        .clear_valid(clear_valid), .clear_ready(clear_ready),
        .clear_voice(clear_voice), .clear_done(clear_done),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .active_mask(active_mask), .n_modes_vec(n_modes_vec), .x_vec(x_vec),
        .busy(busy), .out_valid(out_valid), .mix_sum(mix_sum),
        .sat_count(sat_count), .voice_valid(voice_valid), .voice_id(voice_id),
        .voice_sum(voice_sum), .error_valid(error_valid), .error_code(error_code),
        .commit_valid(commit_valid), .commit_voice(commit_voice),
        .commit_mode(commit_mode), .commit_y1(commit_y1), .commit_y2(commit_y2),
        .commit_sat(commit_sat)
    );

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        if (!a1_ready) $fatal(1, "a1_ready not high");
        // cfg mode0
        cfg_word = {26'sd0, 24'h800000, 22'h30bdc0};
        cfg_valid = 1;
        @(posedge clk);
        while (!cfg_ready) @(posedge clk);
        cfg_valid = 0;
        repeat (2) @(posedge clk);
        // a1 shadow write
        a1_data = 22'h12345; a1_we = 1; a1_voice = 0; a1_mode = 0;
        @(posedge clk);
        a1_we = 0;
        repeat (2) @(posedge clk);
        if (dut.g_lane[0].u_lane.a1_mem[0] !== 22'h12345)
            $fatal(1, "a1 shadow write failed: %h", dut.g_lane[0].u_lane.a1_mem[0]);
        // coeff readback
        coeff_rd_en = 1; coeff_rd_voice = 0; coeff_rd_mode = 0;
        @(posedge clk);
        #1;
        if (!coeff_rd_valid) $fatal(1, "coeff_rd_valid missing");
        if (coeff_rd_data[21:0] !== cfg_word[21:0])
            $fatal(1, "coeff readback mismatch: %h vs %h",
                   coeff_rd_data, cfg_word);
        $display("tb_bank_a1 PASS: a1 shadow + coeff read");
        $finish;
    end
endmodule
