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
    logic [31:0]          co_wdata;
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
                co_wdata <= {2'b00, (6'd8 + lfsr[2:0]), lfsr[23:0]};
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
