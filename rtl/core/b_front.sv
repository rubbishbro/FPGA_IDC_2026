// -----------------------------------------------------------------------------
// b_front.sv -- B 类前端：Control 解析 + 16 voice NCO/AR 激励
//
// 只负责“B 的 x 和包络参数”：
//   ctrl: base_inc / attack / release
//   class/vel/start/gate -> b_x_pool
// 系数、a1 刷新、seed 都不在这里（router / engine RAM）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module b_front #(
    parameter int NUM_SLOTS = 16
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic [NUM_SLOTS*256-1:0]   ctrl_vec,
    input  logic [NUM_SLOTS*2-1:0]     class_vec,
    input  logic [NUM_SLOTS*16-1:0]    vel_vec,
    input  logic [NUM_SLOTS-1:0]       start_mask,
    input  logic [NUM_SLOTS-1:0]       gate_mask,
    input  logic [15:0]                ratio,       // UQ1.15

    output logic [NUM_SLOTS*32-1:0]    x_vec,
    output logic [NUM_SLOTS*24-1:0]    attack_vec,
    output logic [NUM_SLOTS*24-1:0]    release_vec
);

    b_x_pool #(.NUM_VOICES(NUM_SLOTS)) u_pool (
        .clk(clk), .rst_n(rst_n),
        .ctrl_vec(ctrl_vec), .class_vec(class_vec), .vel_vec(vel_vec),
        .start_mask(start_mask), .gate_mask(gate_mask),
        .ratio(ratio), .x_vec(x_vec)
    );

    genvar g;
    generate
        for (g = 0; g < NUM_SLOTS; g = g + 1) begin : g_ctl
            // 与 b_x_pool 相同的字段：attack=[39:16]，release=[63:40]
            assign attack_vec[g*24 +: 24]  = ctrl_vec[g*256 + 16 +: 24];
            assign release_vec[g*24 +: 24] = ctrl_vec[g*256 + 40 +: 24];
        end
    endgenerate

endmodule
