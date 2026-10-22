`timescale 1ns/1ps
// modulation0 的数值验证：TB 内按实数算参考值，和 RTL 写回的 Q1.30 结果对比
module tb_modulation;
    localparam int SLOTS = 2, NM = 4, FS = 48000;
    localparam int CO = $clog2(SLOTS*NM);

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic signed [31:0] alpha_q;
    logic [15:0] n_modes = NM;
    logic [SLOTS-1:0] active = '1;
    logic start = 0, busy, done;

    logic p_re, co_re;
    logic [3:0] co_we;
    logic [CO-1:0] p_addr, co_addr;
    logic signed [31:0] p_c0, p_s0, p_gam, p_theta0, p_g;
    modal_step_pkg::coeff_t co_wdata;

    modulation0 #(.SLOTS(SLOTS), .N_MODES(NM), .FS(FS)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .active(active),
        .alpha_q(alpha_q), .n_modes(n_modes), .busy(busy), .done(done),
        .p_re(p_re), .p_addr(p_addr),
        .p_c0(p_c0), .p_s0(p_s0), .p_gam(p_gam), .p_theta0(p_theta0), .p_g(p_g),
        .co_we(co_we), .co_addr(co_addr), .co_wdata(co_wdata)
    );

    // ---- 参数/系数存储（1 拍同步读）----
    logic signed [31:0] mc0[0:SLOTS*NM-1], ms0[0:SLOTS*NM-1], mgam[0:SLOTS*NM-1],
                        mth[0:SLOTS*NM-1], mg[0:SLOTS*NM-1];
    modal_step_pkg::coeff_t mco[0:SLOTS*NM-1];

    always_ff @(posedge clk) begin
        if (p_re) begin
            p_c0 <= mc0[p_addr]; p_s0 <= ms0[p_addr]; p_gam <= mgam[p_addr];
            p_theta0 <= mth[p_addr]; p_g <= mg[p_addr];
        end
    end

    // ---- 写回捕获 ----
    modal_step_pkg::coeff_t wmem[0:SLOTS*NM-1];
    logic [SLOTS*NM-1:0]   wr_seen;
    always_ff @(posedge clk) begin
        // 按字段写：只有被使能的字段才更新（真实 RAM 也是这个行为）
        if (|co_we) begin
            if (co_we[0]) wmem[co_addr].a11 <= co_wdata.a11;
            if (co_we[1]) wmem[co_addr].a12 <= co_wdata.a12;
            if (co_we[2]) wmem[co_addr].a21 <= co_wdata.a21;
            if (co_we[3]) wmem[co_addr].a22 <= co_wdata.a22;
            wr_seen[co_addr] <= 1'b1;
            if (co_we != 4'b1111) $display("FAIL: 写使能不是 4'b1111: %b", co_we);
        end
    end

    // ---- 期望值（数学实数）----
    function automatic real fabs(input real x); return (x < 0.0) ? -x : x; endfunction

    function automatic longint q30(input real v);
        return longint'($rtoi(v * 1073741824.0));
    endfunction

    real th[0:SLOTS*NM-1];
    real ex_a11[0:SLOTS*NM-1], ex_a12[0:SLOTS*NM-1], ex_a21[0:SLOTS*NM-1], ex_a22[0:SLOTS*NM-1];
    real alpha, gam, dt;
    real maxerr;

    task automatic prep(input real cents);
        real d, D, c, s, a12, t, w0;
        int i;
        alpha = $exp($ln(2.0) * cents / 1200.0);
        gam   = 1.0;
        dt    = 1.0 / FS;
        // 用例：slot0 = 82.4 Hz 的 1..4 次模态；slot1 = 含一个 theta0=2.5 的高模态（应被门控）
        for (i = 0; i < NM; i++) th[i]         = 2.0 * 3.14159265 * 82.4 * (i+1) / FS;
        th[4] = 0.010; th[5] = 0.030; th[6] = 0.070; th[7] = 0.900;
        for (i = 0; i < SLOTS*NM; i++) begin
            mc0[i]   = q30($cos(th[i]));
            ms0[i]   = q30($sin(th[i]));
            mgam[i]  = $rtoi(65536.0 * gam);
            mth[i]   = q30(th[i]);
            mg[i]    = q30(dt / th[i]);
            mco[i].a11 = 32'sd123; mco[i].a12 = 32'sd456; mco[i].a21 = 32'sd789;
            mco[i].a22 = 32'sd321; mco[i].gq = 32'sd1111; mco[i].gv = 32'sd2222;
            mco[i].wo  = 32'sd3333;
            // 参考
            d  = 1.0 - gam / FS;
            D  = (alpha - 1.0) * th[i];
            c  = $cos(th[i]) - $sin(th[i]) * D;
            s  = $sin(th[i]) + $cos(th[i]) * D;
            a12 = d * s * (dt / th[i]) / alpha;
            t   = a12 * gam;
            w0  = th[i] * FS;
            ex_a11[i] = d * c + t;
            ex_a22[i] = d * c - t;
            ex_a12[i] = a12;
            ex_a21[i] = -a12 * alpha * alpha * w0 * w0;
        end
        alpha_q = q30(alpha);
    endtask

    task automatic run_and_check(input real cents);
        real e, r;
        int  i, checked, gated;
        prep(cents);
        for (i = 0; i < SLOTS*NM; i++) wr_seen[i] = 1'b0;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        #20;
        maxerr = 0.0; checked = 0; gated = 0;
        for (i = 0; i < SLOTS*NM; i++) begin
            if (!wr_seen[i]) begin gated++; continue; end
            checked++;
            r = fabs(wmem[i].a11 / 268435456.0 - ex_a11[i]);
            if (r > maxerr) begin maxerr = r; $display("  worst a11 mode %0d: got %.6f exp %.6f", i, wmem[i].a11/268435456.0, ex_a11[i]); end
            r = fabs(wmem[i].a22 / 268435456.0 - ex_a22[i]);
            if (r > maxerr) maxerr = r;
            r = fabs(wmem[i].a12 / 1073741824.0 - ex_a12[i]);
            if (r > maxerr) maxerr = r;
            r = fabs(wmem[i].a21 / 8388608.0 - ex_a21[i]) / ((ex_a21[i] == 0.0) ? 1.0 : fabs(ex_a21[i]));
            if (r > maxerr) begin maxerr = r; $display("  worst a21 mode %0d: got %.6f exp %.6f", i, wmem[i].a21/8388608.0, ex_a21[i]); end
            // gq/gv/wo 必须原样保留
            if (wmem[i].gq != 32'sd1111 || wmem[i].gv != 32'sd2222 || wmem[i].wo != 32'sd3333)
                $display("FAIL: mode %0d 的 gq/gv/wo 被改写了", i);
        end
        $display("cents=%0d  checked=%0d gated=%0d  max_abs_err=%.3e  a11[0]=%0d (exp %.6f) a21[3]=%.4f (exp %.4f)",
                 cents, checked, gated, maxerr, wmem[0].a11, ex_a11[0],
                 wmem[3].a21 / 8388608.0, ex_a21[3]);
        if (maxerr < 1.0e-3 && gated == 1) $display("  -> PASS");
        else                               $display("  -> FAIL");
    endtask

    initial begin
        for (int i = 0; i < SLOTS*NM; i++) begin
            mc0[i] = '0; ms0[i] = '0; mgam[i] = '0; mth[i] = '0; mg[i] = '0;
            mco[i] = '0; wr_seen[i] = '0;
            wmem[i] = '0; wmem[i].gq = 32'sd1111; wmem[i].gv = 32'sd2222; wmem[i].wo = 32'sd3333;
        end
        alpha_q = 32'sd1 << 30;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (3) @(posedge clk);

        run_and_check(25.0);
        run_and_check(50.0);

        $display("RESULT: %s", (maxerr < 1.0e-3) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
