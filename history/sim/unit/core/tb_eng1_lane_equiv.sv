// -----------------------------------------------------------------------------
// tb_eng1_lane_equiv.sv -- 新纯计算 lane 与旧 poly_modal_lane 的随机对拍
//
// 同一个 voice、同一组系数/初值/x，分别跑：
//   * 旧 poly_modal_lane（内部 RAM）
//   * 新 eng1_lane_core + modal_ram（内存中心）
// 比较 partial_sum / sat_count / commit(y1,y2) 逐位相等。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_eng1_lane_equiv;

    import modal_record_pkg::*;

    localparam int SLOTS = 2;
    localparam int MODES = 8;
    localparam int LANES = 4;
    localparam int LOCAL = (MODES + LANES - 1) / LANES;   // 2
    localparam int AW    = $clog2(SLOTS * LOCAL);          // 2
    localparam int VW    = $clog2(SLOTS);                  // 1
    localparam int MW    = $clog2(MODES);                  // 3
    localparam int SVW   = $clog2(SLOTS * LOCAL);          // 2

    logic clk = 0;
    logic rst_n = 0;

    // 旧 lane
    logic old_start;
    logic [MW-1:0] old_n_modes;
    logic signed [31:0] old_x;
    logic [VW-1:0] old_voice;
    logic old_clear;
    logic [VW-1:0] old_clear_voice;
    logic old_cfg_we;
    logic [VW-1:0] old_cfg_voice;
    logic [0:0] old_cfg_local;      // LOCAL=2 -> 1 bit
    logic [71:0] old_cfg_wdata;
    logic old_seed_we;
    logic [VW-1:0] old_seed_voice;
    logic [0:0] old_seed_local;
    logic [63:0] old_seed_wdata;
    logic old_a1_we;
    logic [SVW-1:0] old_a1_addr;
    logic [21:0] old_a1_wdata;
    logic [SLOTS-1:0] old_b_mask;
    logic old_coeff_rd_en;
    logic [SVW-1:0] old_coeff_rd_addr;
    logic [71:0] old_coeff_rd_data;
    logic old_done;
    logic [VW-1:0] old_commit_voice;
    logic [MW-1:0] old_commit_mode;
    logic signed [31:0] old_commit_y1, old_commit_y2;
    logic old_commit_sat;
    logic old_commit_valid;
    logic signed [63:0] old_ps;
    logic [5:0] old_sat;

    // 新 RAM + core
    logic cfg_we;
    logic [VW-1:0] cfg_voice;
    logic [MW-1:0] cfg_mode;
    logic [REC_W-1:0] cfg_data;
    logic [LANES-1:0] st_we;
    logic [LANES*AW-1:0] st_addr;
    logic [LANES*64-1:0] st_data;
    logic [LANES-1:0] rd_re;
    logic [LANES*AW-1:0] rd_addr;
    logic [LANES*REC_W-1:0] rd_data;
    logic clr_we;
    logic [VW-1:0] clr_voice;
    logic [MW-1:0] clr_mode;
    logic seed_we;
    logic [VW-1:0] seed_voice;
    logic [MW-1:0] seed_mode;
    logic [63:0] seed_data;

    logic new_start;
    logic [MW-1:0] new_n_modes;
    logic signed [31:0] new_x;
    logic [VW-1:0] new_voice;
    logic core_rd_re;
    logic [AW-1:0] core_rd_addr;
    logic core_st_we;
    logic [AW-1:0] core_st_addr;
    logic [63:0] core_st_data;
    logic new_done, new_busy;
    logic new_commit_valid;
    logic [VW-1:0] new_commit_voice;
    logic [MW-1:0] new_commit_mode;
    logic signed [31:0] new_commit_y1, new_commit_y2;
    logic new_commit_sat;
    logic signed [63:0] new_ps;
    logic [5:0] new_sat;

    int errors = 0;
    int old_cc, new_cc;
    logic [MW-1:0] old_modes [0:7];
    logic [MW-1:0] new_modes [0:7];
    logic signed [31:0] old_y1s [0:7], old_y2s [0:7];
    logic signed [31:0] new_y1s [0:7], new_y2s [0:7];
    int seed = 32'h1357_2468;

    poly_modal_lane #(
        .NUM_VOICES(SLOTS), .N_MODES(MODES), .LANE(0), .MW(MW),
        .SKIP_ZERO_INPUT(0)
    ) u_old (
        .clk(clk), .rst_n(rst_n),
        .start(old_start), .n_modes(old_n_modes), .x_in(old_x), .voice(old_voice),
        .clear(old_clear), .clear_voice(old_clear_voice),
        .cfg_we(old_cfg_we), .cfg_voice(old_cfg_voice),
        .cfg_local(old_cfg_local), .cfg_wdata(old_cfg_wdata),
        .seed_we(old_seed_we), .seed_voice(old_seed_voice),
        .seed_local(old_seed_local), .seed_wdata(old_seed_wdata),
        .a1_we(old_a1_we), .a1_addr(old_a1_addr), .a1_wdata(old_a1_wdata),
        .b_mask(old_b_mask),
        .coeff_rd_en(old_coeff_rd_en), .coeff_rd_addr(old_coeff_rd_addr),
        .coeff_rd_data(old_coeff_rd_data),
        .done(old_done), .commit_voice(old_commit_voice),
        .commit_mode(old_commit_mode), .commit_y1(old_commit_y1),
        .commit_y2(old_commit_y2), .commit_sat(old_commit_sat),
        .commit_valid(old_commit_valid), .partial_sum(old_ps),
        .sat_count(old_sat)
    );

    modal_ram #(
        .SLOTS(SLOTS), .MODES(MODES), .LANES(LANES),
        .STATE_FIRST(E1_Y1), .REC_W(REC_W), .FLD_W(FLD_W)
    ) u_ram (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice),
        .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .st_we(st_we), .st_addr(st_addr), .st_data(st_data),
        .rd_re(rd_re), .rd_addr(rd_addr), .rd_data(rd_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice),
        .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0),
        .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0),
        .co_field('0), .co_wdata('0)
    );

    eng1_lane_core #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .LANES(LANES), .LANE(0),
        .LOCAL(LOCAL), .VW(VW), .MW(MW), .AW(AW), .REC_W(REC_W)
    ) u_new (
        .clk(clk), .rst_n(rst_n),
        .start(new_start), .n_modes(new_n_modes), .x_in(new_x), .voice(new_voice),
        .rd_re(core_rd_re), .rd_addr(core_rd_addr),
        .rd_data(rd_data[0*REC_W +: REC_W]),
        .st_we(core_st_we), .st_addr(core_st_addr), .st_data(core_st_data),
        .done(new_done), .busy(new_busy),
        .commit_valid(new_commit_valid), .commit_voice(new_commit_voice),
        .commit_mode(new_commit_mode), .commit_y1(new_commit_y1),
        .commit_y2(new_commit_y2), .commit_sat(new_commit_sat),
        .partial_sum(new_ps), .sat_count(new_sat)
    );

    assign rd_re = {{(LANES-1){1'b0}}, core_rd_re};
    assign rd_addr = {{(LANES-1){1'b0}}, core_rd_addr};
    assign st_we = {{(LANES-1){1'b0}}, core_st_we};
    assign st_addr = {{(LANES-1){1'b0}}, core_st_addr};
    assign st_data = {{(LANES-1){1'b0}}, core_st_data};

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (old_commit_valid) begin
            old_modes[old_cc] <= old_commit_mode;
            old_y1s[old_cc]   <= old_commit_y1;
            old_y2s[old_cc]   <= old_commit_y2;
            old_cc <= old_cc + 1;
        end
        if (new_commit_valid) begin
            new_modes[new_cc] <= new_commit_mode;
            new_y1s[new_cc]   <= new_commit_y1;
            new_y2s[new_cc]   <= new_commit_y2;
            new_cc <= new_cc + 1;
        end
    end

    function automatic logic [71:0] pack72(
        input logic signed [25:0] g,
        input logic [23:0] a2,
        input logic signed [21:0] a1
    );
        pack72 = {g, a2, a1};
    endfunction

    task automatic write_pair(
        input int m,
        input logic signed [25:0] g26,
        input logic [23:0] a2_24,
        input logic signed [21:0] a1_22,
        input logic signed [31:0] y1,
        input logic signed [31:0] y2
    );
        logic [REC_W-1:0] rec;
        logic [1:0] loc;
        begin
            loc = m / LANES;
            // old: coefficient + seed state
            // old lane: cfg 与 seed 不能同拍（cfg 优先），分两拍
            @(negedge clk);
            old_cfg_we = 1; old_cfg_voice = '0; old_cfg_local = loc;
            old_cfg_wdata = pack72(g26, a2_24, a1_22);
            cfg_we = 1; cfg_voice = '0; cfg_mode = m[MW-1:0];
            rec = '0;
            rec = rec_set(rec, E1_G,  {{6{g26[25]}}, g26});
            rec = rec_set(rec, E1_A1, {{10{a1_22[21]}}, a1_22});
            rec = rec_set(rec, E1_A2, {8'b0, a2_24});
            rec = rec_set(rec, E1_Y1, y1);
            rec = rec_set(rec, E1_Y2, y2);
            cfg_data = rec;
            @(posedge clk);
            @(negedge clk);
            old_cfg_we = 0; cfg_we = 0;

            old_seed_we = 1; old_seed_voice = '0; old_seed_local = loc;
            old_seed_wdata = {y2, y1};
            @(posedge clk);
            @(negedge clk);
            old_seed_we = 0;
        end
    endtask

    task automatic run_frame(input int n, input logic signed [31:0] xv);
        begin
            wait (!new_busy);
            old_cc = 0; new_cc = 0;
            @(negedge clk);
            old_start = 1; old_n_modes = n[MW-1:0]; old_x = xv; old_voice = '0;
            new_start = 1; new_n_modes = n[MW-1:0]; new_x = xv; new_voice = '0;
            @(posedge clk);
            @(negedge clk);
            old_start = 0; new_start = 0;
            wait (old_done && new_done);
            @(posedge clk);
            #1;
        end
    endtask

    logic signed [25:0] g26;
    logic [23:0] a2_24;
    logic signed [21:0] a1_22;
    logic signed [31:0] y1, y2, xv;
    int i, j;

    initial begin
        old_start=0; old_n_modes='0; old_x='0; old_voice='0;
        old_clear=0; old_clear_voice='0;
        old_cfg_we=0; old_cfg_voice='0; old_cfg_local='0; old_cfg_wdata='0;
        old_seed_we=0; old_seed_voice='0; old_seed_local='0; old_seed_wdata='0;
        old_a1_we=0; old_a1_addr='0; old_a1_wdata='0; old_b_mask='0;
        old_coeff_rd_en=0; old_coeff_rd_addr='0;
        cfg_we=0; cfg_voice='0; cfg_mode='0; cfg_data='0;
        clr_we=0; clr_voice='0; clr_mode='0;
        seed_we=0; seed_voice='0; seed_mode='0; seed_data='0;
        new_start=0; new_n_modes='0; new_x='0; new_voice='0;
        old_cc=0; new_cc=0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // 2 个 lane0 mode：mode0、mode4
        for (i = 0; i < 2; i = i + 1) begin
            g26   = ($random(seed) & 26'h3ffffff);          // 0..~1
            a2_24 = 24'h80_0000 + ($random(seed) & 24'h1F_FFFF); // 0.5..0.625
            a1_22 = (($random(seed) & 22'h0F_FFFF) - 22'sh08_0000); // ±0.5
            y1    = $random(seed);
            y2    = $random(seed);
            write_pair(i*4, g26, a2_24, a1_22, y1, y2);
        end

        for (j = 0; j < 20; j = j + 1) begin
            xv = $random(seed);
            run_frame(5, xv);

            if (old_ps !== new_ps) begin
                $display("FAIL frame %0d ps old=%0d new=%0d", j, old_ps, new_ps);
                errors = errors + 1;
            end
            if (old_sat !== new_sat) begin
                $display("FAIL frame %0d sat old=%0d new=%0d", j, old_sat, new_sat);
                errors = errors + 1;
            end
            if (old_cc != 2 || new_cc != 2) begin
                $display("FAIL frame %0d commit_cnt old=%0d new=%0d", j, old_cc, new_cc);
                errors = errors + 1;
            end else begin
                for (i = 0; i < 2; i = i + 1) begin
                    if ((old_modes[i] !== new_modes[i]) ||
                        (old_y1s[i] !== new_y1s[i]) ||
                        (old_y2s[i] !== new_y2s[i])) begin
                        $display("FAIL frame %0d mode %0d old=(%0d,%0d,%0d) new=(%0d,%0d,%0d)",
                                 j, i, old_modes[i], old_y1s[i], old_y2s[i],
                                 new_modes[i], new_y1s[i], new_y2s[i]);
                        errors = errors + 1;
                    end
                end
            end
        end

        if (errors == 0)
            $display("PASS tb_eng1_lane_equiv");
        else
            $display("FAIL tb_eng1_lane_equiv errors=%0d", errors);

        $finish;
    end

endmodule
