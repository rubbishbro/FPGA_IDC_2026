// -----------------------------------------------------------------------------
// post_chain.sv -- engine 后的 MVP 后级
//   envelope_mul -> body_filter -> reverb_filter -> dry_wet_mix -> final_adder
// 说明：当前 dry 未做 reverb 延迟对齐；这版先打通连接，下一步加 dry delay/predelay。
// -----------------------------------------------------------------------------
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

    envelope_mul u_env (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_data(in_data),
        .gain(env_gain), .out_valid(env_v), .out_data(env_data)
    );

    assign body_in_v = env_v;
    assign in_ready   = body_in_ready;

    body_filter #(.BODY_INSTRUMENT(0), .BODY_FILE("rtl/rom/body_coeff.mem")) u_body (
        .clk(clk), .rst_n(rst_n), .clear_valid(1'b0), .clear_ready(),
        .in_valid(body_in_v), .in_ready(body_in_ready), .in_sum(env_data),
        .out_valid(body_v), .out_sum(body_data), .out_sat(body_sat), .sat_count(body_sat_cnt),
        .coeff_ready(body_ready), .coeff_error(body_err)
    );

    reverb_filter u_rev (
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
