// -----------------------------------------------------------------------------
// b_a1_ram_engine.sv -- 把旧 b_a1_engine 适配到 9×32 modal_ram
//
// 旧引擎读 72-bit {G,a2,a1}，写 22-bit a1 shadow；
// 新 RAM 读 9×32 记录，写单字段（field 1 = a1，32-bit sign-extended）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module b_a1_ram_engine #(
    parameter int NUM_SLOTS  = 16,
    parameter int N_MODES    = 48,
    parameter int COEFF_DEPTH= 5483,
    parameter int THETA_DEPTH= COEFF_DEPTH,
    parameter THETA_FILE = "",
    parameter int REC_W      = 288,
    parameter int VW         = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW         = (N_MODES < 2) ? 1 : $clog2(N_MODES)
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [NUM_SLOTS*2-1:0]  class_vec,
    input  logic [NUM_SLOTS*16-1:0] theta_base_vec,
    input  logic [15:0]             ratio,
    input  logic                    enable,
    input  logic                    idle,

    output logic                    aux_re,
    output logic [VW-1:0]           aux_voice,
    output logic [MW-1:0]           aux_mode,
    input  logic [REC_W-1:0]        aux_data,
    input  logic                    aux_valid,

    output logic                    co_we,
    output logic [VW-1:0]           co_voice,
    output logic [MW-1:0]           co_mode,
    output logic [3:0]              co_field,
    output logic [31:0]             co_wdata,

    output logic                    active,
    output logic                    done
);

    logic                    rd_en;
    logic [VW-1:0]           rd_voice;
    logic [MW-1:0]           rd_mode;
    logic [71:0]             rd_data;
    logic                    a1_we;
    logic [VW-1:0]           a1_voice;
    logic [MW-1:0]           a1_mode;
    logic [21:0]             a1_data;

    // 9×32 -> 72-bit {G(0),a2,a1}
    assign rd_data = {26'd0, aux_data[87:64], aux_data[53:32]};

    b_a1_engine #(
        .NUM_VOICES(NUM_SLOTS), .N_MODES(N_MODES),
        .COEFF_DEPTH(COEFF_DEPTH), .THETA_DEPTH(THETA_DEPTH),
        .THETA_FILE(THETA_FILE), .VW(VW), .MW(MW)
    ) u_old (
        .clk(clk), .rst_n(rst_n),
        .class_vec(class_vec), .theta_base_vec(theta_base_vec),
        .ratio(ratio), .enable(enable),
        .rd_en(rd_en), .rd_voice(rd_voice), .rd_mode(rd_mode),
        .rd_data(rd_data), .rd_valid(aux_valid), .bank_ready(idle),
        .a1_we(a1_we), .a1_voice(a1_voice), .a1_mode(a1_mode),
        .a1_data(a1_data), .a1_ready(1'b1),
        .active(active), .done(done)
    );

    assign aux_re    = rd_en;
    assign aux_voice = rd_voice;
    assign aux_mode  = rd_mode;

    assign co_we     = a1_we;
    assign co_voice  = a1_voice;
    assign co_mode   = a1_mode;
    assign co_field  = 4'd1;
    assign co_wdata  = {{10{a1_data[21]}}, a1_data};

endmodule
