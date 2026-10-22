// -----------------------------------------------------------------------------
// b_voice_ctrl.sv -- B 类每声部激励控制（迁移第一步）
//
// 只做三件事（a1 刷新在 bank/独立模块，本模块不碰）：
//   * 分数 NCO：phase += base_inc * ratio，回绕发一个脉冲；
//   * AR 包络：env += (target-env) * step >> 24，gate 开向 1、关向 0；
//   * x = impulse ? env * vel >> 17 : 0（Q2.30 附近，供 modal bank 的 x）。
//
// Q：base_inc UQ0.32、ratio UQ1.15（1.0=0x8000）、env UQ0.32、step UQ0.24、vel UQ1.15。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module b_voice_ctrl (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               start,        // note-on：相位/包络从 0 起
    input  logic               gate,         // 0=release
    input  logic [31:0]        base_inc,     // UQ0.32
    input  logic [15:0]        ratio,        // UQ1.15
    input  logic [23:0]        attack_step,  // UQ0.24
    input  logic [23:0]        release_step, // UQ0.24
    input  logic [15:0]        vel_q,        // UQ1.15

    output logic signed [31:0] x,
    output logic               imp
);

    logic [31:0] phase;
    logic [32:0] phase_sum;
    logic [31:0] inc;
    logic [31:0] env;
    logic [31:0] target;
    logic signed [32:0] diff;
    logic signed [56:0] env_inc;

    wire [47:0] inc_prod = {16'd0, base_inc} * {32'd0, ratio};
    assign inc       = inc_prod[47:15];             // UQ0.32
    assign phase_sum = {1'b0, phase} + {1'b0, inc};
    wire imp_c       = phase_sum[32];
    assign target    = gate ? 32'hFFFF_FFFF : 32'd0;
    assign diff      = $signed({1'b0, target}) - $signed({1'b0, env});
    assign env_inc   = diff * $signed({1'b0, (gate ? attack_step : release_step)});

    // x = impulse ? env*vel >> 17 : 0；env*vel 是 Q1.47，右移 17 到 Q1.30
    logic signed [31:0] x_c;
    always_comb begin
        x_c = 32'sd0;
        if (imp_c)
            x_c = $signed(({16'd0, env} * {32'd0, vel_q}) >> 17);
    end

    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            phase <= 32'd0;
            env   <= 32'd0;
            imp   <= 1'b0;
            x     <= 32'sd0;
        end else begin
            phase <= phase_sum[31:0];
            env   <= env + 32'(env_inc >>> 24);
            imp   <= imp_c;
            x     <= x_c;
        end
    end

endmodule
