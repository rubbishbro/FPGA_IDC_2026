// -----------------------------------------------------------------------------
// top_seq.sv -- 方案 A 的顶层：modal_bank_seq + 它必须配套的**外部系数 ROM**
//
// 端口与 top_ram.sv 完全一致（公平对比的前提）：
//   co_we/co_addr/co_sel/co_wdata : 窄口装载系数（7 次 32 位写装一个模态，见 coeff_loader）
//   x_valid/x_data                : 每个采样给一个激励值
//   y_valid/y_data                : 每个采样输出 Σ wo·q
//
// 总 I/O ≈ 141 个（窄口之前是约 340 个，超过器件 312，PnR 跑不动）。
// 每采样在 bank 内需要 9N+1 拍；N=48 时 433 拍 < 2083 拍预算。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module top_seq #(
    parameter int N_MODES = 32
) (
    input  logic                                 clk,
    input  logic                                 rst_n,

    // 窄口系数装载
    input  logic                                 co_we,
    input  logic [$clog2(N_MODES)-1:0]           co_addr,
    input  logic [2:0]                           co_sel,
    input  logic [31:0]                          co_wdata,

    input  logic                                 x_valid,
    input  logic signed [modal_step_pkg::XW-1:0] x_data,
    output logic                                 y_valid,
    output logic signed [modal_step_pkg::YW-1:0] y_data
);

    import modal_step_pkg::*;

    localparam int IW = $clog2(N_MODES);

    // ---- 窄口 -> coeff_t --------------------------------------------------
    logic          ld_we;
    logic [IW-1:0] ld_addr;
    coeff_t        ld_data;

    coeff_loader #(.N_MODES(N_MODES)) u_ld (
        .clk(clk), .rst_n(rst_n),
        .we(co_we), .addr(co_addr), .sel(co_sel), .wdata(co_wdata),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data)
    );

    // ---- 系数 ROM（A 方案必须外挂的部分）---------------------------------
    (* syn_ramstyle = "block_ram" *)
    coeff_t co_rom [0:N_MODES-1];

    logic          co_re;
    logic [IW-1:0] co_raddr;
    coeff_t        co_rdata;

    always_ff @(posedge clk) begin
        if (ld_we) co_rom[ld_addr] <= ld_data;
        if (co_re) co_rdata <= co_rom[co_raddr];
    end
    assign co_re = 1'b1;          // ROM 每拍跟着 c_addr 读（1 拍延迟正是 bank 需要的）

    // ---- bank ------------------------------------------------------------
    logic                 bank_start;
    logic                 bank_busy;
    logic                 bank_done;
    logic signed [YW-1:0] bank_y;

    modal_bank_seq #(.N_MODES(N_MODES)) u_bank (
        .clk(clk), .rst_n(rst_n),
        .start(bank_start),
        .n_modes(N_MODES[$clog2(N_MODES+1)-1:0]),
        .x_in(x_data),
        .st_we(1'b0), .st_addr('0), .st_q('0), .st_v('0),
        .rd_en(1'b0), .rd_q(), .rd_v(), .rd_valid(),
        .c_addr(co_raddr), .c_data(co_rdata),
        .y_sum(bank_y), .frame_done(bank_done), .busy(bank_busy)
    );

    // ---- 逐采样控制 ------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_start <= 1'b0;
            y_valid    <= 1'b0;
            y_data     <= '0;
        end else begin
            bank_start <= 1'b0;
            y_valid    <= 1'b0;
            if (x_valid && !bank_busy) bank_start <= 1'b1;
            if (bank_done) begin
                y_data  <= bank_y;
                y_valid <= 1'b1;
            end
        end
    end

endmodule
