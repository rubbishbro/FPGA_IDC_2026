// -----------------------------------------------------------------------------
// waterfall_store.sv -- 瀑布图历史：64 帧 × 128 根柱子 × 10 bit
//
// 每帧频谱保存为一行历史：
//   wr_row   ：正在写入的历史行号
//   base_row ：最近一帧已经写完整的行号（给显示用）
// 显示读取 base_row, base_row-1, ... 即“最新在上、越往下越旧”。
// -----------------------------------------------------------------------------
module waterfall_store #(
    parameter int ROWS = 64,    // 历史帧数
    parameter int COLS = 128,   // 每帧柱子数
    parameter int W    = 10     // 柱高位宽
)(
    // 33.333 MHz 显示时钟与低有效复位
    input  logic             clk,
    input  logic             rst_n,

    // ---------------- 写侧：当前帧频谱 ----------------
    // wr_en         ：写一个柱高
    // wr_col        ：柱子编号 0..127
    // wr_data       ：柱高 0..1023
    // wr_frame_done ：当前帧 128 根柱子写完，切换到下一历史行
    input  logic             wr_en,
    input  logic [6:0]       wr_col,
    input  logic [W-1:0]     wr_data,
    input  logic             wr_frame_done,

    // ---------------- 读侧：瀑布显示 ----------------
    // rd_row  ：历史行号（0..63）
    // rd_col  ：柱子编号（0..127）
    // rd_data ：该历史单元的柱高
    // base_row：最新完整历史行号
    input  logic [5:0]       rd_row,
    input  logic [6:0]       rd_col,
    output logic [W-1:0]     rd_data,
    output logic [5:0]       base_row
);

    logic [W-1:0] mem [0:ROWS*COLS-1];
    initial begin
        $readmemh("waterfall_zero.mem", mem);
    end
    logic [5:0] wr_row;
    logic [5:0] base_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row   <= 6'd0;
            base_r   <= 6'd0;
            rd_data  <= '0;
        end
        else begin
            if (wr_en)
                mem[{wr_row, wr_col}] <= wr_data;

            if (wr_frame_done) begin
                base_r <= wr_row;
                wr_row <= wr_row + 1'b1;
            end

            rd_data <= mem[{rd_row, rd_col}];
        end
    end

    assign base_row = base_r;

endmodule
