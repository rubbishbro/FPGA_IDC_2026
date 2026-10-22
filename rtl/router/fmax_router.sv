// -----------------------------------------------------------------------------
// fmax_router.sv -- voice_router 的时序/面积探针（clk / rst_n / led）
//   内部 LFSR 造 fmap、start/reload/mod_req 脉冲；结果异或进累加器驱动 LED
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module fmax_router #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 48,
    parameter int X_DEPTH = 64
) (
    input  logic clk,
    input  logic rst_n,
    output logic led
);

    import router_pkg::*;

    pad_driver_pkg::mat4x4   fmap;
    router_pkg::instrument_e inst;
    logic                    reload, start, mod_req;
    logic [$clog2(SLOTS+1)-1:0]     n_voices;
    logic [$clog2(N_MODES+1)-1:0]   n_modes;
    logic [$clog2(X_DEPTH+1)-1:0]   n_samples;
    logic                    ready, busy, done, y_valid;
    logic signed [63:0]      y_data;
    logic signed [31:0]      ns_rd_data;
    logic                    ns_rd_valid;

    voice_router #(.SLOTS(SLOTS), .N_MODES(N_MODES), .X_DEPTH(X_DEPTH), .DEBUG_PORT(1'b0)) u_vr (
        .clk(clk), .rst_n(rst_n), .fmap(fmap), .inst(inst),
        .reload(reload), .mod_req(mod_req), .start(start),
        .n_voices(n_voices), .n_modes(n_modes), .n_samples(n_samples),
        .ready(ready), .busy(busy), .done(done),
        .y_valid(y_valid), .y_data(y_data),
        .qspi_cs_n(), .qspi_sck(), .qspi_dq_o(), .qspi_dq_oe(), .qspi_dq_i(4'b0101),
        .ns_rd_en(1'b0), .ns_rd_addr('0), .ns_rd_sel(1'b0),
        .ns_rd_data(ns_rd_data), .ns_rd_valid(ns_rd_valid)
    );

    logic [127:0] lfsr;
    logic [63:0] acc;
    logic [3:0]  inst_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr      <= {96'h0, 32'h1234_5678};
            acc       <= '0;
            led       <= 1'b0;
            start     <= 1'b0;
            reload    <= 1'b0;
            mod_req   <= 1'b0;
            n_voices  <= SLOTS[$clog2(SLOTS+1)-1:0];
            n_modes   <= N_MODES[$clog2(N_MODES+1)-1:0];
            n_samples <= 6'd8;
            inst_cnt  <= '0;
        end else begin
            lfsr <= {lfsr[126:0], lfsr[127] ^ lfsr[125] ^ lfsr[120] ^ lfsr[118]};
            led  <= ^acc;
            for (int i = 0; i < 16; i++) fmap.flat_d[i].val <= lfsr[8*i +: 8];

            if (y_valid) acc <= acc ^ y_data;

            reload  <= 1'b0;
            mod_req <= lfsr[7] & lfsr[15];

            if (ready && !busy) begin
                start    <= 1'b1;
                inst_cnt <= inst_cnt + 1'b1;
                inst     <= instrument_e'(inst_cnt);
            end else start <= 1'b0;
        end
    end

endmodule
