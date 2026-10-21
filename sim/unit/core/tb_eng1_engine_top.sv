// -----------------------------------------------------------------------------
// tb_eng1_engine_top.sv -- ENG1 单引擎顶层冒烟（16 slot 参数化到 4）
//
// 2 个 active voice，各自 n_modes=5（lane0 处理 mode0/4）：
//   voice0 x=0.25 -> voice_sum=0.5
//   voice1 x=0.125 -> voice_sum=0.25
//   mix_sum=0.75
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_eng1_engine_top;

    import modal_record_pkg::*;

    localparam int SLOTS = 4;
    localparam int MODES = 8;
    localparam int LANES = 4;
    localparam int LOCAL = (MODES + LANES - 1) / LANES;
    localparam int VW    = $clog2(SLOTS);
    localparam int MW    = $clog2(MODES);
    localparam int AW    = $clog2(SLOTS * LOCAL);
    localparam int SW    = $clog2(SLOTS * MODES + 1);

    logic clk = 0;
    logic rst_n = 0;

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

    logic start;
    logic [SLOTS-1:0] active_mask;
    logic [SLOTS*32-1:0] x_vec;
    logic [SLOTS*MW-1:0] n_modes_vec;
    logic [SLOTS*16-1:0] x_vel_vec;
    logic [SLOTS*16-1:0] env_gain_vec;
    logic sample_ready, done, busy;
    logic out_valid;
    logic signed [63:0] mix_sum;
    logic [SW-1:0] sat_count;
    logic voice_valid;
    logic [VW-1:0] voice_id;
    logic signed [63:0] voice_sum;

    int errors = 0;
    int vcount = 0;
    logic [VW-1:0] vids [0:7];
    logic signed [63:0] vsums [0:7];

    eng1_engine_top #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .LANES(LANES), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice),
        .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice),
        .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0),
        .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0),
        .co_field('0), .co_wdata('0),
        .start(start), .active_mask(active_mask),
        .x_vec(x_vec), .x_vel_vec(x_vel_vec), .n_modes_vec(n_modes_vec),
        .env_gain_vec(env_gain_vec),
        .sample_ready(sample_ready), .done(done), .busy(busy),
        .out_valid(out_valid), .mix_sum(mix_sum), .sat_count(sat_count),
        .voice_valid(voice_valid), .voice_id(voice_id), .voice_sum(voice_sum)
    );

    always #5 clk = ~clk;
    always_ff @(posedge clk) begin
        if (voice_valid) begin
            vids[vcount]  <= voice_id;
            vsums[vcount] <= voice_sum;
            vcount <= vcount + 1;
        end
    end

    task automatic check64(input string name, input logic signed [63:0] got,
                           input logic signed [63:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %-14s got=%0d exp=%0d", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    task automatic cfg_write(input int v, input int m, input logic signed [31:0] g);
        logic [REC_W-1:0] rec;
        begin
            @(negedge clk);
            cfg_we = 1; cfg_voice = v[VW-1:0]; cfg_mode = m[MW-1:0];
            rec = '0;
            rec = rec_set(rec, E1_G, g);
            cfg_data = rec;
            @(posedge clk);
            @(negedge clk);
            cfg_we = 0;
        end
    endtask

    initial begin
        cfg_we = 0; cfg_voice = '0; cfg_mode = '0; cfg_data = '0;
        clr_we = 0; clr_voice = '0; clr_mode = '0;
        seed_we = 0; seed_voice = '0; seed_mode = '0; seed_data = '0;
        start = 0; active_mask = '0; x_vec = '0; n_modes_vec = '0;
        x_vel_vec = {SLOTS{16'h8000}};
        env_gain_vec = {SLOTS{16'h8000}};

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // voice0/1 的 mode0..4，G=1.0（lane1/2/3 也要有合法系数）
        for (int m = 0; m < 5; m = m + 1) begin
            cfg_write(0, m, 32'sh0100_0000);
            cfg_write(1, m, 32'sh0100_0000);
        end

        // n_modes=5 for voice0/1
        n_modes_vec[0*MW +: MW] = 3'd5;
        n_modes_vec[1*MW +: MW] = 3'd5;
        active_mask = 2'b11;
        x_vec[0*32 +: 32] = 32'sh1000_0000;  // 0.25
        x_vec[1*32 +: 32] = 32'sh0800_0000;  // 0.125

        @(negedge clk);
        start = 1;
        @(posedge clk);
        @(negedge clk);
        start = 0;

        wait (done);
        #1;
        check64("mix_sum", mix_sum, 64'sd2013265920); // 1.875 * 2^30
        check64("sat_count", {54'd0, sat_count}, 64'sd0);
        if (!out_valid) begin
            $display("FAIL out_valid not high"); errors = errors + 1;
        end
        if (vcount != 2) begin
            $display("FAIL voice count=%0d", vcount); errors = errors + 1;
        end else begin
            if (vids[0] !== 2'd0 || vsums[0] !== 64'sd1342177280) begin
                $display("FAIL voice0 id=%0d sum=%0d", vids[0], vsums[0]);
                errors = errors + 1;
            end
            if (vids[1] !== 2'd1 || vsums[1] !== 64'sd671088640) begin
                $display("FAIL voice1 id=%0d sum=%0d", vids[1], vsums[1]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS tb_eng1_engine_top");
        else
            $display("FAIL tb_eng1_engine_top errors=%0d", errors);

        $finish;
    end

endmodule
