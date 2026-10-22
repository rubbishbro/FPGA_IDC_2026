// freq_pingpong.v - Frequency-domain ping-pong buffer (self-contained, single clock)
// 2026-09-29 自包含重构：wr_sel 内部化，单时钟
//
//  写侧（spectrum_map）写一块，读侧（显示）读另一块。
//  写地址到 N_BARS-1 时自动翻块 + 切读（自包含，无需外部 wr_sel/frame_done）。
//
//  设计决定（重要，别忘）：
//  - 单时钟（clk_i）：当前 FFT/显示都跑 pix_clk，写读同域。
//  - 自包含翻转：wr_addr 到 N_BARS-1 判断写满，rd_sel 切到刚写完的块（wr_sel 旧值）。
//  - 写地址必须 0..N_BARS-1 连续递增（spectrum_map 需保证，见 docs/RTL编码规范.md 9.1）
//  - 越界地址丢弃（边界保护，本模块自己该做的）
module freq_pingpong #(
    parameter N_BARS = 128,   // 柱数
    parameter WIDTH  = 10     // 柱高位宽
) (
    input               clk_i,
    input               rst_ni,

    // ---- 写侧（spectrum_map）----
    input  [$clog2(N_BARS)-1:0] wr_addr_i,   // 0..N_BARS-1 连续递增
    input  [WIDTH-1:0]   wr_bar_i,     // bar 高度
    input  [WIDTH-1:0]   wr_ov_i,      // 超调目标
    input                wr_we_i,

    // ---- 读侧（显示）----
    input  [$clog2(N_BARS)-1:0] rd_addr_i,
    output [WIDTH-1:0]   rd_bar_o,
    output [WIDTH-1:0]   rd_ov_o
);

    // 双块 RAM
    reg [WIDTH-1:0] bar_ram [0:1][0:N_BARS-1];
    reg [WIDTH-1:0] ov_ram  [0:1][0:N_BARS-1];

    // 写块/读块指针（内部）
    reg wr_sel, rd_sel;

    // ---- 写 + 自包含翻转 ----
    // 写到 N_BARS-1 那拍：rd_sel 切到刚写完的块（wr_sel 旧值），wr_sel 翻下一块
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            wr_sel <= 1'b0;
            rd_sel <= 1'b0;
        end
        else if (wr_we_i && (wr_addr_i < N_BARS)) begin
            bar_ram[wr_sel][wr_addr_i] <= wr_bar_i;
            ov_ram [wr_sel][wr_addr_i] <= wr_ov_i;
            if (wr_addr_i == N_BARS-1) begin
                rd_sel <= wr_sel;    // 读切到刚写完的块
                wr_sel <= ~wr_sel;   // 翻写块
            end
        end
    end

    // ---- 读（寄存器读）----
    reg [WIDTH-1:0] rd_bar_r, rd_ov_r;
    always @(posedge clk_i) begin
        rd_bar_r <= bar_ram[rd_sel][rd_addr_i];
        rd_ov_r  <= ov_ram [rd_sel][rd_addr_i];
    end

    assign rd_bar_o = rd_bar_r;
    assign rd_ov_o  = rd_ov_r;

endmodule