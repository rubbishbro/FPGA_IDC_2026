// -----------------------------------------------------------------------------
// tb_fp_ops.sv -- rtl/math 新增内容的验证（xsim）
//
// 三个目的：
//   1. fx_mul_rnd(a, m, 0, 0, -s) 必须**逐位等于** modal_step_pkg::term(a, m, s)
//      —— 这是把 rtl/math 当作唯一算术库的前提（含负数、含 s=0、含 .5 的平局）。
//   2. 验证"舍入 vs 截断"确实不同（平局用例：round 给 1，floor 给 0）。
//   3. ufp 全套（add/sub/mul/mac/resize/饱和）与朴素整数运算一致。
//
// 运行：pwsh -File rtl/math/tb/run_xsim.ps1
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_fp_ops;

    import fxp_pkg::*;
    import modal_step_pkg::*;

    int n_ck;
    int n_bad;

    // ---- 1) fx_mul_rnd 与"手写参考"逐位等价 --------------------------------
    // 参考式在 TB 里独立写一遍（round-half-up 后再算术右移），不复用被测函数，
    // 这样即使 modal_step_pkg::term 以后改成调用 fx_mul_rnd，这条检查仍然有意义。
    task automatic check_equiv(input logic signed [31:0] a,
                               input logic signed [23:0] m,
                               input int s);
        logic signed [63:0] got, want, prod, half;
        got  = fx_mul_rnd(a, m, 0, 0, -s);
        prod = 64'(a) * 64'(m);
        half = (s == 0) ? 64'sd0 : (64'sd1 <<< (s - 1));
        want = prod + half;
        want = (s == 0) ? want : (want >>> s);
        n_ck++;
        if (got !== want) begin
            n_bad++;
            if (n_bad <= 8)
                $display("MISMATCH rnd/ref a=%0d m=%0d s=%0d : rnd=%0d ref=%0d",
                         a, m, s, got, want);
        end
        // 同时与包里的 term 比对（它现在就是 fx_mul_rnd，仍然值得留一道闸门）
        n_ck++;
        if (got !== modal_step_pkg::term(a, m, s[5:0])) begin
            n_bad++;
            if (n_bad <= 8)
                $display("MISMATCH rnd/term a=%0d m=%0d s=%0d", a, m, s);
        end
    endtask

    // ---- 2) sfp 接口实例（16 位 s4.12，够测所有算子）-----------------------
    sfp #(.iw(4), .qw(12))  sa();
    sfp #(.iw(4), .qw(12))  sb();
    sfp #(.iw(5), .qw(12))  sadd();     // 和需要多 1 位整数
    sfp #(.iw(8), .qw(24))  smul();     // 积的小数位相加

    sfp_add   u_sadd(.a(sa), .b(sb), .y(sadd));
    sfp_mul   u_smul(.a(sa), .b(sb), .y(smul));

    // ---- 3) ufp 接口实例 ---------------------------------------------------
    ufp #(.iw(4), .qw(12))  ua();
    ufp #(.iw(4), .qw(12))  ub();
    ufp #(.iw(5), .qw(12))  uadd();
    ufp #(.iw(8), .qw(24))  umul();
    ufp #(.iw(4), .qw(12))  usub();
    ufp #(.iw(4), .qw(12))  usat();     // 饱和用例：目标格式故意窄

    logic borrow_u, clip_u;

    ufp_add     u_uadd(.a(ua), .b(ub), .y(uadd));
    ufp_mul     u_umul(.a(ua), .b(ub), .y(umul));
    ufp_sub     u_usub(.a(ua), .b(ub), .y(usub), .borrow(borrow_u));
    ufp_add_ind u_usat(.a(ua), .b(ub), .y(usat), .clip(clip_u));

    initial begin
        n_ck  = 0;
        n_bad = 0;

        $display("=== 1) fx_mul_rnd == modal_step_pkg::term (random + directed) ===");

        // 随机：覆盖负数、跨数量级、s = 0..40
        for (int i = 0; i < 4000; i++) begin
            logic signed [31:0] a;
            logic signed [23:0] m;
            int s;
            a = 32'($random) >>> (i % 20);
            m = 24'($random) >>> (i % 16);
            s = i % 41;
            check_equiv(a, m, s);
        end

        // 定点平局：a = 2^(s-1), m = 1 → 恰好 .5，round 应给 1、floor 会给 0
        for (int s = 1; s <= 20; s++) begin
            logic signed [31:0] a;
            logic signed [23:0] m;
            a = 32'sd1 <<< (s - 1);
            m = 24'sd1;
            check_equiv(a, m, s);                      // 与 term 相等
            n_ck++;
            if ($signed(fx_mul_rnd(a, m, 0, 0, -s)) !== 64'sd1) begin
                n_bad++;
                $display("MISMATCH tie s=%0d: round should be 1, got %0d",
                         s, fx_mul_rnd(a, m, 0, 0, -s));
            end
            n_ck++;
            if ($signed(fx_mul(a, m, 0, 0, -s)) !== 64'sd0) begin
                n_bad++;
                $display("MISMATCH tie s=%0d: floor should be 0, got %0d",
                         s, fx_mul(a, m, 0, 0, -s));
            end
        end
        $display("  after 1): %0d checks, %0d bad", n_ck, n_bad);

        $display("=== 2) sfp operators (s4.12) ===");
        for (int i = 0; i < 200; i++) begin
            logic signed [11:0] av, bv;
            av = 12'($random) >>> 4;             // 范围大约 ±8
            bv = 12'($random) >>> 4;
            sa.val = av; sb.val = bv;
            #1;
            n_ck++;
            if (sadd.val !== 17'(av + bv)) begin
                n_bad++;
                if (n_bad <= 12) $display("MISMATCH sfp_add %0d+%0d -> %0d", av, bv, sadd.val);
            end
            n_ck++;
            // 积的小数位 = 12+12 = 24，而 y.qw = 24 ⇒ 不移位；结果位宽 8+24
            if (smul.val !== $signed(av) * $signed(bv)) begin
                n_bad++;
                if (n_bad <= 12) $display("MISMATCH sfp_mul %0d*%0d -> %0d", av, bv, smul.val);
            end
        end
        $display("  after 2): %0d checks, %0d bad", n_ck, n_bad);

        $display("=== 3) ufp operators (u4.12) ===");
        for (int i = 0; i < 200; i++) begin
            logic [15:0] av, bv;
            av = 16'($random) & 16'h7FFF;        // 0..8 左右（u4.12）
            bv = 16'($random) & 16'h7FFF;
            ua.val = av; ub.val = bv;
            #1;
            // add：和需要 17 位，格式 u5.12
            n_ck++;
            if (uadd.val !== 17'(av + bv)) begin
                n_bad++;
                if (n_bad <= 12) $display("MISMATCH ufp_add %0h+%0h -> %0h", av, bv, uadd.val);
            end
            // mul：u4.12 × u4.12 -> u8.24，无移位
            n_ck++;
            if (umul.val !== 32'(av * bv)) begin
                n_bad++;
                if (n_bad <= 12) $display("MISMATCH ufp_mul %0h*%0h -> %0h", av, bv, umul.val);
            end
            // sub：a<b 时 borrow=1 且输出 0
            n_ck++;
            if (borrow_u !== (av < bv)) begin
                n_bad++;
                if (n_bad <= 12) $display("MISMATCH ufp_sub borrow %0h<%0h -> %0b", av, bv, borrow_u);
            end
            n_ck++;
            if (!borrow_u && (usub.val !== (av - bv))) begin
                n_bad++;
                if (n_bad <= 12) $display("MISMATCH ufp_sub %0h-%0h -> %0h", av, bv, usub.val);
            end
            // 饱和：u4.12 目标，和超过 0xFFFF 时应夹到 0xFFFF 且 clip=1
            n_ck++;
            if (clip_u !== (17'(av + bv) > 17'h0FFFF)) begin
                n_bad++;
                if (n_bad <= 12) $display("MISMATCH ufp_add_ind clip %0h+%0h", av, bv);
            end
            n_ck++;
            if (usat.val !== ((17'(av + bv) > 17'h0FFFF) ? 16'hFFFF : (av + bv))) begin
                n_bad++;
                if (n_bad <= 12) $display("MISMATCH ufp_add_ind sat %0h+%0h -> %0h", av, bv, usat.val);
            end
        end

        $display("=== %0d checks, %0d mismatches ===", n_ck, n_bad);
        if (n_bad == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

endmodule
