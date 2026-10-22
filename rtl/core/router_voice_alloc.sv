// -----------------------------------------------------------------------------
// voice_router.sv -- 全局 16 voice 的 class/active/gate 路由
//
// 全局 voice 0..15；每个 voice 同一时刻属于一个引擎：
//   cls=0 A, 1 B, 2 C, 3 ENG2
// 每个引擎物理 16 slot，所以 local slot = global voice，不需要搬移。
//
// 本模块只做“事件 -> 每引擎 active/note_start/gate/choke”；
// index/control/seed 表仍在更上层的 router/ROM。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module router_voice_alloc #(
    parameter int NUM_VOICES = 16,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES)
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  note_on,
    input  logic                  note_off,
    input  logic [VW-1:0]         voice,
    input  logic [1:0]            cls,

    output logic [NUM_VOICES-1:0] a_active,
    output logic [NUM_VOICES-1:0] b_active,
    output logic [NUM_VOICES-1:0] c_active,
    output logic [NUM_VOICES-1:0] e2_active,

    output logic [NUM_VOICES-1:0] a_note_start,
    output logic [NUM_VOICES-1:0] b_note_start,
    output logic [NUM_VOICES-1:0] c_note_start,
    output logic [NUM_VOICES-1:0] e2_note_start,

    output logic [NUM_VOICES-1:0] a_gate,
    output logic [NUM_VOICES-1:0] b_gate,
    output logic [NUM_VOICES-1:0] c_choke,

    output logic [NUM_VOICES-1:0] voice_active,
    output logic [NUM_VOICES*2-1:0] voice_class
);

    logic [NUM_VOICES-1:0] active_r, gate_r, start_r;
    logic [NUM_VOICES*2-1:0] class_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_r <= '0;
            gate_r   <= '0;
            start_r  <= '0;
            class_r  <= '0;
        end else begin
            start_r <= '0;
            if (note_on && (voice < NUM_VOICES)) begin
                active_r[voice] <= 1'b1;
                gate_r[voice]   <= 1'b1;
                class_r[voice*2 +: 2] <= cls;
                start_r[voice]  <= 1'b1;
            end else if (note_off && (voice < NUM_VOICES)) begin
                active_r[voice] <= 1'b0;
                gate_r[voice]   <= 1'b0;
            end
        end
    end

    genvar g;
    generate
        for (g = 0; g < NUM_VOICES; g = g + 1) begin : g_map
            wire [1:0] vc = class_r[g*2 +: 2];
            assign voice_active[g] = active_r[g];
            assign voice_class[g*2 +: 2] = vc;

            assign a_active[g]  = active_r[g] && (vc == 2'd0);
            assign b_active[g]  = active_r[g] && (vc == 2'd1);
            assign c_active[g]  = active_r[g] && (vc == 2'd2);
            assign e2_active[g] = active_r[g] && (vc == 2'd3);

            assign a_note_start[g]  = start_r[g] && (vc == 2'd0);
            assign b_note_start[g]  = start_r[g] && (vc == 2'd1);
            assign c_note_start[g]  = start_r[g] && (vc == 2'd2);
            assign e2_note_start[g] = start_r[g] && (vc == 2'd3);

            assign a_gate[g]   = gate_r[g] && (vc == 2'd0);
            assign b_gate[g]   = gate_r[g] && (vc == 2'd1);
            assign c_choke[g]  = 1'b0;
        end
    endgenerate

endmodule
