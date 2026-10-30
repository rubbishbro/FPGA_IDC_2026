`timescale 1ns/1ps
// router 内的演奏选源。MIDI 力度只进入激励，不经过压力门限/压力调音。
// sample_commit 必须是 router 真正接收激励快照的采样边界；frame_retire
// 表示该帧全部声部及后级已退休。midi_ready 是操作完成确认，不是提前收件。
module performance_input_mux #(
    parameter integer SLOTS = 16,
    parameter bit MIDI_ENABLE = 1'b0
) (
    input logic clk, rst_n,
    input logic sample_commit, frame_retire,
    input logic maintenance_clear,
    output logic maintenance_done, midi_inflight,
    input logic [SLOTS-1:0] pad_gate,
    input logic [SLOTS*8-1:0] pad_level,
    input logic midi_select, midi_valid,
    output logic midi_ready,
    input logic [SLOTS-1:0] midi_gate, midi_retrigger, midi_hard_clear,
    input logic [SLOTS*7-1:0] midi_velocity,
    output logic active_midi,
    output logic [SLOTS-1:0] gate, trigger, hard_clear,
    output logic [SLOTS*8-1:0] strike_level, envelope_level
);
    logic mode_q, op_inflight, switch_inflight, blank_q;
    logic clear_issued, clear_inflight;
    wire clear_now=MIDI_ENABLE && sample_commit && maintenance_clear &&
                   !clear_issued && !op_inflight && !switch_inflight;
    logic [SLOTS-1:0] gate_q;
    logic [SLOTS*7-1:0] velocity_q;
    wire requested_midi = MIDI_ENABLE && midi_select;
    wire switch_now = sample_commit && !op_inflight && !switch_inflight && !clear_inflight && !clear_now &&
                      (requested_midi != mode_q);
    wire apply_midi = sample_commit && mode_q && requested_midi &&
                      !op_inflight && !switch_inflight && !clear_inflight && !clear_now && midi_valid;
    logic [6:0] v;

    assign active_midi = mode_q;
    assign midi_inflight = op_inflight;
    assign maintenance_done = clear_inflight && frame_retire;
    // 未选 MIDI 时，仅供来源清理排空：旧 MIDI 已经在切源帧全部清除。
    // 上层须禁止未选来源的新演奏事件；不能借此让后台 MIDI 偷偷发声。
    assign midi_ready = rst_n && MIDI_ENABLE &&
                        ((op_inflight && frame_retire) ||
                         (!mode_q && !requested_midi && !switch_inflight));
    always_comb begin
        gate = mode_q ? (apply_midi ? (midi_gate & ~midi_hard_clear) : gate_q) : pad_gate;
        trigger = apply_midi ? (midi_retrigger & midi_gate & ~midi_hard_clear) : '0;
        hard_clear = apply_midi ? midi_hard_clear : '0;
        strike_level = pad_level;
        envelope_level = pad_level;
        v = '0;
        if (mode_q) begin
            for (integer i = 0; i < SLOTS; i = i + 1) begin
                v = apply_midi ? midi_velocity[i*7 +: 7] : velocity_q[i*7 +: 7];
                // 7->8 bit 端点保持：1->2, 64->129, 127->255。
                strike_level[i*8 +: 8] = {v, v[6]};
                // velocity 不再重复乘进动态包络。
                envelope_level[i*8 +: 8] = 8'hff;
            end
        end
        if (switch_now || clear_now || (MIDI_ENABLE && maintenance_clear) || (blank_q && !sample_commit)) begin
            gate = '0;
            trigger = '0;
        end
        if (switch_now || clear_now) hard_clear = '1;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_q <= 1'b0;
            clear_issued <= 1'b0;
            clear_inflight <= 1'b0;
            op_inflight <= 1'b0;
            switch_inflight <= 1'b0;
            blank_q <= 1'b0;
            gate_q <= '0;
            velocity_q <= '0;
        end else begin
            if (!maintenance_clear) clear_issued <= 1'b0;
            if (frame_retire) begin
                op_inflight <= 1'b0;
                switch_inflight <= 1'b0;
                clear_inflight <= 1'b0;
            end
            if (sample_commit) blank_q <= 1'b0;
            if (clear_now) begin
                clear_issued <= 1'b1;
                clear_inflight <= 1'b1;
                gate_q <= '0;
            end else if (switch_now) begin
                mode_q <= requested_midi;
                gate_q <= '0;
                velocity_q <= '0;
                switch_inflight <= 1'b1;
                blank_q <= 1'b1;
            end else if (apply_midi) begin
                gate_q <= midi_gate & ~midi_hard_clear;
                velocity_q <= midi_velocity;
                op_inflight <= 1'b1;
            end
        end
    end
endmodule
