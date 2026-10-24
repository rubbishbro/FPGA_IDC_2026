// -----------------------------------------------------------------------------
// lcd_waterfall.v -- 瀑布图渲染：64 帧历史，128 根柱子
//
// 屏幕上一行像素对应一条历史频谱；最新 60 行显示在 480px 高度内
// （每行 8px）。柱高映射到蓝→红的简单配色。
//
// 本模块只负责生成“读地址 + 颜色”，历史数据在 waterfall_store 里。
// -----------------------------------------------------------------------------
module lcd_waterfall (
    // 33.333 MHz 像素时钟与低有效复位
    input  logic        clk,
    input  logic        rst_n,

    // lcd_valid：当前像素在有效显示区
    // pix_x/pix_y：当前像素坐标
    input  logic        lcd_valid,
    input  logic [9:0]  pix_x,
    input  logic [9:0]  pix_y,
    input  logic        theme,

    // wf_base_row：最新历史行号（来自 waterfall_store）
    // wf_rd_data ：当前读地址对应的历史柱高
    input  logic [5:0]  wf_base_row,
    input  logic [9:0]  wf_rd_data,

    // ---------------- 历史 RAM 读地址 ----------------
    // wf_rd_row：要读的历史行
    // wf_rd_col：要读的柱子编号
    output logic [5:0]  wf_rd_row,
    output logic [6:0]  wf_rd_col,

    // ---------------- 像素输出 ----------------
    // wf_hit：当前像素属于瀑布图
    // wf_r/g/b：RGB 颜色
    output logic        wf_hit,
    output logic [5:0]  wf_r,
    output logic [5:0]  wf_g,
    output logic [5:0]  wf_b
);

    // Pixel pipeline: pxx/pxy align with the registered waterfall RAM read.
    reg [9:0] pxx, pxy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pxx <= 10'd0; pxy <= 10'd0;
        end
        else begin
            pxx <= pix_x; pxy <= pix_y;
        end
    end

    // Bar index: floor(pix_x/6), advanced every 6 pixels.
    reg [2:0] xmod;
    reg [6:0] bar_idx;
    wire [6:0] bar_idx_next = (pix_x == 10'd0) ? 7'd0 :
                              (xmod == 3'd5) ? ((bar_idx < 7'd127) ? bar_idx + 1'b1 : bar_idx) :
                              bar_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xmod    <= 3'd0;
            bar_idx <= 7'd0;
        end
        else if (pix_x == 10'd0) begin
            xmod    <= 3'd0;
            bar_idx <= 7'd0;
        end
        else if (xmod == 3'd5) begin
            xmod    <= 3'd0;
            bar_idx <= bar_idx_next;
        end
        else begin
            xmod <= xmod + 1'b1;
        end
    end

    // History row: 60 visible rows, 8 px each; newest at the top.
    wire [5:0] row_off  = pix_y[8:3];          // 0..59 for active area
    wire [5:0] hist_row = wf_base_row - row_off;

    assign wf_rd_col = bar_idx_next;
    assign wf_rd_row = hist_row;

    wire [9:0] h = wf_rd_data;

    always_comb begin
        if (theme) begin
            wf_r = h[9:4];
            wf_g = h[9:4];
            wf_b = h[9:4];
        end
        else begin
            wf_r = {h[9:5], 1'b0};
            wf_g = h[8:4];
            wf_b = 6'h3F - {h[9:5], 1'b0};
        end
    end

    assign wf_hit = lcd_valid && (pxx < 10'd768) && (pxy < 10'd480) && (pxy < 10'd480);

endmodule
