// -----------------------------------------------------------------------------
// voice_env_bank.sv -- NUM_SLOTS 个 voice_env 的并行包络组
//
// 输入按 voice 扁平化；输出直接接 eng1_engine_top 的 env_gain_vec。
// A 的 gain 恒 1.0；B 用 gate；C 用 choke/done。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module voice_env_bank #(
    parameter int NUM_SLOTS = 16,
    parameter int VW        = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS)
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic [NUM_SLOTS-1:0]     start_mask,
    input  logic [NUM_SLOTS-1:0]     gate_mask,
    input  logic [NUM_SLOTS-1:0]     choke_mask,
    input  logic [NUM_SLOTS-1:0]     done_mask,
    input  logic [NUM_SLOTS*2-1:0]   class_vec,
    input  logic [NUM_SLOTS*24-1:0]  attack_vec,
    input  logic [NUM_SLOTS*24-1:0]  release_vec,

    output logic [NUM_SLOTS*16-1:0]  env_gain_vec
);

    genvar g;
    generate
        for (g = 0; g < NUM_SLOTS; g = g + 1) begin : g_env
            voice_env u_env (
                .clk(clk), .rst_n(rst_n),
                .start(start_mask[g]),
                .gate(gate_mask[g]),
                .choke(choke_mask[g]),
                .done(done_mask[g]),
                .cls(class_vec[g*2 +: 2]),
                .attack_step(attack_vec[g*24 +: 24]),
                .release_step(release_vec[g*24 +: 24]),
                .gain(env_gain_vec[g*16 +: 16])
            );
        end
    endgenerate

endmodule
