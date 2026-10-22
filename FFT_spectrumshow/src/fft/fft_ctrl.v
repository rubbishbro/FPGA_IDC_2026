// fft_ctrl.v - 时域窗口读取 + Hann 窗 + 1024 点 FFT 控制
//
// 工作流程：
//   1. 从 time_pingpong 读出 1024 个 24-bit 时域样本
//   2. 取高 16-bit 乘以 Hann 窗系数
//   3. 逐个送入 fft1024_iter
//   4. FFT 完成后输出 1024 个复数 bin（自然顺序，正频率 0..511）
module fft_ctrl #(
    // 一个 FFT 窗口的样本数，当前固定 1024
    parameter N_SAMPLES = 1024
) (
    // 33.333 MHz 可视化时钟与低有效复位
    input               clk_i,
    input               rst_ni,

    // ---------------- 时域窗口读接口 ----------------
    // tp_rd_valid_i：窗口里已经有一整块 1024 个样本
    // tp_rd_req_o  ：请求读下一个样本（单拍）
    // tp_rd_addr_o ：样本地址 0..1023
    // tp_rd_data_i ：24-bit 时域样本
    // tp_rd_done_o ：读完 1024 个样本时拉高一拍
    input               tp_rd_valid_i,
    output              tp_rd_req_o,
    output [9:0]        tp_rd_addr_o,
    input  [23:0]       tp_rd_data_i,
    output              tp_rd_done_o,

    // ---------------- FFT 输出接口（给 spectrum_map） ----------------
    // xk_re_o / xk_im_o：该 bin 的实部/虚部（16-bit）
    // bin_idx_o        ：bin 编号 0..1023（自然顺序）
    // opd_o            ：本拍 bin 有效（每个 bin 一拍）
    // eoud_o           ：所有 bin 输出完成（单拍）
    output [15:0]       xk_re_o,
    output [15:0]       xk_im_o,
    output [9:0]        bin_idx_o,
    output              opd_o,
    output              eoud_o
);

    localparam IDLE       = 3'd0;
    localparam START      = 3'd1;
    localparam WAIT_READY = 3'd2;
    localparam REQ        = 3'd3;
    localparam WAIT_DATA  = 3'd4;
    localparam NEXT       = 3'd5;
    localparam COLLECT    = 3'd6;

    reg [2:0] state;
    reg [$clog2(N_SAMPLES)-1:0] cnt;

    reg        start_fft;
    reg [15:0] xn_re;
    reg        xn_valid;
    reg        tp_rd_done_r;

    wire [25:0] fft_y_re;
    wire [25:0] fft_y_im;
    wire [9:0]  fft_y_idx;
    wire        fft_y_valid;
    wire        fft_ready;
    wire        fft_busy;
    wire        fft_done;

    // Hann window: 1024 x 16-bit Q1.15, same clock as the pixel/compute domain.
    logic [15:0] hann_rom [0:N_SAMPLES-1];
    initial $readmemh("hann1024.mem", hann_rom);
    logic [9:0]  hann_addr;
    logic [15:0] hann_coeff_r;
    always_ff @(posedge clk_i) hann_coeff_r <= hann_rom[hann_addr];

    logic signed [15:0] sample16;
    logic signed [31:0] mul_prod;
    logic signed [15:0] windowed;
    assign sample16 = $signed(tp_rd_data_i[23:8]);
    assign mul_prod = sample16 * $signed({1'b0, hann_coeff_r});
    assign windowed = (mul_prod + 32'sd16384) >>> 15;
    fft1024_iter u_fft (
        .clk     (clk_i),
        .rst_n   (rst_ni),
        .ce      (1'b1),
        .start   (start_fft),
        .x_re    (xn_re),
        .x_valid (xn_valid),
        .ready   (fft_ready),
        .y_re    (fft_y_re),
        .y_im    (fft_y_im),
        .y_idx   (fft_y_idx),
        .y_valid (fft_y_valid),
        .busy    (fft_busy),
        .done    (fft_done)
    );

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state        <= IDLE;
            cnt          <= 0;
            start_fft    <= 1'b0;
            xn_re        <= 16'd0;
            xn_valid     <= 1'b0;
            hann_addr    <= 10'd0;
            tp_rd_done_r <= 1'b0;
        end
        else begin
            start_fft    <= 1'b0;
            xn_valid     <= 1'b0;
            tp_rd_done_r <= 1'b0;

            case (state)
                IDLE: begin
                    if (tp_rd_valid_i)
                        state <= START;
                end

                START: begin
                    start_fft <= 1'b1;
                    cnt       <= 0;
                    state     <= WAIT_READY;
                end

                WAIT_READY: begin
                    if (fft_ready)
                        state <= REQ;
                end

                REQ: begin
                    hann_addr <= cnt;
                    state     <= WAIT_DATA;
                end

                WAIT_DATA: begin
                    if (fft_ready) begin
                        xn_re    <= windowed;
                        xn_valid <= 1'b1;
                        if (cnt == N_SAMPLES-1)
                            tp_rd_done_r <= 1'b1;
                        state <= NEXT;
                    end
                end

                NEXT: begin
                    if (cnt == N_SAMPLES-1) begin
                        cnt   <= 0;
                        state <= COLLECT;
                    end
                    else begin
                        cnt   <= cnt + 1'b1;
                        state <= REQ;
                    end
                end

                COLLECT: begin
                    if (fft_done)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign tp_rd_req_o  = (state == REQ);
    assign tp_rd_addr_o = cnt;
    assign tp_rd_done_o = tp_rd_done_r;

    // 26-bit internal -> 16-bit display scale (drop 10 LSBs).
    assign xk_re_o   = fft_y_re[25:10];
    assign xk_im_o   = fft_y_im[25:10];
    assign bin_idx_o = fft_y_idx;
    assign opd_o     = fft_y_valid;
    assign eoud_o    = fft_done;

endmodule
