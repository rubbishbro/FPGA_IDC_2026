// =============================================================================
// 文件 : router_frontend.sv
// 模块 : router_frontend
// 功能 : router 控制 + 激励前端
// 说明 : 组合 router_ctrl 与 excitation_convert。
// =============================================================================
`timescale 1ns/1ps
module router_frontend (
    input  logic clk, rst_n,
    input  logic cfg_valid,
    input  logic [3:0] cfg_instrument,
    input  logic [3:0] cfg_voice,
    input  logic [6:0] cfg_note,
    input  logic [7:0] cfg_velocity,
    input  logic [16*8-1:0] fmap,
    input  logic fmap_valid,

    output logic [3:0] instrument_id,
    output logic [1:0] engine_sel,
    output logic [15:0] coeff_base,
    output logic [15:0] ram_base,
    output logic load_req,
    output logic [3:0] load_voice,
    output logic [6:0] load_note,
    output logic [7:0] load_velocity,
    output logic [15:0] load_addr,
    output logic key_pressed,

    output logic [15:0] velocity,
    output logic signed [31:0] x,
    output logic x_valid
);
    logic [7:0] pressure;
    assign pressure = fmap[7:0];   // MVP：取第一个压力单元；后续由 key code 选

    router_ctrl u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_instrument(cfg_instrument),
        .cfg_voice(cfg_voice), .cfg_note(cfg_note), .cfg_velocity(cfg_velocity),
        .fmap(fmap), .fmap_valid(fmap_valid),
        .instrument_id(instrument_id), .engine_sel(engine_sel),
        .coeff_base(coeff_base), .ram_base(ram_base),
        .load_req(load_req), .load_voice(load_voice), .load_note(load_note),
        .load_velocity(load_velocity), .load_addr(load_addr),
        .key_pressed(key_pressed)
    );

    excitation_convert u_exc (
        .pressure(pressure), .valid(fmap_valid),
        .velocity(velocity), .x(x), .out_valid(x_valid)
    );
endmodule
