// -----------------------------------------------------------------------------
// tb_eng1_lane_core.sv -- ENG1 纯计算 lane + modal_ram 的单 voice 单测
//
// 覆盖：
//   * n_modes=5 时 lane0 处理 mode 0/4，partial_sum 正确；
//   * 写回 y1/y2，且系数保留；
//   * 非零 a1/a2 的递推。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_eng1_lane_core;

    import modal_record_pkg::*;

    localparam int SLOTS = 2;
    localparam int MODES = 8;
    localparam int LANES = 4;
    localparam int LOCAL = (MODES + LANES - 1) / LANES;   // 2
    localparam int AW    = $clog2(SLOTS * LOCAL);          // 2
    localparam int VW    = $clog2(SLOTS);                  // 1
    localparam int MW    = $clog2(MODES);                  // 3

    logic clk = 0;
    logic rst_n = 0;

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

    // core
    logic start;
    logic [MW-1:0] n_modes;
    logic signed [31:0] x_in;
    logic [VW-1:0] voice;

    logic core_rd_re;
    logic [AW-1:0] core_rd_addr;
    logic core_st_we;
    logic [AW-1:0] core_st_addr;
    logic [63:0] core_st_data;
    logic done, busy;
    logic commit_valid;
    logic [VW-1:0] commit_voice;
    logic [MW-1:0] commit_mode;
    logic signed [31:0] commit_y1, commit_y2;
    logic commit_sat;
    logic signed [63:0] partial_sum;
    logic [5:0] sat_count;

    // 测试读口（core 空闲时用）
    logic tb_rd_re;
    logic [AW-1:0] tb_rd_addr;

    int errors = 0;
    int commit_cnt = 0;
    logic [MW-1:0] commit_modes [0:7];
    logic signed [31:0] commit_y1s [0:7];
    logic signed [31:0] commit_y2s [0:7];

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
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .start(start), .n_modes(n_modes), .x_in(x_in), .voice(voice),
        .rd_re(core_rd_re), .rd_addr(core_rd_addr),
        .rd_data(rd_data[0*REC_W +: REC_W]),
        .st_we(core_st_we), .st_addr(core_st_addr), .st_data(core_st_data),
        .done(done), .busy(busy),
        .commit_valid(commit_valid), .commit_voice(commit_voice),
        .commit_mode(commit_mode), .commit_y1(commit_y1),
        .commit_y2(commit_y2), .commit_sat(commit_sat),
        .partial_sum(partial_sum), .sat_count(sat_count)
    );

    // lane0 读口在 core busy 时归 core，否则归 testbench
    assign rd_re[0] = busy ? core_rd_re : tb_rd_re;
    assign rd_addr[0*AW +: AW] = busy ? core_rd_addr : tb_rd_addr;
    assign rd_re[LANES-1:1] = '0;
    assign rd_addr[LANES*AW-1:AW] = '0;

    assign st_we = {{(LANES-1){1'b0}}, core_st_we};
    assign st_addr = {{(LANES-1){1'b0}}, core_st_addr};
    assign st_data = {{(LANES-1){1'b0}}, core_st_data};

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (commit_valid) begin
            commit_modes[commit_cnt] <= commit_mode;
            commit_y1s[commit_cnt]   <= commit_y1;
            commit_y2s[commit_cnt]   <= commit_y2;
            commit_cnt <= commit_cnt + 1;
        end
    end

    task automatic check64(input string name, input logic signed [63:0] got,
                           input logic signed [63:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %-16s got=%0d exp=%0d", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check32(input string name, input logic [31:0] got,
                           input logic [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %-16s got=%08x exp=%08x", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    task automatic cfg_write(input int v, input int m, input logic [REC_W-1:0] rec);
        begin
            @(negedge clk);
            cfg_we = 1; cfg_voice = v[VW-1:0]; cfg_mode = m[MW-1:0];
            cfg_data = rec;
            @(posedge clk);
            @(negedge clk);
            cfg_we = 0;
        end
    endtask

    task automatic read_rec(input int v, input int m, output logic [REC_W-1:0] rec);
        int lane, loc, addr;
        begin
            lane = m % LANES;
            loc  = m / LANES;
            addr = v * LOCAL + loc;
            @(negedge clk);
            tb_rd_re = 1; tb_rd_addr = addr[AW-1:0];
            @(posedge clk);
            #1;
            rec = rd_data[lane*REC_W +: REC_W];
            @(negedge clk);
            tb_rd_re = 0;
        end
    endtask

    task automatic run_frame(input int n, input logic signed [31:0] xv);
        begin
            wait (!busy);
            @(negedge clk);
            start = 1; n_modes = n[MW-1:0]; x_in = xv; voice = '0;
            @(posedge clk);
            @(negedge clk);
            start = 0;
            wait (done);
            @(posedge clk);
            #1;
        end
    endtask

    logic [REC_W-1:0] rec;
    logic [REC_W-1:0] r0, r4;

    initial begin
        cfg_we = 0; cfg_voice = '0; cfg_mode = '0; cfg_data = '0;
        clr_we = 0; clr_voice = '0; clr_mode = '0;
        seed_we = 0; seed_voice = '0; seed_mode = '0; seed_data = '0;
        start = 0; n_modes = '0; x_in = '0; voice = '0;
        tb_rd_re = 0; tb_rd_addr = '0;
        commit_cnt = 0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- frame 1: n=5, G=1, a1=a2=0, x=0.25 ----
        rec = '0;
        rec = rec_set(rec, E1_G, 32'h0100_0000);
        cfg_write(0, 0, rec);
        cfg_write(0, 4, rec);

        run_frame(5, 32'sh1000_0000);

        check64("ps n=5", partial_sum, 64'sd536870912); // 2 * 0x10000000
        check32("sat n=5", {26'd0, sat_count}, 32'd0);
        if (commit_cnt != 2) begin
            $display("FAIL commit_cnt=%0d exp=2", commit_cnt);
            errors = errors + 1;
        end
        if (commit_modes[0] !== 3'd0 || commit_modes[1] !== 3'd4) begin
            $display("FAIL commit modes %0d %0d", commit_modes[0], commit_modes[1]);
            errors = errors + 1;
        end
        check32("commit0.y1", commit_y1s[0], 32'h1000_0000);
        check32("commit1.y1", commit_y1s[1], 32'h1000_0000);

        read_rec(0, 0, r0);
        read_rec(0, 4, r4);
        check32("r0.G",  rec_get(r0, E1_G), 32'h0100_0000);
        check32("r0.y1", rec_get(r0, E1_Y1), 32'h1000_0000);
        check32("r0.y2", rec_get(r0, E1_Y2), 32'h0000_0000);
        check32("r4.y1", rec_get(r4, E1_Y1), 32'h1000_0000);

        // ---- frame 2: n=1, G=0, a1=-0.5, a2=0.25, y1=0.25, x=0 ----
        rec = '0;
        rec = rec_set(rec, E1_G,  32'h0000_0000);
        rec = rec_set(rec, E1_A1, 32'hFFF8_0000);   // -524288 Q2.20 = -0.5
        rec = rec_set(rec, E1_A2, 32'h0040_0000);   // 0.25 * 2^24
        rec = rec_set(rec, E1_Y1, 32'h1000_0000);   // 0.25 Q2.30
        rec = rec_set(rec, E1_Y2, 32'h0000_0000);
        cfg_write(0, 0, rec);

        run_frame(1, 32'sd0);
        check64("ps a1/a2", partial_sum, 64'sd134217728); // 0.125
        read_rec(0, 0, r0);
        check32("a1.y1", rec_get(r0, E1_Y1), 32'h0800_0000);
        check32("a1.y2", rec_get(r0, E1_Y2), 32'h1000_0000);

        if (errors == 0)
            $display("PASS tb_eng1_lane_core");
        else
            $display("FAIL tb_eng1_lane_core errors=%0d", errors);

        $finish;
    end

endmodule
