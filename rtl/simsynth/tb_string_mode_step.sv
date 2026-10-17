// -----------------------------------------------------------------------------
// tb_string_mode_step.sv -- xsim 测试台：string_mode_step 与 Python 黄金向量逐位比对
//
// 两份向量（golden_piano.txt / golden_guitar.txt）走**同一个 DUT 实例**，因为它们只是
// 系数不同 —— 这正是"吉他与钢琴复用同一模块"的验证方式。
//
// 向量格式（见 gen_golden.py）：每行 20 个十进制数
//   a11 s11 a12 s12 a21 s21 a22 s22 gq sgq gv sgv wo swo q v x q_exp v_exp y_exp
// 以 # 开头的行、空行、以及字段数不足的行都会被跳过。
//
// 运行：见同目录 run_xsim.ps1
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_string_mode_step;

    import modal_step_pkg::*;

    logic signed [QW-1:0] q;
    logic signed [VW-1:0] qdot;
    logic signed [XW-1:0] x;
    logic signed [QW-1:0] q_next;
    logic signed [VW-1:0] qdot_next;
    logic signed [YW-1:0] y;
    coeff_t               c;

    string_mode_step dut (
        .c(c), .q(q), .qdot(qdot), .x(x),
        .q_next(q_next), .qdot_next(qdot_next), .y(y)
    );

    int              n_total;
    int              n_bad;
    int              n_shown;
    string           line;

    `define SCAN_FIELDS "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d"

    task automatic step_case(
        input longint signed a11, input longint signed s11,
        input longint signed a12, input longint signed s12,
        input longint signed a21, input longint signed s21,
        input longint signed a22, input longint signed s22,
        input longint signed gq,  input longint signed sgq,
        input longint signed gv,  input longint signed sgv,
        input longint signed wo,  input longint signed swo,
        input longint signed qi,  input longint signed vi, input longint signed xi,
        input longint signed qe,  input longint signed ve, input longint signed ye,
        input string         src
    );
        c.a11 = a11; c.s11 = s11[SW-1:0];
        c.a12 = a12; c.s12 = s12[SW-1:0];
        c.a21 = a21; c.s21 = s21[SW-1:0];
        c.a22 = a22; c.s22 = s22[SW-1:0];
        c.gq  = gq;  c.sgq = sgq[SW-1:0];
        c.gv  = gv;  c.sgv = sgv[SW-1:0];
        c.wo  = wo;  c.swo = swo[SW-1:0];
        q     = qi;
        qdot  = vi;
        x     = xi;
        #1;                                     // 组合逻辑稳定

        n_total++;
        if ((q_next !== qe) || (qdot_next !== ve) || (y !== ye)) begin
            n_bad++;
            if (n_shown < 8) begin
                n_shown++;
                $display("MISMATCH %s", src);
                $display("  got  q_next=%0d qdot_next=%0d y=%0d",
                         q_next, qdot_next, y);
                $display("  want q_next=%0d qdot_next=%0d y=%0d", qe, ve, ye);
                $display("  (q=%0d v=%0d x=%0d)", q, qdot, x);
            end
        end
    endtask

    task automatic run_file(input string path);
        int              fd;
        int              nread;
        int              n_here;
        longint signed   f[20];
        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("FAIL: cannot open %s", path);
            n_bad++;
            return;
        end
        n_here = 0;
        while (!$feof(fd)) begin
            nread = $fgets(line, fd);
            if (nread == 0) break;
            nread = $sscanf(line, `SCAN_FIELDS,
                             f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8],
                             f[9], f[10], f[11], f[12], f[13], f[14], f[15],
                             f[16], f[17], f[18], f[19]);
            if (nread != 20) continue;            // 注释 / 空行 / 表头
            n_here++;
            step_case(f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9],
                      f[10], f[11], f[12], f[13], f[14], f[15], f[16], f[17],
                      f[18], f[19], path);
        end
        $fclose(fd);
        $display("  %s: %0d cases", path, n_here);
    endtask

    initial begin
        n_total = 0;
        n_bad   = 0;
        n_shown = 0;
        $display("=== string_mode_step: golden-vector check (piano + guitar) ===");
        run_file("golden_piano.txt");
        run_file("golden_guitar.txt");
        $display("=== %0d cases, %0d mismatches ===", n_total, n_bad);
        if (n_bad == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

endmodule
