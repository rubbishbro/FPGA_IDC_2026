// fft_ctrl.v - FFT control: read time_pingpong -> feed FFT (registered) -> collect output
// 2026-09-29 架构重构 v2
//
//  握手（IPUG503 + 旧版验证过的逻辑）：
//  - IDLE: 看到时域乒乓有满块（tp_rd_valid_i）→ 拉 start
//  - start 后 IP 拉 sod → 下个沿开始收（ipd 高）
//  - ipd 高时逐拍：读乒乓 -> xn_re(寄存) -> 喂 FFT；读地址递增
//  - eod 拉高 -> 输入完；等 busy 结束
//  - opd 高时收 xk_re/im 给 spectrum_map；eoud 结束回 IDLE
//
//  读喂合一：不存 1024 缓冲，边读乒乓边喂 FFT，ipd 驱动，一拍对齐。
//  xn_re 寄存器化：从乒乓读出的数据寄存一拍再喂，消除组合路径（P1）。
module fft_ctrl #(
    parameter N_SAMPLES = 1024
) (
    input               clk_i,        // pix_clk
    input               rst_ni,

    // 时域乒乓读口
    input               tp_rd_valid_i,  // 有满块可读
    output              tp_rd_req_o,    // 请求读一拍
    output [$clog2(N_SAMPLES)-1:0] tp_rd_addr_o,
    input  [15:0]       tp_rd_data_i,
    output              tp_rd_done_o,   // 读完一块

    // FFT 输出（给 spectrum_map）
    output [15:0]       xk_re_o,
    output [15:0]       xk_im_o,
    output [9:0]        bin_idx_o,
    output              opd_o,          // 输出有效（每 bin 一拍）
    output              eoud_o          // 输出完
);

    // ---- FFT IP 信号 ----
    wire [9:0]  fft_idx;
    wire [15:0] fft_xk_re, fft_xk_im;
    wire        fft_sod, fft_ipd, fft_eod;
    wire        fft_busy, fft_soud, fft_opd, fft_eoud;
    reg  [15:0] xn_re;
    reg         start_fft;

    // ---- 状态 ----
    localparam IDLE = 2'd0, START = 2'd1, FEED = 2'd2, COLLECT = 2'd3;
    reg [1:0] state;
    reg [$clog2(N_SAMPLES)-1:0] cnt;   // 喂数计数

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= IDLE;
            cnt <= 0;
            start_fft <= 1'b0;
        end
        else begin
            start_fft <= 1'b0;
            case (state)
                IDLE: begin
                    // 有满块且 FFT 空闲 → 启动
                    if (tp_rd_valid_i && !fft_busy) begin
                        state <= START;
                    end
                end

                START: begin
                    start_fft <= 1'b1;      // 拉 start（IP 空闲时采样）
                    state <= FEED;
                    cnt <= 0;
                end

                FEED: begin
                    // ipd 高：读乒乓 + 喂 FFT，一拍一拍
                    if (fft_ipd) begin
                        if (cnt == N_SAMPLES-1) begin
                            state <= COLLECT;   // 喂完
                        end
                        cnt <= cnt + 1'b1;
                    end
                end

                COLLECT: begin
                    // 等 FFT 算完输出（opd 期间 spectrum_map 收）
                    if (fft_eoud) state <= IDLE;
                end
            endcase
        end
    end

    // ---- 读乒乓：ipd 高时读（读喂合一）----
    assign tp_rd_req_o  = (state == FEED) && fft_ipd;
    assign tp_rd_addr_o = cnt;
    assign tp_rd_done_o = (state == FEED) && fft_ipd && (cnt == N_SAMPLES-1);

    // ---- xn_re 寄存器化 ----
    reg [15:0] tdata_r;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tdata_r <= 16'd0;
            xn_re   <= 16'd0;
        end
        else begin
            tdata_r <= tp_rd_data_i;        // 寄存乒乓读出的数据
            if ((state == FEED) && fft_ipd)
                xn_re <= tdata_r;           // 喂 FFT（用寄存值）
            else
                xn_re <= 16'd0;
        end
    end

    // ---- FFT IP ----
    FFT_Top u_fft (
        .idx    ( fft_idx     ),
        .xk_re  ( fft_xk_re   ),
        .xk_im  ( fft_xk_im   ),
        .sod    ( fft_sod     ),
        .ipd    ( fft_ipd     ),
        .eod    ( fft_eod     ),
        .busy   ( fft_busy    ),
        .soud   ( fft_soud    ),
        .opd    ( fft_opd     ),
        .eoud   ( fft_eoud    ),
        .xn_re  ( xn_re       ),
        .xn_im  ( 16'd0       ),
        .start  ( start_fft   ),
        .clk    ( clk_i       ),
        .rst    ( ~rst_ni     )
    );

    // ---- 输出 ----
    assign xk_re_o   = fft_xk_re;
    assign xk_im_o   = fft_xk_im;
    assign bin_idx_o = fft_idx;
    assign opd_o     = fft_opd;
    assign eoud_o    = fft_eoud;

endmodule