// -----------------------------------------------------------------------------
// tb_c_engine_top.sv -- C 引擎 seed/timer 冒烟
//
// mode0: G=0, a1=-0.5, a2=0.25, seed y1=0.25
// -> ynew=0.125, mix 非零；timer 到期后 envelope 进入 release。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_c_engine_top;

    import modal_record_pkg::*;

    localparam int SLOTS = 2;
    localparam int MODES = 4;
    localparam int LANES = 4;
    localparam int CW    = 8;
    localparam int SW    = 4;

    logic clk = 0, rst_n = 0;

    logic cfg_we;
    logic [0:0] cfg_voice;
    logic [1:0] cfg_mode;
    logic [REC_W-1:0] cfg_data;
    logic clr_we;
    logic [0:0] clr_voice;
    logic [1:0] clr_mode;
    logic seed_we;
    logic [0:0] seed_voice;
    logic [1:0] seed_mode;
    logic [63:0] seed_data;

    logic [SLOTS-1:0] note_start_mask, choke_mask;
    logic [SLOTS*CW-1:0] length_vec;
    logic [SLOTS*24-1:0] attack_vec, release_vec;
    logic [SLOTS*16-1:0] seed_vel_vec;
    logic [SLOTS*2-1:0] n_modes_vec;

    logic start;
    logic sample_ready, done, busy;
    logic [SLOTS-1:0] c_active, c_done;
    logic out_valid;
    logic signed [63:0] mix_sum;
    logic [SW-1:0] sat_count;
    logic voice_valid;
    logic [0:0] voice_id;
    logic signed [63:0] voice_sum;

    int errors = 0;

    c_engine_top #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .LANES(LANES), .REC_W(REC_W), .CW(CW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .note_start_mask(note_start_mask), .choke_mask(choke_mask),
        .length_vec(length_vec), .attack_vec(attack_vec), .release_vec(release_vec),
        .seed_vel_vec(seed_vel_vec), .n_modes_vec(n_modes_vec),
        .seed_load_start(1'b0), .seed_load_voice('0), .seed_load_nmodes('0),
        .seed_base('0), .seed_busy(), .seed_done(),
        .start(start), .sample_ready(sample_ready), .done(done), .busy(busy),
        .c_active(c_active), .c_done(c_done),
        .out_valid(out_valid), .mix_sum(mix_sum), .sat_count(sat_count),
        .voice_valid(voice_valid), .voice_id(voice_id), .voice_sum(voice_sum)
    );

    always #5 clk = ~clk;

    initial begin
        cfg_we = 0; cfg_voice = '0; cfg_mode = '0; cfg_data = '0;
        clr_we = 0; clr_voice = '0; clr_mode = '0;
        seed_we = 0; seed_voice = '0; seed_mode = '0; seed_data = '0;
        note_start_mask = '0; choke_mask = '0;
        length_vec = '0; attack_vec = '0; release_vec = '0;
        seed_vel_vec = {SLOTS{16'h8000}};
        n_modes_vec = '0; start = 0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // coeff mode0: G=0, a1=-0.5, a2=0.25
        @(negedge clk);
        cfg_we = 1; cfg_voice = 0; cfg_mode = 0; cfg_data = '0;
        cfg_data = rec_set(cfg_data, E1_A1, 32'hFFF8_0000);
        cfg_data = rec_set(cfg_data, E1_A2, 32'h0040_0000);
        @(posedge clk);
        @(negedge clk); cfg_we = 0;

        // seed y1=0.25
        @(negedge clk);
        seed_we = 1; seed_voice = 0; seed_mode = 0;
        seed_data = {32'd0, 32'h1000_0000};
        @(posedge clk);
        @(negedge clk); seed_we = 0;

        n_modes_vec[0*2 +: 2] = 2'd1;
        length_vec[0*CW +: CW] = 8'd20;
        release_vec[0*24 +: 24] = 24'h01_0000;

        // timer start
        @(negedge clk); note_start_mask[0] = 1;
        @(posedge clk); @(negedge clk); note_start_mask[0] = 0;
        wait (c_active[0]);

        // one engine sample
        start = 1;
        @(posedge clk); @(negedge clk); start = 0;
        wait (done);
        #1;
        if (mix_sum <= 0) begin
            $display("FAIL C mix_sum=%0d", mix_sum); errors = errors + 1;
        end
        if (!out_valid) begin
            $display("FAIL C out_valid"); errors = errors + 1;
        end

        // timer expires -> c_done; envelope should release (gain no longer 1.0)
        wait (c_done[0]);
        repeat (10) @(posedge clk);

        if (errors == 0) $display("PASS tb_c_engine_top");
        else             $display("FAIL tb_c_engine_top errors=%0d", errors);
        $finish;
    end

endmodule
