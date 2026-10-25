`timescale 1ns/1ps
// tb_eng1_g：eng1 的黄金判据 + 清零覆盖 + **状态错位** / **满 64 模态** 检查
//
//   契约：G=2^24 表示增益 1.0；y = clamp((G*x - (a1<<4)*y1 - a2*y2 + 2^23) >>> 24)
//         y1' = y_new，y2' = y1（都要用**本模态刚读回来的**状态）
//
//   A) 从零开始：G=2^24, a1=a2=0, x=-2^28 -> 每模态 -2^28
//   B) 清零覆盖所有模态：历史灌 2^28、G=0、a1=2^20，st_zero=1 -> y 必须回 0
//   C) 同一份历史不清零 -> y 不为 0
//   D) **状态不许错位一个模态**（原报告 F05 的复现）：G=0、a1=2^20、a2=0，
//      初始状态 [10, 20, 30]，跑一遍后必须变成 [-10, -20, -30]，y = -60。
//      错位时会是 [0, -10, -20]。
//   E) 满 64 模态（原报告"nmod_lat 用索引位宽，64 截成 0"）：N_MODES=64、n_modes=64、
//      G=2^24、x=1 -> 每个模态 +1，64 个模态 y 必须是 64（截断时是 0）。
//
// 运行（仓根目录）：
//   xvlog -sv rtl/math/pkg/fxp_pkg.sv rtl/router/pkg/modal_step_pkg.sv ^
//             rtl/router/engines/eng1.sv rtl/router/tb_eng1_g.sv
//   xelab tb_eng1_g -s tbg --debug typical -timescale 1ns/1ps
//   xsim tbg --runall
// -----------------------------------------------------------------------------
module tb_eng1_g;
    localparam int N  = 3;      // 前四个用例的模态数
    localparam int NB = 64;     // 用例 E 的模态数（满额）

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    int errs = 0;

    // =================================================================
    // 实例 1：N 个模态（A~D）
    // =================================================================
    logic               start = 0, st_zero = 1;
    logic [6:0]         n_modes = N;
    logic signed [31:0] x_in = 0;

    logic               co_re, st_re, st_we, x_re, yv;
    logic [5:0]         co_addr, st_addr, st_wa, x_addr;
    logic signed [63:0] yd;
    logic signed [31:0] qw, qdw;
    modal_step_pkg::coeff_t cd;

    logic signed [31:0] q_mem [0:N-1], v_mem [0:N-1];
    logic signed [31:0] st_q_r, st_qd_r;

    logic [31:0] g_coef, a1_coef;
    assign cd.a11 = g_coef;
    assign cd.a12 = a1_coef;
    assign cd.a21 = 32'sd0;

    eng1 #(.N_MODES(N), .X_DEPTH(4)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .st_zero(st_zero), .n_modes(n_modes),
        .co_re(co_re), .co_addr(co_addr), .co_data(cd),
        .st_re(st_re), .st_addr(st_addr), .st_q(st_q_r), .st_qdot(st_qd_r),
        .st_we(st_we), .st_waddr(st_wa), .st_q_wdata(qw), .st_qdot_wdata(qdw),
        .x_re(x_re), .x_addr(x_addr), .x_data(x_in),
        .y_valid(yv), .y_data(yd)
    );

    // 状态存储模型：S_RD 给地址、下一拍数据有效（同步读）；S_WB 写回
    always @(posedge clk) begin
        if (dut.st === 3'd1) begin           // S_RD
            st_q_r  <= q_mem[dut.st_addr];
            st_qd_r <= v_mem[dut.st_addr];
        end
        if (dut.st === 3'd5) begin           // S_WB
            q_mem[dut.st_waddr]  <= dut.st_q_wdata;
            v_mem[dut.st_waddr]  <= dut.st_qdot_wdata;
        end
    end

    // 带看门狗的 run：正常 N 模态 ≈ 10*N 拍出 y_valid
    task automatic run(input logic zero);
        int n;
        st_zero = zero;
        @(negedge clk); start = 1'b1;
        @(posedge clk); @(negedge clk); start = 1'b0;
        n = 0;
        while (!yv) begin
            @(posedge clk);
            n = n + 1;
            if (n > 5000) begin
                $display("   !! 看门狗超时：st=%0d mi=%0d mi_q=%0d nmod=%0d",
                         dut.st, dut.mi, dut.mi_q, dut.nmod_lat);
                errs = errs + 1;
                return;
            end
        end
        #1;
    endtask

    // =================================================================
    // 实例 2：满 64 模态（用例 E）
    // =================================================================
    logic               b_start = 0, b_zero = 0, b_yv;
    logic [7:0]         b_nmodes = NB;
    logic signed [63:0] b_yd;
    logic [31:0]        b_g;
    modal_step_pkg::coeff_t b_cd;
    logic signed [31:0] b_q [0:NB-1], b_v [0:NB-1];
    logic signed [31:0] b_qr, b_vr;

    assign b_cd.a11 = b_g;
    assign b_cd.a12 = 32'sd0;
    assign b_cd.a21 = 32'sd0;

    eng1 #(.N_MODES(NB), .X_DEPTH(4)) dut_b (
        .clk(clk), .rst_n(rst_n), .start(b_start), .st_zero(b_zero), .n_modes(b_nmodes),
        .co_re(), .co_addr(), .co_data(b_cd),
        .st_re(), .st_addr(), .st_q(b_qr), .st_qdot(b_vr),
        .st_we(), .st_waddr(), .st_q_wdata(), .st_qdot_wdata(),
        .x_re(), .x_addr(), .x_data(32'sd1),
        .y_valid(b_yv), .y_data(b_yd)
    );

    always @(posedge clk) begin
        if (dut_b.st === 3'd1) begin
            b_qr <= b_q[dut_b.st_addr];
            b_vr <= b_v[dut_b.st_addr];
        end
    end

    longint y;

    initial begin
        for (int i = 0; i < N; i++) begin q_mem[i] = 0; v_mem[i] = 0; end
        for (int i = 0; i < NB; i++) begin b_q[i] = 0; b_v[i] = 0; end
        st_q_r = 0; st_qd_r = 0; b_qr = 0; b_vr = 0;
        g_coef  = 32'sh0100_0000;    // G = 1.0
        a1_coef = 32'sd0;
        b_g     = 32'sh0100_0000;
        repeat (3) @(posedge clk); rst_n = 1'b1; repeat (3) @(posedge clk);

        // ---------------- A) 从零开始 ----------------
        x_in = -32'sd268435456;
        run(1'b1);
        y = yd;
        if (y === -64'sd805306368) $display("A) 从零:   y=%0d (3 x -2^28)", y);
        else begin $display("A) FAIL y=%0d exp=-805306368", y); errs++; end

        // ---------------- B) 历史灌非零 + 清零 ----------------
        g_coef  = 32'sd0;
        a1_coef = 32'sd1048576;      // a1 = 2^20（<<4 = 1.0）
        x_in    = 32'sd0;
        for (int i = 0; i < N; i++) begin
            q_mem[i] = 32'sd268435456;
            v_mem[i] = 32'sd268435456;
        end
        run(1'b1);
        y = yd;
        if (y === 64'sd0) $display("B) 清零:   y=%0d（所有模态历史都读作 0）", y);
        else begin $display("B) FAIL 清零没覆盖所有模态: y=%0d exp=0", y); errs++; end

        // ---------------- C) 同样的历史、不清零 ----------------
        for (int i = 0; i < N; i++) begin
            q_mem[i] = 32'sd268435456;
            v_mem[i] = 32'sd268435456;
        end
        run(1'b0);
        y = yd;
        if (y != 0) $display("C) 用历史: y=%0d（不为 0，说明没清零时历史确实参与运算）", y);
        else begin $display("C) FAIL 没清零却算成 0"); errs++; end

        // ---------------- D) 状态不许错位一个模态 ----------------
        for (int i = 0; i < N; i++) begin
            q_mem[i] = 32'sd10 * (i + 1);    // [10, 20, 30]
            v_mem[i] = 32'sd0;
        end
        run(1'b0);
        y = yd;
        $display("D) 状态更新后 q_mem = %0d %0d %0d   y=%0d（期望 -10 -20 -30 / -60）",
                 q_mem[0], q_mem[1], q_mem[2], y);
        if (q_mem[0] !== -32'sd10 || q_mem[1] !== -32'sd20 || q_mem[2] !== -32'sd30)
            begin $display("D) FAIL 状态错位（或量纲不对）"); errs++; end
        else if (y !== -64'sd60) begin $display("D) FAIL y=%0d exp=-60", y); errs++; end

        // ---------------- E) 满 64 模态 ----------------
        b_start = 1'b1; @(posedge clk); @(negedge clk); b_start = 1'b0;
        begin : e_wait
            int n;
            n = 0;
            while (!b_yv) begin
                @(posedge clk);
                n = n + 1;
                if (n > 5000) begin
                    $display("   !! E 看门狗超时：st=%0d mi=%0d nmod=%0d",
                             dut_b.st, dut_b.mi, dut_b.nmod_lat);
                    errs = errs + 1;
                    disable e_wait;
                end
            end
            #1;
            if (b_yd === 64'sd64) $display("E) 64 模态: y=%0d（每个模态 +1）", b_yd);
            else begin $display("E) FAIL y=%0d exp=64（nmod_lat 位宽被截断？）", b_yd); errs++; end
        end

        if (errs == 0) $display("RESULT: PASS");
        else           $display("RESULT: FAIL (%0d)", errs);
        $finish;
    end
endmodule
