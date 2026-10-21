// -----------------------------------------------------------------------------
// tb_eng1_engine_env_top.sv -- engine + envelope bank 的 A 路径冒烟
// 1 voice / 1 mode / G=1 / x=0.25 / class=A -> mix=0.25
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_eng1_engine_env_top;

    import modal_record_pkg::*;

    localparam int SLOTS = 2;
    localparam int MODES = 4;
    localparam int LANES = 4;
    localparam int LOCAL = 1;
    localparam int VW    = 1;
    localparam int MW    = 2;
    localparam int AW    = 1;
    localparam int SW    = 4;

    logic clk = 0, rst_n = 0;
    logic cfg_we;
    logic [VW-1:0] cfg_voice;
    logic [MW-1:0] cfg_mode;
    logic [REC_W-1:0] cfg_data;
    logic clr_we;
    logic [VW-1:0] clr_voice;
    logic [MW-1:0] clr_mode;
    logic seed_we;
    logic [VW-1:0] seed_voice;
    logic [MW-1:0] seed_mode;
    logic [63:0] seed_data;

    logic [SLOTS-1:0] note_start_mask, gate_mask, choke_mask, done_mask;
    logic [SLOTS*2-1:0] class_vec;
    logic [SLOTS*24-1:0] attack_vec, release_vec;

    logic start;
    logic [SLOTS-1:0] active_mask;
    logic [SLOTS*32-1:0] x_vec;
    logic [SLOTS*MW-1:0] n_modes_vec;
    logic [SLOTS*16-1:0] x_vel_vec;
    logic sample_ready, done, busy;
    logic out_valid;
    logic signed [63:0] mix_sum;
    logic [SW-1:0] sat_count;
    logic voice_valid;
    logic [VW-1:0] voice_id;
    logic signed [63:0] voice_sum;

    int errors = 0;

    eng1_engine_env_top #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .LANES(LANES), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0),
        .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0),
        .co_field('0), .co_wdata('0),
        .note_start_mask(note_start_mask), .gate_mask(gate_mask),
        .choke_mask(choke_mask), .done_mask(done_mask),
        .class_vec(class_vec), .attack_vec(attack_vec), .release_vec(release_vec),
        .start(start), .active_mask(active_mask), .x_vec(x_vec),
        .x_vel_vec(x_vel_vec),
        .n_modes_vec(n_modes_vec), .sample_ready(sample_ready),
        .done(done), .busy(busy), .out_valid(out_valid), .mix_sum(mix_sum),
        .sat_count(sat_count), .voice_valid(voice_valid), .voice_id(voice_id),
        .voice_sum(voice_sum)
    );

    always #5 clk = ~clk;

    initial begin
        cfg_we = 0; cfg_voice = '0; cfg_mode = '0; cfg_data = '0;
        clr_we = 0; clr_voice = '0; clr_mode = '0;
        seed_we = 0; seed_voice = '0; seed_mode = '0; seed_data = '0;
        note_start_mask = '0; gate_mask = '0; choke_mask = '0; done_mask = '0;
        class_vec = '0; attack_vec = '0; release_vec = '0;
        start = 0; active_mask = '0; x_vec = '0; n_modes_vec = '0;
        x_vel_vec = {SLOTS{16'h8000}};

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // mode0: G=1
        @(negedge clk);
        cfg_we = 1; cfg_voice = 0; cfg_mode = 0; cfg_data = '0;
        cfg_data = rec_set(cfg_data, E1_G, 32'h0100_0000);
        @(posedge clk);
        @(negedge clk);
        cfg_we = 0;

        n_modes_vec[0*MW +: MW] = 2'd1;
        active_mask = 2'b01;
        x_vec[0*32 +: 32] = 32'sh1000_0000; // 0.25
        class_vec[0*2 +: 2] = 2'd0;         // A

        // A note-on pulse，随后 sample start
        @(negedge clk); note_start_mask[0] = 1;
        @(posedge clk); @(negedge clk); note_start_mask[0] = 0;
        start = 1;
        @(posedge clk); @(negedge clk); start = 0;

        wait (done);
        #1;
        if (mix_sum !== 64'sd268435456) begin
            $display("FAIL mix_sum=%0d exp=268435456", mix_sum);
            errors = errors + 1;
        end
        if (!out_valid) begin
            $display("FAIL out_valid"); errors = errors + 1;
        end

        if (errors == 0) $display("PASS tb_eng1_engine_env_top");
        else             $display("FAIL tb_eng1_engine_env_top errors=%0d", errors);
        $finish;
    end

endmodule
