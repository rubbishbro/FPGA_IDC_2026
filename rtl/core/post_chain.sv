// =============================================================================
// 文件 : post_chain.sv
// 模块 : post_chain
// 功能 : 正式后级链
// 说明 : envelope_mul → body_biquad → comb_reverb → dry_wet_mix → final_adder。
// =============================================================================
`timescale 1ns/1ps
module post_chain (
    input  logic clk, rst_n,
    input  logic in_valid,
    output logic in_ready,
    input  logic signed [63:0] in_data,
    input  logic [15:0] env_gain,
    input  logic [15:0] gd,
    input  logic [15:0] gw,
    output logic out_valid,
    output logic signed [63:0] out_data
);
    logic env_v, body_in_v, body_in_ready;
    logic signed [63:0] env_data, body_data;
    logic body_v;
    logic [3:0] body_sat;
    logic [2:0] body_sat_cnt;
    logic body_ready, body_err;
    logic rev_v;
    logic signed [63:0] rev_data;
    logic mix_v;
    logic mix_out_v;
    logic signed [63:0] mix_out_data;
    logic body_v_r;
    logic signed [63:0] body_data_r;
    logic env_pending;
    logic env_inflight;
    logic signed [63:0] env_pending_data;

    envelope_mul u_env (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_data(in_data),
        .gain(env_gain), .out_valid(env_v), .out_data(env_data)
    );

    // envelope 有一级延迟；用 1-entry buffer 隔离，in_ready 只在空时接收。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env_pending      <= 1'b0;
            env_inflight     <= 1'b0;
            env_pending_data <= 64'sd0;
        end else begin
            // 一次只允许一个样本在 envelope 的 1 级延迟中。
            if (in_valid && in_ready)
                env_inflight <= 1'b1;
            if (env_v) begin
                env_pending      <= 1'b1;
                env_pending_data <= env_data;
                env_inflight     <= 1'b0;
            end
            if (env_pending && body_in_ready)
                env_pending <= 1'b0;
        end
    end

    assign body_in_v = env_pending;
    assign in_ready   = !env_pending && !env_inflight;

    body_biquad #(.BODY_INSTRUMENT(0), .BODY_FILE("rtl/rom/body_coeff.mem")) u_body (
        .clk(clk), .rst_n(rst_n), .clear_valid(1'b0), .clear_ready(),
        .in_valid(body_in_v), .in_ready(body_in_ready), .in_sum(env_pending_data),
        .out_valid(body_v), .out_sum(body_data), .out_sat(body_sat), .sat_count(body_sat_cnt),
        .coeff_ready(body_ready), .coeff_error(body_err)
    );

    comb_reverb u_rev (
        .clk(clk), .rst_n(rst_n), .in_valid(body_v), .in_data(body_data),
        .out_valid(rev_v), .out_data(rev_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin body_v_r <= 1'b0; body_data_r <= 64'sd0; end
        else begin body_v_r <= body_v; if (body_v) body_data_r <= body_data; end
    end

    assign mix_v = rev_v;

    dry_wet_mix u_mix (
        .clk(clk), .rst_n(rst_n), .in_valid(mix_v), .dry(body_data_r), .wet(rev_data),
        .gd(gd), .gw(gw), .out_valid(mix_out_v), .out_data(mix_out_data)
    );

    final_adder #(.N(1)) u_final (
        .clk(clk), .rst_n(rst_n), .in_valid(mix_out_v),
        .in_bus(mix_out_data), .out_valid(out_valid), .out_data(out_data)
    );

endmodule
