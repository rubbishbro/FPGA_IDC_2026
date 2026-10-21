// -----------------------------------------------------------------------------
// voice_env.sv -- 每个 voice 的输出包络（A unity / B AR / C fade）
//
// 位置：engine 内、voice_sum 之后、mix 之前。
// 语义：
//   A：gain = 1.0（0x8000）
//   B：AR；start 清 0，gate=1 向 1.0 逼近，gate=0 向 0 逼近
//   C：start 置 1.0；done 或 choke 后向 0 逼近（fade）
//
// env 内部 UQ0.32；输出 gain UQ1.15（1.0=0x8000）。
// attack/release step 为 UQ0.24，与旧 control 字段一致。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module voice_env (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,       // note-on 单拍
    input  logic        gate,        // B：1=attack，0=release
    input  logic        choke,       // C：同组新 hit
    input  logic        done,        // C：timer 到 0
    input  logic [1:0]  cls,         // 0=A,1=B,2=C

    input  logic [23:0] attack_step, // UQ0.24
    input  logic [23:0] release_step,// UQ0.24

    output logic [15:0] gain         // UQ1.15
);

    logic [31:0] env;
    logic        c_rel_r;
    logic [31:0] target;
    logic [23:0] step;
    logic signed [32:0] diff;
    logic signed [57:0] env_inc;
    logic signed [32:0] env_next;

    wire is_a = (cls == 2'd0);
    wire is_b = (cls == 2'd1);
    wire is_c = (cls == 2'd2);
    wire c_release = done | choke;

    always_comb begin
        target = 32'd0;
        step   = release_step;
        if (is_a) begin
            target = 32'hFFFF_FFFF;
            step   = 24'd0;
        end else if (is_b) begin
            target = gate ? 32'hFFFF_FFFF : 32'd0;
            step   = gate ? attack_step : release_step;
        end else if (is_c) begin
            target = c_rel_r ? 32'd0 : 32'hFFFF_FFFF;
            step   = release_step;
        end
    end

    assign diff    = $signed({1'b0, target}) - $signed({1'b0, env});
    assign env_inc = diff * $signed({1'b0, step});
    assign env_next = $signed({1'b0, env}) + (env_inc >>> 24);

    // gain = round(env / 2^17)，clamp 到 0x8000
    wire [32:0] gain_raw = ({1'b0, env} + 33'd65536) >> 17;
    assign gain = (gain_raw > 33'd32768) ? 16'h8000 : gain_raw[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env     <= 32'd0;
            c_rel_r <= 1'b0;
        end else if (start) begin
            c_rel_r <= 1'b0;
            if (is_a || is_c) env <= 32'hFFFF_FFFF;
            else              env <= 32'd0;
        end else begin
            if (is_c && c_release) c_rel_r <= 1'b1;
            if (!is_a) begin
            if (env_next > 33'sh0_FFFF_FFFF)
                env <= 32'hFFFF_FFFF;
            else if (env_next < 0)
                env <= 32'd0;
            else
                env <= env_next[31:0];
            end
        end
    end

endmodule
