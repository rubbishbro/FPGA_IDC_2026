// exc_router -- 激励子路由：同一模块不同参数 = 不同乐器
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
    output logic signed [31:0]      xmap [0:15],
    output logic                    xmap_valid
);
    logic signed [31:0] m0 [0:15], m1 [0:15], m2 [0:15];
    logic v0, v1, v2;

    excitation_pulse_single #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SHIFT(20), .GATE_TH(1)) u0 (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap), .note_on(note_on), .xmap(m0), .xmap_valid(v0));
    excitation_pulse_single #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SHIFT(18), .GATE_TH(2)) u1 (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap), .note_on(note_on), .xmap(m1), .xmap_valid(v1));
    excitation_pulse_train  #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SHIFT(20), .GATE_TH(1)) u2 (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap), .note_on(note_on), .xmap(m2), .xmap_valid(v2));

    always_comb begin
        xmap_valid = v0;
        for (int i = 0; i < 16; i++) xmap[i] = m0[i];
        case (inst)
            router_pkg::INST_GUITAR: begin
                for (int i = 0; i < 16; i++) xmap[i] = m1[i];
                xmap_valid = v1;
            end
            router_pkg::INST_PAD, router_pkg::INST_BASS: begin
                for (int i = 0; i < 16; i++) xmap[i] = m2[i];
                xmap_valid = v2;
            end
            default: ;
        endcase
    end
endmodule
