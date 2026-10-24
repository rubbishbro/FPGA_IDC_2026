`timescale 1ns/1ps
// =============================================================================
// tb_throughput -- 吞吐体检：钢琴 80 模态 x 16 声部，一个采样到底要多少拍
//
//   把 smp_tick 周期设成 1 拍（CLK_HZ/SR_HZ = 1），FSM 就不用等节拍，
//   于是"相邻两个 y_valid 之间"的拍数就是**纯计算时间**（含腔体）。
//   最低工作频率 = 每采样拍数 x 48000。
//
//   两个相位：
//     dead : fmap 全 0  -> 包络为 0 -> voice_dead=1 -> 引擎每帧多跑一趟清零 pass
//     live : fmap 全 200 -> 16 个声部都在响（第一帧还带 note-on/调制）
//
//   运行（仓根目录）：
//     xvlog -sv <RTL 列表> rtl/router/tb_throughput.sv
//     xelab tb_throughput -s tb_tp --debug typical -timescale 1ns/1ps
//     xsim tb_tp -runall
// =============================================================================
module tb_throughput;

    localparam int SLOTS   = 16;
    localparam int N_MODES = 80;      // 钢琴：每声部 80 个模态
    localparam int PM_MODES = 80;
    localparam int NSAMP   = 8;

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;             // 100 MHz（只用来算拍，跟结果无关）

    pad_driver_pkg::mat4x4 fmap;
    router_pkg::instrument_e inst;
    logic        reload = 0, start = 0;
    logic [4:0]  n_voices;
    logic [6:0]  n_modes;
    logic [6:0]  n_samples;
    logic        ready, busy, done, y_valid;
    logic signed [63:0] y_data;
    logic        ns_rd_en = 0, ns_rd_sel = 0;
    logic [10:0] ns_rd_addr = 0;
    logic signed [31:0] ns_rd_data;
    logic        ns_rd_valid;

    voice_router #(
        .SLOTS(SLOTS), .N_MODES(N_MODES), .PM_MODES(PM_MODES),
        // 节拍周期 = 1 拍 -> 不等节拍，直接量计算时间
        .CLK_HZ(100_000_000), .SR_HZ(100_000_000),
        .DEBUG_PORT(1'b0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .fmap(fmap), .inst(inst),
        .reverb_preset(router_pkg::REVERB_NONE),
        .reload(reload), .start(start),
        .n_voices(n_voices), .n_modes(n_modes), .n_samples(n_samples),
        .ready(ready), .busy(busy), .done(done),
        .y_valid(y_valid), .y_data(y_data),
        .qspi_cs_n(), .qspi_sck(), .qspi_dq_o(), .qspi_dq_oe(), .qspi_dq_i(4'b0),
        .ns_rd_en(ns_rd_en), .ns_rd_addr(ns_rd_addr), .ns_rd_sel(ns_rd_sel),
        .ns_rd_data(ns_rd_data), .ns_rd_valid(ns_rd_valid)
    );

    // ---- 拍计数与间隔统计 ----
    longint cyc = 0;
    longint last_cyc = -1;
    int     n_yv = 0, dmin = 0, dmax = 0;
    longint dsum = 0;
    longint t0 = 0, t1 = 0;

    always @(posedge clk) cyc = cyc + 1;

    always @(posedge clk) begin
        if (y_valid) begin
            if (last_cyc >= 0) begin
                int d;
                d = int'(cyc - last_cyc);
                if (n_yv == 1 || d < dmin) dmin = d;
                if (d > dmax) dmax = d;
                dsum = dsum + d;
            end
            last_cyc = cyc;
            n_yv     = n_yv + 1;
        end
    end

    task automatic clear_stats();
        n_yv = 0; last_cyc = -1; dmin = 0; dmax = 0; dsum = 0;
    endtask

    task automatic run_job(input string name, input logic [7:0] press);
        for (int i = 0; i < SLOTS; i++) fmap.flat_d[i].val = press;
        clear_stats();
        t0 = cyc;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        t1 = cyc;
        repeat (2) @(posedge clk);
        $display("[%0s] y_valid=%0d  gap min/avg/max = %0d / %0d / %0d 拍",
                 name, n_yv, dmin, (n_yv > 1) ? int'(dsum / (n_yv - 1)) : 0, dmax);
        // 作业总拍数 / 采样 = 含首帧（note-on）和收尾排空的平均
        $display("         作业总拍 %0d，平均 %0d 拍/采样（含首帧 note-on 与收尾排空）",
                 t1 - t0, (t1 - t0) / NSAMP);
        $display("         -> 48 kHz 最低 %0d MHz（按最坏 %0d 拍）",
                 (dmax * 48) / 1000, dmax);
    endtask

    initial begin
        for (int i = 0; i < SLOTS; i++) fmap.flat_d[i].val = 8'd0;
        inst      = router_pkg::INST_PIANO;
        n_voices  = SLOTS;
        n_modes   = N_MODES;
        n_samples = NSAMP;
        rst_n     = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // 预热一个作业：把加载器走完、系数表填上占位数据
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        repeat (5) @(posedge clk);

        $display("== voice_router：钢琴 %0d 模态 x %0d 声部，%0d 采样/作业，节拍周期=1 拍 ==",
                 N_MODES, SLOTS, NSAMP);
        run_job("dead", 8'd0);      // 全静音：每声部每帧都要跑清零 pass
        run_job("live", 8'd200);    // 全在响（首帧带 note-on）

        $finish;
    end
endmodule
