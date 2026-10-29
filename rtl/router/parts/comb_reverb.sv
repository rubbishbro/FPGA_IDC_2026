`timescale 1ns/1ps
// =============================================================================
// comb_reverb -- 4 条并联梳状延迟线（后级混响的湿声部分）
//
// 每条线：  延迟 n_k 个样点，反馈 g_k，输出加权 w_k
//   s_k      = c_k[p_k]                         （同步读）
//   c_k[p_k] = in + (s_k * g_k)  >>> G_FRAC     （同一地址回写，含反馈）
//   t_k      = (s_k * w_k) >>> G_FRAC
//   wet      = t_0 + t_1 + t_2 + t_3
//
// 流水（每级只干一件事；地址/输入都要跟着流水走，不能只留一份）：
//   A  in_valid : 发读地址 -> 存 ad_a、din_a、s <= c[p]
//   B  v1       : fb <= (s*g)>>>F、t <= (s*w)>>>F、ad_b <= ad_a、din_b <= din_a
//   C  v2       : c[ad_b] <= sat(din_b + fb)（组合算完直接进 RAM 的 D）
//                 sum_q  <= t0+t1+t2+t3
//   D  v3       : wet <= sum_q
//   out_valid 比 in_valid 晚 4 拍。
//
// 说明
//   * c1..c4 必须是**同步读**：2048 x 64 bit x 4 = 512 Kbit，只能用 BSRAM；
//     组合读会变成分布式 RAM，资源上放不下。
//   * 延迟 / 反馈 / 加权都是运行时输入（reverb_router 按预设给），n_k 必须 1..N。
//   * 系数 Q4.27（1.0 = 1<<27）；反馈 |g| < 1.0 才稳定。
//   * 回写饱和用"65 位加法的进位 vs 符号"判，不用 96 位比大小（后者 PnR 实测
//     多花 4 ns 还占一堆 LUT）。
//   * 复位后**不写 0**：挂"清空中"标志，标志期间读出的旧值当 0 用（和 eng0 的
//     st_zero 一个套路），回写照常写新数据；跑满 N 个采样后标志自动落，那时
//     整条线已被新数据覆盖。这样既不用 2048 拍空转，也不会读到 BSRAM 上电的
//     随机值（仿真里是 X，而 X*0=X 会把湿声整条路染成 X）。
//   * 四路写开、不用 for + 2D 数组：xsim 2017.4 对这种写法会把后两路算成 X。
// =============================================================================
module comb_reverb #(
    parameter int N      = 2048,          // 每条线的最大延迟（2^11）
    parameter int G_FRAC = 27             // 反馈/加权 Q4.27
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic [$clog2(N+1)-1:0]       n1, n2, n3, n4,     // 实际用的延迟（1..N，2 的幂也要能到 N）
    input  logic signed [31:0]          g1, g2, g3, g4,     // 反馈 Q4.27
    input  logic signed [31:0]          w1c, w2c, w3c, w4c, // 加权 Q4.27
    input  logic                        clr,        // 清空请求（一拍脉冲）：复位 / 换预设时由上层给
    input  logic                        in_valid,
    input  logic signed [63:0]          in_data,
    output logic                        out_valid,
    output logic signed [63:0]          wet
);

    localparam int AW = $clog2(N);

    (* syn_ramstyle = "block_ram" *) logic signed [63:0] c1 [0:N-1];
    (* syn_ramstyle = "block_ram" *) logic signed [63:0] c2 [0:N-1];
    (* syn_ramstyle = "block_ram" *) logic signed [63:0] c3 [0:N-1];
    (* syn_ramstyle = "block_ram" *) logic signed [63:0] c4 [0:N-1];

    logic [AW-1:0]       p1, p2, p3, p4;              // 读指针
    logic [AW-1:0]       ad_a1, ad_a2, ad_a3, ad_a4;  // A 级地址
    logic [AW-1:0]       ad_b1, ad_b2, ad_b3, ad_b4;  // B 级地址（C 级写 RAM 用）
    logic signed [63:0]  s1, s2, s3, s4;              // RAM 读出
    logic signed [63:0]  din_a, din_b;                // 输入，跟着流水走
    logic signed [63:0]  fb1, fb2, fb3, fb4;          // (s*g)>>>F
    logic signed [68:0]  t1, t2, t3, t4;              // (s*w)>>>F，保留完整 69 位（先不截断）
    logic signed [63:0]  sum_q;
    logic                v1, v2, v3;

    // 清空标志：置位期间"读作 0"，写照常；跑满 N 个采样后落
    logic                clr_run;
    logic                clr_q;                     // 取 clr 的上升沿
    logic [AW-1:0]       clr_cnt;
    logic signed [63:0]  z0;
    logic signed [63:0]  s1_r, s2_r, s3_r, s4_r;

    assign z0   = 64'sd0;
    assign s1_r = clr_run ? z0 : s1;
    assign s2_r = clr_run ? z0 : s2;
    assign s3_r = clr_run ? z0 : s3;
    assign s4_r = clr_run ? z0 : s4;

    // ---- 加权输出：保留 69 位，只在求和那一级饱和一次 --------------------
    //   (s*w) 是 96 位、>>>G_FRAC 之后还有 69 位。直接赋给 64 位就是**截断**：
    //   加权系数 > 1.0 或者后面 4 路求和超范围时，高位会被悄悄丢掉（听感是
    //   爆音 / 极性翻转）。这里先判高 32 位是不是全等于符号位，不是就钳位。
    // 4 路求和：71 位加法，只有最后饱和一次（原来 64 位直接加，超了会回绕）
    //   每项 69 位 + 2 位余量给 4 路和，比较只看高 8 位是不是全符号位 —— 比
    //   在乘法那一级塞 4 个 32 位比较器便宜得多（那个版本 PnR 直接掉到 57 MHz）。
    logic signed [70:0]  sum4;
    logic                sum_ok;
    logic signed [63:0]  sum_sat;

    assign sum4    = {{2{t1[68]}}, t1} + {{2{t2[68]}}, t2} +
                     {{2{t3[68]}}, t3} + {{2{t4[68]}}, t4};
    assign sum_ok  = (sum4[70:63] == {8{sum4[63]}});
    assign sum_sat = sum_ok ? sum4[63:0] :
                     (sum4[63] ? 64'sh8000_0000_0000_0000 : 64'sh7FFF_FFFF_FFFF_FFFF);

    // 回写数据：din_b + fb，65 位加法 + 饱和（组合，直接进 RAM 的 D）
    logic signed [64:0]  sm1, sm2, sm3, sm4;
    logic signed [63:0]  wd1, wd2, wd3, wd4;

    assign sm1 = {din_b[63], din_b} + {fb1[63], fb1};
    assign sm2 = {din_b[63], din_b} + {fb2[63], fb2};
    assign sm3 = {din_b[63], din_b} + {fb3[63], fb3};
    assign sm4 = {din_b[63], din_b} + {fb4[63], fb4};

    // wd 是**寄存器**（在 C 级算、D 级才写 RAM）：65 位加 + 饱和 mux 和

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clr_run <= 1'b1;      // 上电先当"清空中"；上层复位时也会给 clr
            clr_q   <= 1'b0;
            clr_cnt <= '0;
            p1 <= '0;  p2 <= '0;  p3 <= '0;  p4 <= '0;
            ad_a1 <= '0; ad_a2 <= '0; ad_a3 <= '0; ad_a4 <= '0;
            ad_b1 <= '0; ad_b2 <= '0; ad_b3 <= '0; ad_b4 <= '0;
            s1 <= '0;  s2 <= '0;  s3 <= '0;  s4 <= '0;
            din_a <= '0; din_b <= '0;
            fb1 <= '0; fb2 <= '0; fb3 <= '0; fb4 <= '0;
            t1 <= '0;  t2 <= '0;  t3 <= '0;  t4 <= '0;
            sum_q <= '0;
            wet   <= '0;
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            out_valid <= 1'b0;
        end else if (clr && !clr_q) begin
            clr_run <= 1'b1;      // 上电先当"清空中"；上层复位时也会给 clr
            clr_q   <= 1'b1;
            clr_cnt <= '0;
            p1 <= '0;  p2 <= '0;  p3 <= '0;  p4 <= '0;
            ad_a1 <= '0; ad_a2 <= '0; ad_a3 <= '0; ad_a4 <= '0;
            ad_b1 <= '0; ad_b2 <= '0; ad_b3 <= '0; ad_b4 <= '0;
            s1 <= '0;  s2 <= '0;  s3 <= '0;  s4 <= '0;
            din_a <= '0; din_b <= '0;
            fb1 <= '0; fb2 <= '0; fb3 <= '0; fb4 <= '0;
            t1 <= '0;  t2 <= '0;  t3 <= '0;  t4 <= '0;
            sum_q <= '0;
            wet   <= '0;
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            clr_q <= clr;
            // 清空请求：任何一拍都能启动/重启（不用等有样本进来）
            if (clr && !clr_q) begin
                clr_run <= 1'b1;
                clr_cnt <= '0;
            end

            v1        <= in_valid;
            v2        <= v1;
            v3        <= v2;
            out_valid <= v3;

            // A：发读地址、记地址和输入
            if (in_valid) begin
                ad_a1 <= p1;  ad_a2 <= p2;  ad_a3 <= p3;  ad_a4 <= p4;
                s1 <= c1[p1];
                s2 <= c2[p2];
                s3 <= c3[p3];
                s4 <= c4[p4];
                // 比较加宽一位再做：n=N（比如 2048）时 p+1 不会回绕成 0 而误判
                p1 <= ({1'b0, p1} + 1'b1 >= {1'b0, n1}) ? '0 : p1 + 1'b1;
                p2 <= ({1'b0, p2} + 1'b1 >= {1'b0, n2}) ? '0 : p2 + 1'b1;
                p3 <= ({1'b0, p3} + 1'b1 >= {1'b0, n3}) ? '0 : p3 + 1'b1;
                p4 <= ({1'b0, p4} + 1'b1 >= {1'b0, n4}) ? '0 : p4 + 1'b1;
                din_a <= in_data;
                if (clr_run) begin
                    if (clr_cnt == AW'(N-1)) clr_run <= 1'b0;
                    else                     clr_cnt <= clr_cnt + 1'b1;
                end
            end

            // B：两个乘法 + 地址/输入过一级
            if (v1) begin
                ad_b1 <= ad_a1;  ad_b2 <= ad_a2;  ad_b3 <= ad_a3;  ad_b4 <= ad_a4;
                din_b <= din_a;
                fb1 <= (s1_r * g1)  >>> G_FRAC;
                fb2 <= (s2_r * g2)  >>> G_FRAC;
                fb3 <= (s3_r * g3)  >>> G_FRAC;
                fb4 <= (s4_r * g4)  >>> G_FRAC;
                t1  <= (s1_r * w1c) >>> G_FRAC;
                t2  <= (s2_r * w2c) >>> G_FRAC;
                t3  <= (s3_r * w3c) >>> G_FRAC;
                t4  <= (s4_r * w4c) >>> G_FRAC;
            end

            // C：加 + 饱和（只打进寄存器）
            if (v2) begin
                wd1 <= (sm1[64] == sm1[63]) ? sm1[63:0] :
                       (sm1[64] ? 64'sh8000_0000_0000_0000 : 64'sh7FFF_FFFF_FFFF_FFFF);
                wd2 <= (sm2[64] == sm2[63]) ? sm2[63:0] :
                       (sm2[64] ? 64'sh8000_0000_0000_0000 : 64'sh7FFF_FFFF_FFFF_FFFF);
                wd3 <= (sm3[64] == sm3[63]) ? sm3[63:0] :
                       (sm3[64] ? 64'sh8000_0000_0000_0000 : 64'sh7FFF_FFFF_FFFF_FFFF);
                wd4 <= (sm4[64] == sm4[63]) ? sm4[63:0] :
                       (sm4[64] ? 64'sh8000_0000_0000_0000 : 64'sh7FFF_FFFF_FFFF_FFFF);
                sum_q <= sum_sat;
            end

            // D：写 RAM（数据已经是寄存器了）+ 输出
            if (v3) begin
                c1[ad_b1] <= wd1;
                c2[ad_b2] <= wd2;
                c3[ad_b3] <= wd3;
                c4[ad_b4] <= wd4;
                wet        <= sum_q;
            end
        end
    end

endmodule
