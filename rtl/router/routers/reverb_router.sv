`timescale 1ns/1ps
// =============================================================================
// reverb_router -- 混响子路由：预设 -> 参数表 -> comb_reverb -> 干湿混合
//
// 和 body_router 一个套路：case (preset) 选参数，里面封装 parts/comb_reverb，
// 对外只收/发样本。
//
//   湿声：4 条梳状线（延迟 n_k、反馈 g_k、加权 w_k 都由预设给）
//   输出：y = (x_dry * gd + wet * gw) >>> G_FRAC   （Q4.27）
//
// 延迟对齐：comb_reverb 的湿声比输入晚 4 拍，干声也拖 4 拍；混合再占 2 拍
//           （乘一拍、加一拍），所以 out_valid 比 in_valid 晚 6 拍。
//
// REVERB_NONE = 直通：gc=0、wc=0、gd=1.0、gw=0 => y 就是延迟 6 拍的 x，逐位不变。
//
// 预设里的数字是先能响的占位值：
//   HALL     ：延迟按 44.1k 的 Freeverb 梳状长度换算到 48k（1214/1293/1390/1476），
//              反馈约 0.90（T60 ~ 2.5 s），湿声加权各 0.25
//   BATHROOM ：更短的延迟 + 稍小的反馈（T60 ~ 0.8 s）
// 要按听感/实测调，就改这张表。
// =============================================================================
module reverb_router #(
    parameter int N      = 2048,          // 最大延迟（和 comb_reverb 一致）
    parameter int G_FRAC = 27
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  router_pkg::reverb_preset    preset,

    input  logic                        in_valid,
    input  logic signed [63:0]          x,

    output logic                        out_valid,
    output logic signed [63:0]          y
);

    localparam int AW = $clog2(N);
    // Q4.27 常数（1.0 = 1<<27）
    localparam logic signed [31:0] Q_ONE   = 32'sd134217728;   // 1.00
    localparam logic signed [31:0] Q_0_93  = 32'sd124822487;   // 0.93
    localparam logic signed [31:0] Q_0_91  = 32'sd122138132;   // 0.91
    localparam logic signed [31:0] Q_0_90  = 32'sd120795955;   // 0.90
    localparam logic signed [31:0] Q_0_89  = 32'sd119453778;   // 0.89
    localparam logic signed [31:0] Q_0_82  = 32'sd110058537;   // 0.82
    localparam logic signed [31:0] Q_0_70  = 32'sd93952410;    // 0.70
    localparam logic signed [31:0] Q_0_50  = 32'sd67108864;    // 0.50
    localparam logic signed [31:0] Q_0_80  = 32'sd107374182;   // 0.80
    localparam logic signed [31:0] Q_0_40  = 32'sd53687091;    // 0.40
    localparam logic signed [31:0] Q_0_25  = 32'sd33554432;    // 0.25

    logic [3:0][AW:0]         len;   // 比指针宽一位：要能装下 N（clog2(N) 位装不下 N 本身）
    logic signed [3:0][31:0]  gc, wc;
    logic signed [31:0]       gd, gw;

    always_comb begin
        // 默认 = 直通（延迟给 1，别让指针比较落在 0 上）
        for (int k = 0; k < 4; k++) begin
            len[k] = (AW+1)'(1);
            gc[k]  = 32'sd0;
            wc[k]  = 32'sd0;
        end
        gd = Q_ONE;
        gw = 32'sd0;

        case (preset)
            router_pkg::REVERB_HALL: begin
                len[0] = (AW+1)'(1214); len[1] = (AW+1)'(1293);
                len[2] = (AW+1)'(1390); len[3] = (AW+1)'(1476);
                gc[0]  = Q_0_90;  gc[1]  = Q_0_90;
                gc[2]  = Q_0_90;  gc[3]  = Q_0_90;
                wc[0]  = Q_0_25;  wc[1]  = Q_0_25;
                wc[2]  = Q_0_25;  wc[3]  = Q_0_25;
                gd = Q_0_70;
                gw = Q_0_50;
            end
            router_pkg::REVERB_BATHROOM: begin
                len[0] = (AW+1)'(557);  len[1] = (AW+1)'(613);
                len[2] = (AW+1)'(691);  len[3] = (AW+1)'(743);
                gc[0]  = Q_0_82;  gc[1]  = Q_0_82;
                gc[2]  = Q_0_82;  gc[3]  = Q_0_82;
                wc[0]  = Q_0_25;  wc[1]  = Q_0_25;
                wc[2]  = Q_0_25;  wc[3]  = Q_0_25;
                gd = Q_0_80;
                gw = Q_0_40;
            end
            default: ;                    // REVERB_NONE / 非法值：直通
        endcase
    end

    // ------------------------------------------------------------------
    logic                    wet_valid;
    logic signed [63:0]      wet;

    // ------------------------------------------------------------------
    // 清空延迟线：复位 + 换预设时给 comb_reverb 一拍 clr（旧尾音不串到新预设）
    // ------------------------------------------------------------------
    router_pkg::reverb_preset preset_q;
    logic                      comb_clr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) preset_q <= router_pkg::REVERB_NONE;
        else        preset_q <= preset;
    end
    assign comb_clr = !rst_n || (preset != preset_q);
    comb_reverb #(.N(N), .G_FRAC(G_FRAC)) u_comb (
        .clk(clk), .rst_n(rst_n),
        .n1(len[0]), .n2(len[1]), .n3(len[2]), .n4(len[3]),
        .g1(gc[0]),  .g2(gc[1]),  .g3(gc[2]),  .g4(gc[3]),
        .w1c(wc[0]), .w2c(wc[1]), .w3c(wc[2]), .w4c(wc[3]),
        .clr(comb_clr),
        .in_valid(in_valid), .in_data(x),
        .out_valid(wet_valid), .wet(wet)
    );

    // ------------------------------------------------------------------
    // 干声拖 4 拍跟湿声对齐；混合再流水两拍（乘一拍、加一拍）
    //   vq[k] = in_valid 延迟 k+1 拍
    //   湿声在第 4 拍有效 -> vq[3] 那拍做两个乘法 -> vq[4] 那拍相加
    //   out_valid = vq[5]，比 in_valid 晚 6 拍
    // ------------------------------------------------------------------
    logic signed [63:0] xd [0:3];
    logic signed [68:0] dry_w, wet_w;      // 干/湿乘积移位后保留 69 位（先不饱和）
    logic [5:0]         vq;

    assign out_valid = vq[5];


    // ------------------------------------------------------------------
    // 干 + 湿：70 位加法 + 一次饱和（原来是 64 位直接加，超了回绕 -> 爆音）
    //   饱和判决放在**相加这一级**，乘法那一级只存 69 位不比较：在乘法后面
    //   塞 32 位比较器会把这条路拖到 57 MHz（教训）。
    // ------------------------------------------------------------------
    logic signed [69:0] y_sum;
    logic               ys_ok;
    assign y_sum = {{1{dry_w[68]}}, dry_w} + {{1{wet_w[68]}}, wet_w};
    assign ys_ok = (y_sum[69:63] == {7{y_sum[63]}});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 4; k++) xd[k] <= '0;
            dry_w <= '0;
            wet_w <= '0;
            y     <= '0;
            vq    <= '0;
        end else begin
            vq <= {vq[4:0], in_valid};

            xd[0] <= x;
            for (int k = 1; k < 4; k++) xd[k] <= xd[k-1];

            if (vq[3]) begin                // 湿声 + 干声同一拍，只寄存不饱和
                dry_w <= (xd[3] * gd) >>> G_FRAC;
                wet_w <= (wet  * gw) >>> G_FRAC;
            end
            // 相加这一级才饱和
            if (vq[4]) begin
                if (ys_ok) y <= y_sum[63:0];
                else y <= y_sum[69] ? 64'sh8000_0000_0000_0000 : 64'sh7FFF_FFFF_FFFF_FFFF;
            end
        end
    end

endmodule
