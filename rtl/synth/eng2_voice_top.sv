// -----------------------------------------------------------------------------
// eng2_voice_top.sv -- ENG2（sythsound modal_voice_top）的适配壳
//
// 复用 rtl/simsynth/modal_voice_top：多槽存储、单份状态、引擎只算、
// 结果流。这里只做 1:1 端口转接，方便 synth_top 用与 eng1_voice_top
// 对称的命名实例化；不改变 ENG2 内部任何行为。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module eng2_voice_top #(
    parameter int   N_MODES    = 48,
    parameter int   X_DEPTH    = 256,
    parameter int   SLOTS      = 16,
    parameter logic DEBUG_PORT = 1'b1
) (
    input  logic                                 clk,
    input  logic                                 rst_n,

    input  logic                                 co_we,
    input  logic [$clog2(SLOTS*N_MODES)-1:0]     co_addr,
    // 扁平 168-bit（7×24，按 coeff_t 的 packed 顺序），避免顶层 struct 端口
    input  logic [167:0]                         co_data,

    input  logic                                 x_we,
    input  logic [$clog2(SLOTS*X_DEPTH)-1:0]     x_addr,
    input  logic signed [modal_step_pkg::XW-1:0] x_data,

    input  logic                                 start,
    input  logic [$clog2(SLOTS+1)-1:0]           n_voices,
    input  logic [$clog2(X_DEPTH+1)-1:0]         n_samples,
    input  logic [$clog2(N_MODES+1)-1:0]         n_modes,
    input  logic [SLOTS-1:0]                     st_zero_mask,
    output logic                                 done,
    output logic                                 busy,

    input  logic                                 rd_en,
    input  logic [$clog2(X_DEPTH)-1:0]           rd_addr,
    output logic signed [modal_step_pkg::YW-1:0] rd_data,
    output logic                                 rd_valid,

    input  logic                                 ns_rd_en,
    input  logic [$clog2(SLOTS*N_MODES)-1:0]     ns_rd_addr,
    input  logic                                 ns_rd_sel,
    output logic signed [31:0]                   ns_rd_data,
    output logic                                 ns_rd_valid
);

    modal_step_pkg::coeff_t co;
    assign co = co_data;

    modal_voice_top #(
        .N_MODES(N_MODES),
        .X_DEPTH(X_DEPTH),
        .SLOTS(SLOTS),
        .DEBUG_PORT(DEBUG_PORT)
    ) u_voice_top (
        .clk(clk),
        .rst_n(rst_n),
        .co_we(co_we),
        .co_addr(co_addr),
        .co_data(co),
        .x_we(x_we),
        .x_addr(x_addr),
        .x_data(x_data),
        .start(start),
        .n_voices(n_voices),
        .n_samples(n_samples),
        .n_modes(n_modes),
        .st_zero_mask(st_zero_mask),
        .done(done),
        .busy(busy),
        .rd_en(rd_en),
        .rd_addr(rd_addr),
        .rd_data(rd_data),
        .rd_valid(rd_valid),
        .ns_rd_en(ns_rd_en),
        .ns_rd_addr(ns_rd_addr),
        .ns_rd_sel(ns_rd_sel),
        .ns_rd_data(ns_rd_data),
        .ns_rd_valid(ns_rd_valid)
    );

endmodule
