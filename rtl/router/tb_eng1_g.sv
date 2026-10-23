// tb_eng1_g：eng1 的黄金判据（照队友 tb_abc_signed 的驱动结构）
//   契约：G=2^24 表示增益 1.0；y = clamp((G*x - (a1<<4)*y1 - a2*y2 + 2^23) >>> 24)
//   判据：G=2^24, a1=a2=0, x=-2^28 -> 每模态 -16，3 模态合计 -48
`timescale 1ns/1ps
module tb_eng1_g;
    localparam int N = 3;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic               start = 0, st_zero = 1;
    logic [6:0]         n_modes = N;
    logic signed [31:0] x_in = 0;

    logic               co_re, st_re, st_we, x_re, yv;
    logic [3:0]         co_addr, st_addr, st_wa, x_addr;
    logic signed [63:0] yd;
    logic signed [31:0] qw, qdw;
    modal_step_pkg::coeff_t cd;

    logic signed [31:0] q_mem [0:N-1], v_mem [0:N-1];
    logic signed [31:0] st_q_r, st_qd_r;

    assign cd.a11 = 32'sh0100_0000;   // G = 1.0
    assign cd.a12 = 32'sd0;
    assign cd.a21 = 32'sd0;

    eng1 #(.N_MODES(N), .X_DEPTH(4)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .st_zero(st_zero), .n_modes(n_modes),
        .co_re(co_re), .co_addr(co_addr), .co_data(cd),
        .st_re(st_re), .st_addr(st_addr), .st_q(st_q_r), .st_qdot(st_qd_r),
        .st_we(st_we), .st_waddr(st_wa), .st_q_wdata(qw), .st_qdot_wdata(qdw),
        .x_re(x_re), .x_addr(x_addr), .x_data(x_in),
        .y_valid(yv), .y_data(yd)
    );

    always @(posedge clk) begin
        if (st_re) begin
            st_q_r  <= q_mem[st_addr];
            st_qd_r <= v_mem[st_addr];
        end
        if (st_we) begin
            q_mem[st_wa] <= qw;
            v_mem[st_wa] <= qdw;
        end
    end


    // 探针：直接看 eng1 内部（不改 RTL）
    integer cyc = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cyc < 40)
            $display("t=%0d st=%0d mi=%0d miq=%0d pg=%0d acc=%0d ynew=%0d we=%b qw=%0d nml=%0d",
                     cyc, dut.st, dut.mi, dut.mi_q, dut.p_g, dut.acc_q, dut.y_new,
                     dut.st_we, dut.st_q_wdata, dut.nmod_lat);
    end
    integer i, errs = 0;
    initial begin
        for (i = 0; i < N; i++) begin q_mem[i] = 0; v_mem[i] = 0; end
        st_q_r = 0; st_qd_r = 0;
        repeat (3) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        x_in = -32'sd268435456;
        @(negedge clk); start = 1; @(posedge clk); @(negedge clk); start = 0;
        wait (yv); #1;
        if (yd === -64'sd805306368) $display("OK  y=%0d (3 x -2^28)", yd);
        else begin $display("FAIL y=%0d exp=-805306368", yd); errs++; end
        $display("q_mem = %0d %0d %0d", q_mem[0], q_mem[1], q_mem[2]);
        if (errs == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
