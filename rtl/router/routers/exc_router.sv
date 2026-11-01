`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// exc_router -- 激励子路由：乐器号 -> 参数表 -> excitation_gen
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
    parameter int SLOTS  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
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
                // 钢琴击弦：对齐 sythsound/sim_piano.py::SF 的形状（方案 B）
                //   Python: 0.5 ms 线性上升 + 1 ms 指数尾巴 + 10 ms 一个 + 0.7^k 递减，4 个
                //   这里:   2 采样上升 + 指数尾巴 + 周期 480(10 ms) + 0.6875^k
                //   PW_LEN = 1<<RISE_SH = 2 -> 上升结束正好到峰值（本地调音从 32/448 收到 2/478）
                //   GAP_LEN = 周期 - PW_LEN = 478（实测周期 = PW_LEN + GAP_LEN）
                //   峰值幅度由 SHIFT 决定：xmap = strike_level<<SHIFT
                //     250<<16 / 2^24 = 0.977（Python SF 默认 amplitude=1.4，demo 里是 1.0）
                shift   = 6'd16;
                rise_sh = 6'd1;
                pw_len  = 16'd2;
                gap_len = 16'd478;
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
            router_pkg::INST_FLUTE: begin
                // TODO: 核定持续激励；当前走周期单采样冲激，rise/pw/gap/n 不参与。
                shift = 6'd16;
                rise_sh = 6'd5;
                pw_len = 16'd32;
                gap_len = 16'd0;
                n_pulse = 3'd0;
            end
            router_pkg::INST_TRUMPET: begin
                // TODO: 核定持续激励；当前走周期单采样冲激，rise/pw/gap/n 不参与。
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
    logic sustain_mode_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sustain_mode_r <= 1'b0;
            shift_r   <= '0;
            rise_sh_r <= '0;
            pw_len_r  <= '0;
            gap_len_r <= '0;
            n_pulse_r <= '0;
        end else begin
            sustain_mode_r <= router_pkg::is_sustain(inst);
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

    excitation_gen #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SLOTS(SLOTS),.SUSTAIN_ENABLE(1)) u_gen (
        .clk(clk), .rst_n(rst_n), .clk_en(smp_tick),
        .sustain_mode(sustain_mode_r),.slot_period(slot_period),.slot_pitch_delta(slot_pitch_delta),
        .SHIFT(shift_r), .RISE_SH(rise_sh_r),
        .PW_LEN(pw_len_r), .GAP_LEN(gap_len_r), .N_PULSE(n_pulse_r),
        .clear(clear), .strike_level(strike_level),
        .retrigger(retrigger), .slot_clear(slot_clear), .note_on(note_on),
        .xmap(xmap), .xmap_valid(xmap_valid)
    );

endmodule
