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
// 换乐器时把 clear 打一拍照给 excitation_gen，清掉 16 个声部的状态机。
//
// 下面这些数值是"先能响"的占位值，要按听感调：
//   GUITAR     一次拨弦（1 个脉冲，2 采样宽）
//   BASS/PAD   持续激励（无限脉冲、不留低电平）
//   其它       1 个脉冲、1 采样宽（原先 pulse_single 的行为）
// -----------------------------------------------------------------------------
module exc_router #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    smp_tick,
    input  pad_driver_pkg::mat4x4   fmap,
    input  logic [SLOTS-1:0]        note_on,
    input  router_pkg::instrument_e inst,
    output logic signed [15:0][31:0] xmap,
    output logic                    xmap_valid
);
    logic [5:0]  shift;
    logic [15:0] pw_len, gap_len;
    logic [2:0]  n_pulse;

    // 常量表：加乐器 = 加一行
    always_comb begin
        shift   = 6'd20;
        pw_len  = 16'd1;
        gap_len = 16'd0;
        n_pulse = 3'd0;
        case (inst)
            router_pkg::INST_GUITAR: begin
                shift  = 6'd18;
                pw_len = 16'd2;          // 拨弦：2 个采样宽
            end
            router_pkg::INST_BASS, router_pkg::INST_PAD: begin
                n_pulse = 3'd7;          // 按住就一直给力
            end
            default: ;
        endcase
    end

    // 参数先打一拍再进激励（常量 mux -> 移位器会串成一条长链）
    logic [5:0]  shift_r;
    logic [15:0] pw_len_r, gap_len_r;
    logic [2:0]  n_pulse_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_r   <= '0;
            pw_len_r  <= '0;
            gap_len_r <= '0;
            n_pulse_r <= '0;
        end else begin
            shift_r   <= shift;
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

    excitation_gen #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SLOTS(SLOTS)) u_gen (
        .clk(clk), .rst_n(rst_n), .clk_en(smp_tick),
        .SHIFT(shift_r), .PW_LEN(pw_len_r), .GAP_LEN(gap_len_r), .N_PULSE(n_pulse_r),
        .clear(clear), .fmap(fmap), .note_on(note_on),
        .xmap(xmap), .xmap_valid(xmap_valid)
    );

endmodule
