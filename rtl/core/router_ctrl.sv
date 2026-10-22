// =============================================================================
// 文件 : router_ctrl.sv
// 模块 : router_ctrl
// 功能 : router 控制面
// 说明 : config/fmap → instrument_id/engine_sel/coeff/ram base/load 命令；不做 DSP。
// =============================================================================
`timescale 1ns/1ps
module router_ctrl (
    input  logic clk, rst_n,

    input  logic cfg_valid,
    input  logic [3:0] cfg_instrument,
    input  logic [3:0] cfg_voice,
    input  logic [6:0] cfg_note,
    input  logic [7:0] cfg_velocity,

    input  logic [16*8-1:0] fmap,       // 4×4 × 8-bit pressure
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

    output logic key_pressed
);
    import router_pkg::*;

    logic [3:0] id_r;
    logic [3:0] voice_r;
    logic [6:0] note_r;
    logic [7:0] vel_r;
    logic       req_r;

    always_comb begin
        instrument_id = id_r;
        engine_sel    = engine_class_of(id_r);
        coeff_base    = coeff_base_of(id_r);
        ram_base      = ram_base_of(id_r);
        load_req      = req_r;
        load_voice    = voice_r;
        load_note     = note_r;
        load_velocity = vel_r;
        load_addr     = coeff_base_of(id_r);
        key_pressed   = |fmap;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            id_r <= 4'd0; voice_r <= 4'd0; note_r <= 7'd0; vel_r <= 8'd0; req_r <= 1'b0;
        end else begin
            req_r <= cfg_valid;
            if (cfg_valid) begin
                id_r    <= cfg_instrument;
                voice_r <= cfg_voice;
                note_r  <= cfg_note;
                vel_r   <= cfg_velocity;
            end
        end
    end
endmodule
