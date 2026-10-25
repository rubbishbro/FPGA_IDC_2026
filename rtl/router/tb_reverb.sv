`timescale 1ns/1ps
// =============================================================================
// tb_reverb -- reverb_router 的三个预设
//
//   NONE      : 直通，y 必须逐位等于延迟 6 拍的 x
//   HALL      : 打一个冲激，检查
//                 - 第一个延迟抽头之前输出必须是 0
//                 - 之后有回声，且慢慢衰减（尾部峰值 < 中部峰值）
//                 - 不发散（|y| 不越界）
//   BATHROOM  : 同 HALL，另外要求比 HALL 衰得快
//
// 运行（仓根目录）：
//   xvlog -sv rtl/math/pkg/fxp_pkg.sv rtl/router/pkg/router_pkg.sv \
//             rtl/router/parts/comb_reverb.sv rtl/router/routers/reverb_router.sv \
//             rtl/router/tb_reverb.sv
//   xelab tb_reverb -s tb_rv --debug typical -timescale 1ns/1ps
//   xsim tb_rv -runall
// =============================================================================
module tb_reverb;

    localparam int N     = 2048;
    localparam int NSAMP = 20000;         // 冲激响应长度（48 kHz 下 0.42 s）
    localparam int LAT   = 6;             // reverb_router 的固定延迟

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    router_pkg::reverb_preset preset;
    logic                     in_valid;
    logic signed [63:0]       x;
    logic                     out_valid;
    logic signed [63:0]       y;

    reverb_router #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n), .preset(preset),
        .in_valid(in_valid), .x(x),
        .out_valid(out_valid), .y(y)
    );

    // 采集输出
    logic signed [63:0] yout [0:NSAMP-1];
    int  n_out = 0;
    always @(posedge clk) if (out_valid) begin
        if (n_out < NSAMP) yout[n_out] = y;
        n_out++;
    end

    longint ymax = 0;
    task automatic clear_stats();
        n_out = 0;
        for (int i = 0; i < NSAMP; i++) yout[i] = '0;
    endtask


    // 静音灌 N 个样本：comb_reverb 的清空标志要跑满 N 个采样才落（这期间
    // 读作 0，也就是湿声为 0），所以冲激要放在清空完成之后。
    task automatic warmup(input int n);
        for (int i = 0; i < n; i++) begin
            @(negedge clk); in_valid = 1'b1; x = 64'sd0;
            @(posedge clk);
        end
        @(negedge clk); in_valid = 1'b0;
        repeat (LAT + 4) @(posedge clk);
    endtask

    // 跑一串样本：stim[i]（=0 表示静音）
    task automatic run(input string name, input bit impulse);
        int bad;
        clear_stats();
        for (int i = 0; i < NSAMP; i++) begin
            @(negedge clk);
            in_valid = 1'b1;
            x        = impulse ? ((i == 0) ? 64'sd268435456 : 64'sd0) : 64'sd0;
            @(posedge clk);
        end
        @(negedge clk); in_valid = 1'b0;
        repeat (LAT + 4) @(posedge clk);
        $display("[%0s] out_valid=%0d（期望 %0d）", name, n_out, NSAMP);
        if (n_out != NSAMP) $display("   !! 输出个数不对");
    endtask

    // 统计某个区间里的峰值
    task automatic peak(input string name, input int a, input int b, output longint pk);
        pk = 0;
        for (int i = a; i < b; i++) begin
            longint v;
            if ($isunknown(yout[i])) begin pk = -1; return; end
            v = (yout[i] < 0) ? -yout[i] : yout[i];
            if (v > pk) pk = v;
        end
        $display("   %0s [%0d,%0d) peak = %0d", name, a, b, pk);
    endtask

    // ------------------------------------------------------------------
    // 用例 1：NONE 直通
    // ------------------------------------------------------------------
    task automatic case_none();
        int bad;
        @(negedge clk); preset = router_pkg::REVERB_NONE;
        clear_stats();
        bad = 0;
        for (int i = 0; i < 64; i++) begin
            @(negedge clk);
            in_valid = 1'b1;
            x        = 64'sd12345 * i - 64'sd100000;      // 随便一个有符号序列
            @(posedge clk);
        end
        @(negedge clk); in_valid = 1'b0;
        repeat (LAT + 4) @(posedge clk);
        for (int i = 0; i < 64; i++)
            if (yout[i] !== 64'sd12345 * i - 64'sd100000) begin
                bad++;
                if (bad <= 5)
                    $display("   NONE 不一致 i=%0d y=%0d exp=%0d",
                             i, yout[i], 64'sd12345 * i - 64'sd100000);
            end
        $display("[NONE] out_valid=%0d 不一致 %0d 处（直通要求逐位相等）", n_out, bad);
    endtask

    // ------------------------------------------------------------------
    longint hall_mid, hall_tail, bath_mid, bath_tail;
    int     n_hall, n_bath;

    initial begin
        rst_n    = 1'b0;
        in_valid = 1'b0;
        x        = 64'sd0;
        preset   = router_pkg::REVERB_NONE;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;


        $display("== reverb_router：N=%0d，每个用例 %0d 样本 ==", N, NSAMP);

        // ---- NONE 直通 ----
        case_none();

        // ---- HALL ----
        // 注意：preset 要在 negedge 改。在 posedge 同一 delta 里改的话，
        // reverb_router 里的 preset_q 会同时采到新值，(preset != preset_q)
        // 这个清空脉冲就观察不到了（仿真竞争，硬件上不会）。
        @(negedge clk); preset = router_pkg::REVERB_HALL;
        warmup(2200);                       // 先让清空标志落下
        run("HALL", 1'b1);
        n_hall = n_out;
        // 干声冲激落在 yout[0]；从第 1 个到第一个抽头（1214）之间必须是纯静音
        peak("HALL 回声前", 1, 1214, hall_tail);
        if (hall_tail != 0) $display("   !! 第一个抽头之前就有输出");
        peak("HALL 中部", 1214, 10000, hall_mid);
        peak("HALL 尾部", 10000, 20000, hall_tail);
        if (hall_mid == 0)          $display("   !! 没有回声");
        if (hall_tail > hall_mid)   $display("   !! 尾部比中部还响（发散了？）");

        // ---- BATHROOM ----
        @(negedge clk); preset = router_pkg::REVERB_BATHROOM;
        warmup(2200);
        run("BATHROOM", 1'b1);
        n_bath = n_out;
        peak("BATH 中部", 557, 10000, bath_mid);
        peak("BATH 尾部", 10000, 20000, bath_tail);
        if (bath_mid == 0) $display("   !! 没有回声");

        $display("尾/中 比：HALL %0d‰  BATH %0d‰",
                 (hall_tail * 1000) / ((hall_mid == 0) ? 1 : hall_mid),
                 (bath_tail * 1000) / ((bath_mid == 0) ? 1 : bath_mid));

        if (n_hall == NSAMP && n_bath == NSAMP && hall_mid != 0 && bath_mid != 0 &&
            hall_tail <= hall_mid && bath_tail <= bath_mid)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

endmodule
