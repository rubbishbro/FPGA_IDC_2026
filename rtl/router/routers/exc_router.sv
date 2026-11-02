`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// exc_router -- 乐器号 -> 通用拨弦/击锤或独立小号激励 -> xmap
//
// 和 env_router / body_router 一个套路：case (inst) 选参数，里面封装 parts 的
// 模块，对外只给 xmap。
//
// 参数含义（都进 excitation_gen）：
//   SHIFT   8 位力值 -> 32 位定点的左移量
//   PW_LEN  脉冲宽度（采样数，>=1）
//   GAP_LEN 脉冲间距（采样数，0 = 不留低电平，连续给力）
//   N_PULSE 单次触发最多 N+1 个脉冲；7 = 按住期间一直发
//
// 换乐器时把 clear 打一拍照给 excitation_gen，清掉 SLOTS 个声部的状态机。
// -----------------------------------------------------------------------------
module exc_router #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16,
    parameter bit SPLIT_RESET=0
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input logic rst_gen_n=1'b1,rst_trumpet_n=1'b1,
    input  logic                    smp_tick,
    input logic [SLOTS*16-1:0] slot_period,
    input logic [SLOTS*24-1:0] slot_pitch_delta='0,
    input  logic [SLOTS*8-1:0]      strike_level,
    input  logic [SLOTS-1:0]        retrigger, slot_clear,
    input  logic [SLOTS-1:0]        note_on,
    input  router_pkg::instrument_e inst,
    output logic signed [SLOTS-1:0][31:0] xmap,
    output logic                    xmap_valid
);
    logic [5:0]  shift, rise_sh;
    logic [15:0] pw_len, gap_len;
    logic [2:0]  n_pulse;

    // 常量表：加乐器 = 加一行
    //   SHIFT 的物理含义：x = (strike_level << SHIFT) / 2^XF，现在 XF = QF = 24，
    //   所以 strike_level=250 / SHIFT=16 -> x = 0.977（和 Python SF 的 amplitude 同量纲）。
    always_comb begin
        case (inst)
            router_pkg::INST_PIANO: begin
                shift=6'd16;rise_sh=6'd5;pw_len=16'd32;gap_len=16'd448;n_pulse=3'd3;
            end
            router_pkg::INST_PIANO_ABC: begin
                // Selected audition: 4-sample rise, exponential tail, four hits.
                // PW+GAP=480; preserve the audition's existing inter-hit count
                // behavior (subsequent rises execute PW+1 additions).
                shift   = 6'd16;
                rise_sh = 6'd2;
                pw_len  = 16'd4;
                gap_len = 16'd476;
                n_pulse = 3'd3;
            end
            router_pkg::INST_GUITAR: begin
                // TODO: 核定拨弦形状；暂保留两采样上升、单次拨弦。
                shift = 6'd16;
                rise_sh = 6'd1;
                pw_len = 16'd2;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_GUITAR_ABC: begin
                // Selected 32-sample pluck. excitation_gen shifts its output
                // right by 3 internally; downstream gain is not responsible.
                shift=6'd16;rise_sh=6'd5;pw_len=16'd32;gap_len=16'd0;n_pulse=3'd0;
            end
            router_pkg::INST_FLUTE: begin
                // Periodic single-sample impulse; rise/pw/gap/n are inactive.
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_TRUMPET: begin
                // Independent lip/onset/air module below owns this instrument.
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_CELLO: begin
                // TODO: 核定持续激励；当前走周期单采样冲激，rise/pw/gap/n 不参与。
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_VIOLIN: begin
                // TODO: 核定持续激励；当前走周期单采样冲激，rise/pw/gap/n 不参与。
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_OBOE: begin
                // TODO: 核定独立激励；暂保留原默认参数。
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_DRUMS: begin
                // TODO: 核定独立激励；暂保留原默认参数。
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_BANJO: begin
                // TODO: 核定独立激励；暂保留原默认参数。
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_MANDOLIN: begin
                // TODO: 核定独立激励；暂保留原默认参数。
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_NONE: begin
                // TODO: 核定独立激励；暂保留原默认参数。
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            default: begin
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
        endcase
    end

    // 参数先打一拍再进激励（常量 mux -> 移位器会串成一条长链）
    logic [5:0]  shift_r, rise_sh_r;
    logic [15:0] pw_len_r, gap_len_r;
    logic [2:0]  n_pulse_r;
    logic sustain_mode_r, trumpet_r, attenuate_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sustain_mode_r <= 1'b0;
            trumpet_r <= 1'b0;attenuate_r <= 1'b0;
            shift_r   <= '0;
            rise_sh_r <= '0;
            pw_len_r  <= '0;
            gap_len_r <= '0;
            n_pulse_r <= '0;
        end else begin
            sustain_mode_r <= router_pkg::is_sustain(inst);
            trumpet_r <= inst==router_pkg::INST_TRUMPET;
            attenuate_r <= inst==router_pkg::INST_GUITAR_ABC;
            shift_r   <= shift;
            rise_sh_r <= rise_sh;
            pw_len_r  <= pw_len;
            gap_len_r <= gap_len;
            n_pulse_r <= n_pulse;
        end
    end

    // 换乐器 -> 清内部状态（打一拍，别让 inst 比较串到状态清零上）
    router_pkg::instrument_e inst_q;
    logic                    clear;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) inst_q <= router_pkg::INST_NONE;
        else        inst_q <= inst;
    end
    assign clear = (inst != inst_q);

    logic signed [SLOTS-1:0][31:0] generic_xmap, trumpet_xmap;
    logic generic_valid, trumpet_valid;
    assign xmap=trumpet_r ? trumpet_xmap : generic_xmap;
    assign xmap_valid=trumpet_r ? trumpet_valid : generic_valid;

    excitation_gen #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SLOTS(SLOTS),.SUSTAIN_ENABLE(1)) u_gen (
        .clk(clk), .rst_n(SPLIT_RESET ? rst_gen_n : rst_n), .clk_en(smp_tick),
        .sustain_mode(sustain_mode_r),.attenuate_by_8(attenuate_r),
        .slot_period(slot_period),.slot_pitch_delta(slot_pitch_delta),
        .SHIFT(shift_r), .RISE_SH(rise_sh_r),
        .PW_LEN(pw_len_r), .GAP_LEN(gap_len_r), .N_PULSE(n_pulse_r),
        .clear(clear || trumpet_r), .strike_level(strike_level),
        .retrigger(retrigger), .slot_clear(slot_clear), .note_on(note_on),
        .xmap(generic_xmap), .xmap_valid(generic_valid)
    );

    trumpet_excitation #(.SLOTS(SLOTS),.SR_HZ(SR_HZ)) u_trumpet (
        .clk(clk),.rst_n(SPLIT_RESET ? rst_trumpet_n : rst_n),.clk_en(smp_tick),.enable(trumpet_r),.clear(clear),
        .slot_period(slot_period),.slot_pitch_delta(slot_pitch_delta),
        .strike_level(strike_level),.note_on(note_on),.retrigger(retrigger),.slot_clear(slot_clear),
        .xmap(trumpet_xmap),.xmap_valid(trumpet_valid)
    );

endmodule
