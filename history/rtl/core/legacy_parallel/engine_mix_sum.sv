// -----------------------------------------------------------------------------
// engine_mix_sum.sv -- 四引擎结果求和骨架
//
// 每个引擎在 out_valid 时给出 mix_sum；本模块锁存各引擎结果，四个都到齐后
// 输出一次 out_valid + 总和。start 清空上一帧。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module engine_mix_sum #(
    parameter int NUM_ENGINES = 4
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          start,

    input  logic [NUM_ENGINES-1:0]        in_valid,
    input  logic [NUM_ENGINES*64-1:0]     in_mix,

    output logic                          out_valid,
    output logic signed [63:0]            mix_sum
);

    logic [NUM_ENGINES-1:0]       valid_r;
    logic signed [63:0]           mix_r [0:NUM_ENGINES-1];
    logic signed [63:0]           sum_c;
    int                           i;

    always_comb begin
        sum_c = 64'sd0;
        for (i = 0; i < NUM_ENGINES; i = i + 1)
            sum_c = sum_c + (in_valid[i] ? $signed(in_mix[i*64 +: 64]) : mix_r[i]);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_r   <= '0;
            out_valid <= 1'b0;
            mix_sum   <= 64'sd0;
            for (i = 0; i < NUM_ENGINES; i = i + 1)
                mix_r[i] <= 64'sd0;
        end else if (start) begin
            valid_r   <= '0;
            out_valid <= 1'b0;
            mix_sum   <= 64'sd0;
            for (i = 0; i < NUM_ENGINES; i = i + 1)
                mix_r[i] <= 64'sd0;
        end else begin
            out_valid <= 1'b0;
            for (i = 0; i < NUM_ENGINES; i = i + 1) begin
                if (in_valid[i]) begin
                    mix_r[i]   <= $signed(in_mix[i*64 +: 64]);
                    valid_r[i] <= 1'b1;
                end
            end
            if ((valid_r | in_valid) == {NUM_ENGINES{1'b1}}) begin
                out_valid <= 1'b1;
                mix_sum   <= sum_c;
                valid_r   <= '0;
            end
        end
    end

endmodule
