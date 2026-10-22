`timescale 1ns/1ps
// modulation0 数值验证（每声部一次，alpha 由 fmap_i 内部映射）
module tb_modulation;
    localparam int SLOTS = 1, NM = 4, FS = 48000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic start = 0, busy, done;
    logic [15:0] n_modes = NM;
    logic [7:0]  fmap_i = 8'd0;

    logic p_re;
    logic [$clog2(NM)-1:0] p_mode, co_mode;
    logic signed [31:0] p_c0, p_s0, p_gam, p_theta0, p_g;
    logic [3:0] co_we;
    modal_step_pkg::coeff_t co_wdata;

    modulation0 #(.SLOTS(SLOTS), .N_MODES(NM), .FS(FS)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .n_modes(n_modes), .fmap_i(fmap_i),
        .busy(busy), .done(done),
        .p_re(p_re), .p_mode(p_mode),
        .p_c0(p_c0), .p_s0(p_s0), .p_gam(p_gam), .p_theta0(p_theta0), .p_g(p_g),
        .co_we(co_we), .co_mode(co_mode), .co_wdata(co_wdata)
    );

    // 参数表：组合读（p_mode 直接索引）
    logic signed [31:0] mc0[0:NM-1], ms0[0:NM-1], mgam[0:NM-1], mth[0:NM-1], mg[0:NM-1];
    always_comb begin
        p_c0 = mc0[p_mode]; p_s0 = ms0[p_mode]; p_gam = mgam[p_mode];
        p_theta0 = mth[p_mode]; p_g = mg[p_mode];
    end

    // 写回捕获（按字段）
    modal_step_pkg::coeff_t wmem[0:NM-1];
    logic [NM-1:0] wr_seen;
    always_ff @(posedge clk) begin
        if (|co_we) begin
            if (co_we[0]) wmem[co_mode].a11 <= co_wdata.a11;
            if (co_we[1]) wmem[co_mode].a12 <= co_wdata.a12;
            if (co_we[2]) wmem[co_mode].a21 <= co_wdata.a21;
            if (co_we[3]) wmem[co_mode].a22 <= co_wdata.a22;
            wr_seen[co_mode] <= 1'b1;
            if (co_we != 4'b1111) $display("FAIL: 写使能 %b", co_we);
        end
    end

    function automatic real fabs(input real x); return (x < 0.0) ? -x : x; endfunction
    function automatic longint q30(input real v); return longint'($rtoi(v * 1073741824.0)); endfunction

    localparam real K_ALPHA = 123437.0 / 1073741824.0;   // 与 RTL 一致

    real th[0:NM-1], ex11[0:NM-1], ex12[0:NM-1], ex21[0:NM-1], ex22[0:NM-1];
    real gam, dt, maxerr;

    task automatic prep(input int fm);
        real alpha, d, D, c, s, a12, t, w0;
        int i;
        alpha = 1.0 + fm * K_ALPHA;
        gam   = 1.0;  dt = 1.0 / FS;
        for (i = 0; i < NM; i++) th[i] = 2.0 * 3.14159265 * 82.4 * (i+1) / FS;
        th[3] = 0.9;                       // 这个模态应被门控
        for (i = 0; i < NM; i++) begin
            mc0[i]  = q30($cos(th[i]));
            ms0[i]  = q30($sin(th[i]));
            mgam[i] = 32'sd65536;
            mth[i]  = q30(th[i]);
            mg[i]   = q30(dt / th[i]);
            d = 1.0 - gam / FS;
            D = (alpha - 1.0) * th[i];
            c = $cos(th[i]) - $sin(th[i]) * D;
            s = $sin(th[i]) + $cos(th[i]) * D;
            a12 = d * s * (dt / th[i]) / alpha;
            t = a12 * gam;
            w0 = th[i] * FS;
            ex11[i] = d*c + t;  ex22[i] = d*c - t;
            ex12[i] = a12;      ex21[i] = -a12 * alpha * alpha * w0 * w0;
        end
        fmap_i = 8'(fm);
    endtask

    task automatic run_and_check(input int fm);
        int i, checked, gated;
        real r;
        prep(fm);
        for (i = 0; i < NM; i++) wr_seen[i] = 1'b0;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        #20;
        maxerr = 0.0; checked = 0; gated = 0;
        for (i = 0; i < NM; i++) begin
            if (!wr_seen[i]) begin gated++; continue; end
            checked++;
            r = fabs(wmem[i].a11 / 268435456.0 - ex11[i]);  if (r > maxerr) maxerr = r;
            r = fabs(wmem[i].a22 / 268435456.0 - ex22[i]);  if (r > maxerr) maxerr = r;
            r = fabs(wmem[i].a12 / 1073741824.0 - ex12[i]) / ((ex12[i]==0.0)?1.0:fabs(ex12[i]));
            if (r > maxerr) maxerr = r;
            r = fabs(wmem[i].a21 / 8388608.0 - ex21[i]) / ((ex21[i]==0.0)?1.0:fabs(ex21[i]));
            if (r > maxerr) maxerr = r;
        end
        $display("fmap=%0d checked=%0d gated=%0d max_rel_err=%.3e a11=%0d(exp %.6f) a21[2]=%.4f(exp %.4f)",
                 fm, checked, gated, maxerr, wmem[0].a11, ex11[0],
                 wmem[2].a21 / 8388608.0, ex21[2]);
        if (maxerr < 1.0e-3 && gated == 1) $display("  -> PASS");
        else                               $display("  -> FAIL");
    endtask

    initial begin
        for (int i = 0; i < NM; i++) begin
            mc0[i]='0; ms0[i]='0; mgam[i]='0; mth[i]='0; mg[i]='0;
            wr_seen[i]='0; wmem[i]='0;
        end
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (3) @(posedge clk);
        run_and_check(127);
        run_and_check(255);
        $finish;
    end
endmodule
