`timescale 1ns/1ps
// =============================================================================
// tb_throughput -- 吞吐体检：钢琴 80 模态 x 16 声部，一个采样到底要多少拍
//
//   一次作业 = 一个采样。把 smp_tick 周期设成 1 拍（CLK_HZ/SR_HZ = 1），
//   FSM 就不用等节拍，于是"相邻两个作业起点之间"的拍数就是**纯计算时间**。
//   最低工作频率 = 每采样拍数 x 48000。
//
//   两个相位：
//     dead : fmap 全 0   -> 包络为 0 -> voice_dead=1（引擎读状态按 0）
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
    localparam int NJOB    = 8;       // 连续跑 8 个作业，看相邻间隔

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;             // 100 MHz（只用来算拍，跟结果无关）

    pad_driver_pkg::mat4x4 fmap;
    router_pkg::instrument_e inst;
    logic        reload = 0, start = 0;
    logic [6:0]  n_modes;
    logic        ready, done, y_valid;
    logic signed [63:0] y_data;
    logic        ns_rd_en = 0, ns_rd_sel = 0;
    logic [9:0]  ns_rd_addr = 0;   // = CO_SLOT-1:0（VWID + clog2(N_MODES) = 4+6）
    logic signed [31:0] ns_rd_data;
    logic        ns_rd_valid;

    voice_router #(
        .SLOTS(SLOTS), .N_MODES(N_MODES),
        // 节拍周期 = 1 拍 -> 不等节拍，直接量计算时间
        .CLK_HZ(100_000_000), .SR_HZ(100_000_000),
        .DEBUG_PORT(1'b0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .fmap(fmap), .inst(inst),
        .reverb_preset(router_pkg::REVERB_NONE),
        .reload(reload), .start(start),
        .n_modes(n_modes),
        .ready(ready), .done(done), .load_err(),
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

    // 一个作业 = 一个采样。done 是**电平**：先等空闲 -> 发 start -> 等它落下 -> 再等它起来
    task automatic one_sample();
        while (!done) @(posedge clk);
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        while (done)  @(posedge clk);
        while (!done) @(posedge clk);
    endtask

    task automatic run_job(input string name, input logic [7:0] press);
        for (int i = 0; i < SLOTS; i++) fmap.flat_d[i].val = press;
        clear_stats();
        t0 = cyc;
        for (int j = 0; j < NJOB; j++) one_sample();
        t1 = cyc;
        repeat (2) @(posedge clk);
        $display("[%0s] y_valid=%0d  相邻间隔 min/avg/max = %0d / %0d / %0d 拍",
                 name, n_yv, dmin, (n_yv > 1) ? int'(dsum / (n_yv - 1)) : 0, dmax);
        $display("         %0d 个作业共 %0d 拍，平均 %0d 拍/采样（含首帧 note-on 与收尾排空）",
                 NJOB, t1 - t0, (t1 - t0) / NJOB);
        $display("         -> 48 kHz 最低 %0d MHz（按最坏 %0d 拍）",
                 (dmax * 48) / 1000, dmax);
    endtask

    initial begin
        for (int i = 0; i < SLOTS; i++) fmap.flat_d[i].val = 8'd0;
        inst      = router_pkg::INST_PIANO;
        
        n_modes   = N_MODES;
        rst_n     = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // 预热一个作业：把加载器走完、系数表填上占位数据
        one_sample();
        repeat (5) @(posedge clk);

        $display("== voice_router：钢琴 %0d 模态 x %0d 声部，1 作业 = 1 采样，节拍周期 = 1 拍 ==",
                 N_MODES, SLOTS);
        run_job("dead", 8'd0);      // 全静音
        run_job("live", 8'd200);    // 全在响（首帧带 note-on）

        // ---- 吉他：带揉弦，16 个键同时按下 = 首帧要串行跑 16 次调制（F07）----
        inst = router_pkg::INST_GUITAR;
        for (int i = 0; i < SLOTS; i++) fmap.flat_d[i].val = 8'd0;
        one_sample();                  // 先松键，保证下一次是上升沿
        repeat (5) @(posedge clk);
        run_job("gtr-on", 8'd200);   // 首帧：带 note-on + 16 次调制
        run_job("gtr-ss", 8'd200);   // 稳态：没有 note-on
        // 再来一次 16 键齐按，但**不换乐器**（不用重新加载表）-> 只剩调制的开销
        for (int i = 0; i < SLOTS; i++) fmap.flat_d[i].val = 8'd0;
        one_sample();
        repeat (5) @(posedge clk);
        run_job("gtr-mod", 8'd200);  // 只有调制、没有加载

        $finish;
    end
endmodule
