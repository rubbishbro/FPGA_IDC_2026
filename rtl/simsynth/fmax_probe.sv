// -----------------------------------------------------------------------------
// fmax_probe.sv -- 只为拿真实 Fmax 的探针顶层（无外部激励接口，只有 clk/rst_n/led）
//
// 为什么需要它：两个方案的真实顶层有 ~141 个 I/O，做综合可以，但 PnR 需要有引脚约束；
// 而 Fmax 只取决于内部数据通路。本探针把激励与系数全部由内部 LFSR 产生（写进 RAM，
// 所以综合器不会把系数当常数折叠），跑起来后把 y 反馈到一个累加器并驱动一个 LED 引脚
// 防止逻辑被优化掉。端口只有 3 个，PnR 无引脚压力。
//
// 两个 wrapper 分别测量方案 A（USE_RAM=0）和方案 B（USE_RAM=1）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module fmax_probe #(
    parameter int N_MODES = 48,
    parameter bit USE_RAM = 1'b1
) (
    input  logic clk,
    input  logic rst_n,
    output logic led
);

    import modal_step_pkg::*;

    localparam int IW = $clog2(N_MODES);

    logic                 co_we;
    logic [IW-1:0]        co_addr;
    logic [2:0]           co_sel;
    logic [35:0]          co_wdata;
    logic                 x_valid;
    logic signed [XW-1:0] x_data;
    logic                 y_valid;
    logic signed [YW-1:0] y_data;

    generate
        if (USE_RAM) begin : g_ram
            top_ram #(.N_MODES(N_MODES)) u_dut (
                .clk(clk), .rst_n(rst_n),
                .co_we(co_we), .co_addr(co_addr), .co_sel(co_sel), .co_wdata(co_wdata),
                .x_valid(x_valid), .x_data(x_data),
                .y_valid(y_valid), .y_data(y_data)
            );
        end else begin : g_seq
            top_seq #(.N_MODES(N_MODES)) u_dut (
                .clk(clk), .rst_n(rst_n),
                .co_we(co_we), .co_addr(co_addr), .co_sel(co_sel), .co_wdata(co_wdata),
                .x_valid(x_valid), .x_data(x_data),
                .y_valid(y_valid), .y_data(y_data)
            );
        end
    endgenerate

    // ---- 内部激励 --------------------------------------------------------
    logic [31:0] lfsr;
    logic        init_done;
    logic [63:0] acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr      <= 32'h1234_5678;
            co_we     <= 1'b0;
            co_addr   <= '0;
            co_sel    <= '0;
            co_wdata  <= '0;
            x_valid   <= 1'b0;
            x_data    <= '0;
            init_done <= 1'b0;
            acc       <= '0;
            led       <= 1'b0;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            led  <= ^acc;

            if (!init_done) begin
                // 逐字段写系数：尾数取 LFSR、移位取 8..15，保证不越界也不退化
                co_we    <= 1'b1;
                co_wdata <= {lfsr[3:0], lfsr[31:0]};   // 36 位尾数，随机即可（只测时序）
                if (co_sel == 3'd6) begin
                    co_sel <= '0;
                    if (co_addr == N_MODES[IW-1:0] - 1'b1) begin
                        co_we     <= 1'b0;
                        init_done <= 1'b1;      // 下一拍开始跑采样
                    end else begin
                        co_addr <= co_addr + 1'b1;
                    end
                end else begin
                    co_sel <= co_sel + 1'b1;
                end
            end else begin
                // 持续喂激励（顶层自己节流）；结果反馈进 acc
                x_valid <= 1'b1;
                x_data  <= lfsr;
                if (y_valid) acc <= acc ^ y_data;
            end
        end
    end

endmodule


// ---- 两个 wrapper：分别测 A / B ----------------------------------------
module fmax_seq (
    input  logic clk,
    input  logic rst_n,
    output logic led
);
    fmax_probe #(.USE_RAM(1'b0)) u_probe (.clk(clk), .rst_n(rst_n), .led(led));
endmodule

module fmax_ram (
    input  logic clk,
    input  logic rst_n,
    output logic led
);
    fmax_probe #(.USE_RAM(1'b1)) u_probe (.clk(clk), .rst_n(rst_n), .led(led));
endmodule



// ---- 声部层（引擎 + 双份 bank）的时序探针 ------------------------------
// 与上面两个探针同口径：只有 clk/rst_n/led，装载数据与作业调度全部由内部 LFSR/计数器
// 产生（系数写进 RAM，综合器不会把它们当常数折叠），结果异或进累加器驱动 LED。
// 配置用"生产尺寸"：N_MODES=48、X_DEPTH=256、VOICES=8（每份 bank 8 声部，A/B 两份），
// DEBUG_PORT=0（生产配置）。
module fmax_e7 #(
    parameter int N_MODES = 48,
    parameter int X_DEPTH = 64          // 块处理 64 采样（x/y 阵列缩小 4 倍，便于布线）
) (
    input  logic clk,
    input  logic rst_n,
    output logic led
);

    import modal_step_pkg::*;

    localparam int VOICES = 8;
    localparam int NCO    = VOICES * N_MODES;          // 每份 bank 的系数/状态条数
    localparam int NX     = VOICES * X_DEPTH;          // 每份 bank 的激励/结果条数
    localparam int TB     = $clog2(2*NCO);
    localparam int XB     = $clog2(2*NX);

    logic                          co_we;
    logic [TB-1:0]                 co_addr;
    coeff_t                        co_data;
    logic                          st_we;
    logic [TB-1:0]                 st_addr;
    logic signed [QW-1:0]          st_q;
    logic signed [VW-1:0]          st_v;
    logic                          x_we;
    logic [XB-1:0]                 x_addr;
    logic signed [XW-1:0]          x_data;
    logic                          start;
    logic [$clog2(VOICES+1)-1:0]   n_voices;
    logic [$clog2(X_DEPTH+1)-1:0]  n_samples;
    logic [$clog2(N_MODES+1)-1:0]  n_modes;
    logic                          swap_en;
    logic                          run_bank;
    logic                          done;
    logic                          busy;
    logic                          rd_en;
    logic [XB-1:0]                 rd_addr;
    logic signed [YW-1:0]          rd_data;
    logic                          rd_valid;

    modal_voice_top #(
        .N_MODES(N_MODES), .X_DEPTH(X_DEPTH), .VOICES(VOICES), .DEBUG_PORT(1'b0)
    ) u_vt (
        .clk(clk), .rst_n(rst_n),
        .co_we(co_we), .co_addr(co_addr), .co_data(co_data),
        .st_we(st_we), .st_addr(st_addr), .st_q(st_q), .st_v(st_v),
        .x_we(x_we), .x_addr(x_addr), .x_data(x_data),
        .start(start), .n_voices(n_voices), .n_samples(n_samples), .n_modes(n_modes),
        .swap_en(swap_en), .run_bank(run_bank), .done(done), .busy(busy),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .st_rd_en(1'b0), .st_rd_addr('0), .st_rd_sel(1'b0),
        .st_rd_data(), .st_rd_valid()
    );

    localparam int NCO_LAST = NCO - 1;
    localparam int NX_LAST  = NX - 1;

    logic [31:0]   lfsr;
    logic [TB-1:0] ci;
    logic [XB-1:0] xi;
    logic [1:0]    ph;            // 0=装系数 1=装状态 2=装激励 3=循环跑
    logic [63:0]   acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr      <= 32'h1234_5678;
            ci        <= '0;
            xi        <= '0;
            ph        <= 2'd0;
            co_we     <= 1'b0;
            st_we     <= 1'b0;
            x_we      <= 1'b0;
            co_addr   <= '0;
            st_addr   <= '0;
            x_addr    <= '0;
            co_data   <= '0;
            st_q      <= '0;
            st_v      <= '0;
            x_data    <= '0;
            start     <= 1'b0;
            swap_en   <= 1'b0;
            n_voices  <= VOICES[$clog2(VOICES+1)-1:0];
            n_samples <= '0;
            n_modes   <= '0;
            rd_en     <= 1'b0;
            rd_addr   <= '0;
            acc       <= '0;
            led       <= 1'b0;
        end else begin
            lfsr  <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            led   <= ^acc;
            start <= 1'b0;

            case (ph)
                2'd0: begin                                   // 系数（整条记录一次写）
                    co_we   <= 1'b1;
                    co_addr <= ci;
                    // 7 个字段必须是**互不相同**的表达式：写成 {7{lfsr}} 会被综合器当成公共子表达式，
                    // 7 个乘法合并成 3 个（实测 DSP 从 14 个 MULT27X36 掉到 6 个，Fmax 也就不可信了）。
                    co_data.a11 <= lfsr;
                    co_data.a12 <= {lfsr[4:0],  lfsr[31:5]};
                    co_data.a21 <= {lfsr[8:0],  lfsr[31:9]};
                    co_data.a22 <= {lfsr[12:0], lfsr[31:13]};
                    co_data.gq  <= {lfsr[16:0], lfsr[31:17]};
                    co_data.gv  <= {lfsr[20:0], lfsr[31:21]};
                    co_data.wo  <= {lfsr[24:0], lfsr[31:25]};
                    if (ci == TB'(NCO_LAST)) begin
                        co_we <= 1'b0;
                        ci    <= '0;
                        ph    <= 2'd1;
                    end else begin
                        ci <= ci + 1'b1;
                    end
                end

                2'd1: begin                                   // 状态初值
                    st_we   <= 1'b1;
                    st_addr <= ci;
                    st_q    <= lfsr;
                    st_v    <= {lfsr[15:0], lfsr[31:16]};
                    if (ci == TB'(NCO_LAST)) begin
                        st_we <= 1'b0;
                        ci    <= '0;
                        ph    <= 2'd2;
                    end else begin
                        ci <= ci + 1'b1;
                    end
                end

                2'd2: begin                                   // 激励
                    x_we   <= 1'b1;
                    x_addr <= xi;
                    x_data <= lfsr;
                    if (xi == XB'(NX_LAST)) begin
                        x_we <= 1'b0;
                        xi   <= '0;
                        ph   <= 2'd3;
                    end else begin
                        xi <= xi + 1'b1;
                    end
                end

                default: begin                                // 循环跑作业（8 声部 x 2 帧）
                    if (!busy) begin
                        start     <= 1'b1;
                        swap_en   <= ~swap_en;
                        n_voices  <= VOICES[$clog2(VOICES+1)-1:0];
                        n_modes   <= N_MODES[$clog2(N_MODES+1)-1:0];
                        n_samples <= 2'd2;
                        rd_en     <= 1'b1;
                        rd_addr   <= rd_addr + 1'b1;
                    end
                    if (rd_valid) acc <= acc ^ rd_data;
                end
            endcase
        end
    end

endmodule
