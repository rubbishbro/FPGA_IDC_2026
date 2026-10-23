// -----------------------------------------------------------------------------
// display_frame_buffer.sv -- 当前帧柱高/超调的集中存储
//
// 128 根柱子 × 24 bit，双 bank：
//   写侧：spectrum_map 一帧算完后写入一个 bank；
//   读侧：LCD 像素扫描读取另一个已经写完的 bank；
//   读 bank 只在像素帧边界（rd_frame_pulse）切换，避免撕裂。
//
// 当前 LCD demo 写/读都是 33.333 MHz；
// 接主引擎后也可以做成 100 MHz 写 / 33.3 MHz 读，本模块本身支持双时钟。
//
// 数据格式：{4'b0, 超调[9:0], 柱高[9:0]}
// -----------------------------------------------------------------------------
module display_frame_buffer (
    // ---------------- 写侧：频谱计算域 ----------------
    // wr_en         ：写柱高有效
    // wr_addr       ：柱子编号 0..127
    // wr_data       ：{超调, 柱高}
    // wr_frame_done ：一帧 128 根柱子写完（单拍）
    input  logic        wr_clk,
    input  logic        wr_rst_n,
    input  logic        wr_en,
    input  logic [6:0]  wr_addr,
    input  logic [23:0] wr_data,
    input  logic        wr_frame_done,

    // ---------------- 读侧：LCD 像素域 ----------------
    // rd_addr        ：当前像素要读的柱子编号 0..127
    // rd_data        ：{超调, 柱高}
    // rd_frame_pulse ：像素帧边界，用于切换 bank
    input  logic        rd_clk,
    input  logic        rd_rst_n,
    input  logic [6:0]  rd_addr,
    output logic [23:0] rd_data,
    input  logic        rd_frame_pulse
);

    localparam int NBARS = 128;

    logic [23:0] mem [0:2*NBARS-1];

    logic wr_bank;
    logic frame_toggle;
    logic rd_bank;
    logic [1:0] ft_sync;
    logic [1:0] wb_sync;
    logic ft_seen;
    logic [23:0] rd_data_r;

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bank      <= 1'b0;
            frame_toggle <= 1'b0;
        end
        else begin
            if (wr_en)
                mem[{wr_bank, wr_addr}] <= wr_data;

            if (wr_frame_done) begin
                wr_bank      <= ~wr_bank;
                frame_toggle <= ~frame_toggle;
            end
        end
    end

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            ft_sync   <= 2'b00;
            wb_sync   <= 2'b00;
            ft_seen   <= 1'b0;
            rd_bank   <= 1'b0;
            rd_data_r <= 24'd0;
        end
        else begin
            ft_sync <= {ft_sync[0], frame_toggle};
            wb_sync <= {wb_sync[0], wr_bank};

            if (rd_frame_pulse && (ft_sync[1] != ft_seen)) begin
                ft_seen <= ft_sync[1];
                rd_bank <= ~wb_sync[1];   // bank just completed
            end

            rd_data_r <= mem[{rd_bank, rd_addr}];
        end
    end

    assign rd_data = rd_data_r;

endmodule
