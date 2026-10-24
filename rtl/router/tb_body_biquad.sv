`timescale 1ns/1ps
// =============================================================================
// tb_body_biquad -- 腔体滤波器三个用例的逐点比对
//
//   case 1 passthru : 5 段全直通（直接喂 body_biquad）  -> 输出 == 输入
//   case 2 single   : 只有第 0 段是吉他实测系数，第 1..4 段直通（直接喂 biquad）
//   case 3 five     : 走**真的 body_router**（INST_GUITAR 常量表 + 内嵌 biquad）
//
// 期望值由 rtl/router/tools/bq_gen.py 用 python/modal_sim/body_fixed_point.py
// （Q4.27 + (acc + 2**26) >>> 27，逐段 (64+G) 位饱和）算好，写到
// rtl/router/tools/bq_exp_*.mem；本 tb 与它逐样本比，任何一位不同都算失败。
//
// 运行（仓根目录）：pwsh -File rtl/router/tools/run_bq.ps1
//   xvlog -sv rtl/math/pkg/fxp_pkg.sv rtl/router/pkg/router_pkg.sv \
//             rtl/router/parts/body_biquad.sv rtl/router/routers/body_router.sv \
//             rtl/router/tb_body_biquad.sv
//   xelab tb_body_biquad -s tb_bq --debug typical -timescale 1ns/1ps
//   xsim tb_bq -runall
// =============================================================================
module tb_body_biquad;

    localparam int NSEC       = 5;
    localparam int NTAP       = 5;
    localparam int COEFF_FRAC = 27;
    localparam int GUARD_BITS = 4;
    localparam int NSAMP      = 512;
    localparam int SLOTS      = 16;

    localparam logic signed [31:0] ONE = 32'sd1 <<< COEFF_FRAC;

    // 向量文件（相对仓根）。$readmemh 只吃字面量/常量，不吃任务参数。
    localparam string STIM_FILE    = "rtl/router/tools/bq_stim.mem";
    localparam string COEF_SINGLE  = "rtl/router/tools/bq_coef_single.mem";
    localparam string EXP_PASSTHRU = "rtl/router/tools/bq_exp_passthru.mem";
    localparam string EXP_SINGLE   = "rtl/router/tools/bq_exp_single.mem";
    localparam string EXP_FIVE     = "rtl/router/tools/bq_exp_five.mem";

    logic clk   = 1'b0;
    logic rst_n;                               // 在 initial 里打 0 才有 negedge
    always #5 clk = ~clk;                      // 100 MHz

    logic                              clear;
    router_pkg::instrument_e           rt_inst;   // body_router 的乐器号（换乐器会清腔体）
    logic                              in_valid;
    logic signed [63:0]                in_sum;
    logic signed [NSEC*NTAP-1:0][31:0]  coef_q;
    logic signed [31:0]                coef_mem [0:NSEC*NTAP-1];

    // 被测 1：body_biquad（系数由 tb 喂，跑 直通 / 单段）
    logic                              bq_in_ready, bq_out_valid;
    logic signed [63:0]                bq_y;
    logic [NSEC-1:0]                   bq_sat;
    logic [2:0]                        bq_sat_cnt;

    // 被测 2：body_router（乐器常量表 + 内嵌 biquad，跑 5 段）
    logic                              rt_in_ready, rt_out_valid;
    logic signed [63:0]                rt_y;

    logic signed [63:0] stim [0:NSAMP-1];
    logic signed [63:0] expd [0:NSAMP-1];
    logic signed [63:0] got_bq [0:NSAMP-1];
    logic signed [63:0] got_rt [0:NSAMP-1];

    // ------------------------------------------------------------------
    body_biquad #(
        .NSEC(NSEC), .NTAP(NTAP),
        .COEFF_FRAC(COEFF_FRAC), .GUARD_BITS(GUARD_BITS)
    ) u_bq (
        .clk(clk), .rst_n(rst_n),
        .clear(clear),
        .in_valid(in_valid), .in_ready(bq_in_ready), .in_sum(in_sum),
        .coef_q(coef_q),
        .out_valid(bq_out_valid), .out_sum(bq_y),
        .out_sat(bq_sat), .sat_count(bq_sat_cnt)
    );

    body_router #(
        .SLOTS(SLOTS), .NSEC(NSEC), .NTAP(NTAP),
        .COEFF_FRAC(COEFF_FRAC), .GUARD_BITS(GUARD_BITS)
    ) u_rt (
        .clk(clk), .rst_n(rst_n), .inst(rt_inst),
        .in_valid(in_valid), .in_ready(rt_in_ready), .x(in_sum),
        .out_valid(rt_out_valid), .y(rt_y)
    );

    // ------------------------------------------------------------------
    // 采集：out_valid 是单拍脉冲，negedge 采样（距两侧 posedge 各 5 ns）
    // ------------------------------------------------------------------
    int got_n    = 0;      // u_bq
    int got_rt_n = 0;      // u_rt
    int sat_samples = 0;

    always @(negedge clk) begin
        if (bq_out_valid) begin
            if (got_n < NSAMP) got_bq[got_n] = bq_y;
            if (bq_sat_cnt != 3'd0) sat_samples = sat_samples + 1;
            got_n = got_n + 1;
        end
        if (rt_out_valid) begin
            if (got_rt_n < NSAMP) got_rt[got_rt_n] = rt_y;
            got_rt_n = got_rt_n + 1;
        end
    end

    // ------------------------------------------------------------------
    // 用例
    // ------------------------------------------------------------------
    int errors       = 0;
    int checked      = 0;
    string case_name = "";

    task automatic set_case(input int mode);
        // mode 0 = 全直通；1 = 第 0 段用 bq_coef_single.mem（吉他第 0 段），其余直通
        for (int s = 0; s < NSEC; s++)
            for (int t = 0; t < NTAP; t++)
                coef_q[s*NTAP + t] = (t == 0) ? ONE : 32'sd0;
        if (mode == 1) for (int i = 0; i < NSEC*NTAP; i++) coef_q[i] = coef_mem[i];
    endtask

    task automatic run_case(input int mode, input string name, input int src);
        int                  bad;
        logic signed [63:0]  got_v;
        case_name = name;
        case (mode)
            0:       $readmemh(EXP_PASSTHRU, expd);
            1:       $readmemh(EXP_SINGLE, expd);
            default: $readmemh(EXP_FIVE, expd);
        endcase
        set_case(mode);
        got_n    = 0;
        got_rt_n = 0;
        bad      = 0;

        @(negedge clk); clear = 1'b1;      // 清 body_biquad 的历史
        @(negedge clk); clear = 1'b0;
        // body_router 现在只在**换乐器**时清历史：这里用一次 inst 往返把它清干净
        @(negedge clk); rt_inst = router_pkg::INST_PIANO;
        @(negedge clk); @(negedge clk);
        @(negedge clk); rt_inst = router_pkg::INST_GUITAR;
        repeat (4) @(negedge clk);

        // 送激励：两个被测同时收同一串样本；慢的那个 ready 为低就等
        for (int i = 0; i < NSAMP; i++) begin
            while (!(bq_in_ready && rt_in_ready)) @(negedge clk);
            in_valid = 1'b1;
            in_sum   = stim[i];
            @(negedge clk);
            in_valid = 1'b0;
        end

        while (got_n < NSAMP || got_rt_n < NSAMP) @(negedge clk);
        #1;                                              // 越过采集 always 的更新

        for (int i = 0; i < NSAMP; i++) begin
            got_v = (src == 0) ? got_bq[i] : got_rt[i];
            if (got_v !== expd[i]) begin
                bad++;
                errors++;
                if (bad <= 6)
                    $display("  [%0s] MISMATCH n=%0d rtl=%0d exp=%0d diff=%0d",
                             name, i, got_v, expd[i], got_v - expd[i]);
            end
        end
        checked += NSAMP;
        $display("[%0s] %0d/%0d samples %s   (%0s)",
                 name, NSAMP - bad, NSAMP, (bad == 0) ? "bit-exact" : "MISMATCH",
                 (src == 0) ? "body_biquad" : "body_router");
    endtask

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    initial begin
        clear    = 1'b0;
        rt_inst  = router_pkg::INST_GUITAR;
        in_valid = 1'b0;
        in_sum   = 64'sd0;
        coef_q   = '0;
        rst_n    = 1'b0;                                 // X->0 是 negedge：真的复位
        $readmemh(STIM_FILE, stim);
        $readmemh(COEF_SINGLE, coef_mem);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        $display("== body 频率响应：Q4.%0d，%0d 段 x %0d tap，G=%0d，%0d 样本/用例 ==",
                 COEFF_FRAC, NSEC, NTAP, GUARD_BITS, NSAMP);
        $display("   stimulus: n=0 impulse=%0d, n=1 x=%0d, n=511 x=%0d",
                 stim[0], stim[1], stim[NSAMP-1]);

        run_case(0, "passthru", 0);
        run_case(1, "single",   0);
        run_case(2, "five",     1);

        $display("== 合计：%0d 样本比对，%0d 处不一致，body_biquad 饱和样本 %0d ==",
                 checked, errors, sat_samples);
        if (errors == 0 && checked == 3*NSAMP) $display("RESULT: PASS");
        else                                   $display("RESULT: FAIL");
        $finish;
    end

    // 超时保护：两个被测并行，一个样本 93 拍，3 x 512 个样本约 1.5e5 拍 -> 3 ms 够
    initial begin
        #3_000_000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
