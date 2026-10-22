// env_router -- 包络子路由：常数包络 / 两套 ADSR 参数 / 动态包络
module env_router #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    smp_tick,
    input  pad_driver_pkg::mat4x4   fmap,
    input  logic [SLOTS-1:0]        note_on,
    input  logic [SLOTS-1:0]        note_gate,
    input  router_pkg::instrument_e inst,
    output logic signed [31:0]      emap [0:15],
    output logic                    emap_valid
);
    logic signed [31:0] m0 [0:15], m1 [0:15], m2 [0:15], m3 [0:15];
    logic v0, v1, v2, v3;

    envelope_const u0 (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .emap(m0), .emap_valid(v0));

    envelope_ADSR #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ),
                    .A_STEP(32'd16_777_216), .D_STEP(32'd1_048_576),
                    .S_LEVEL(32'd536_870_912)) u1 (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .note_on(note_on), .note_gate(note_gate), .emap(m1), .emap_valid(v1));

    envelope_ADSR #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ),
                    .A_STEP(32'd4_194_304), .D_STEP(32'd4_194_304),
                    .S_LEVEL(32'd1_073_741_824)) u2 (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .note_on(note_on), .note_gate(note_gate), .emap(m2), .emap_valid(v2));

    envelope_dyn0 #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u3 (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .note_on(note_on), .note_gate(note_gate), .emap(m3), .emap_valid(v3));

    always_comb begin
        emap_valid = v0;
        for (int i = 0; i < 16; i++) emap[i] = m0[i];
        case (inst)
            router_pkg::INST_PIANO: begin
                for (int i = 0; i < 16; i++) emap[i] = m1[i];
                emap_valid = v1;
            end
            router_pkg::INST_MARIMBA, router_pkg::INST_E_PIANO: begin
                for (int i = 0; i < 16; i++) emap[i] = m2[i];
                emap_valid = v2;
            end
            router_pkg::INST_GUITAR, router_pkg::INST_BASS, router_pkg::INST_VIBES: begin
                for (int i = 0; i < 16; i++) emap[i] = m3[i];
                emap_valid = v3;
            end
            default: ;   // 其余 = 常数包络（"无"）
        endcase
    end
endmodule
