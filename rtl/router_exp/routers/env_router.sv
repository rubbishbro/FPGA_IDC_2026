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
    output logic signed [15:0][31:0] emap,
    output logic                    emap_valid
);
    // 参数常量表：加乐器 = 加一行，不用再加硬件
    logic [31:0] a_step, d_step, s_level;
    logic        use_adsr, use_dyn;

    always_comb begin
        // 默认（无包络）：直接用 dyn0 的直通也行，这里用 ADSR 的值占位
        a_step  = 32'd16_777_216;
        d_step  = 32'd1_048_576;
        s_level = 32'd536_870_912;
        use_adsr = 1'b1;
        use_dyn  = 1'b0;
        case (inst)
            router_pkg::INST_PIANO: ;
            router_pkg::INST_MARIMBA, router_pkg::INST_E_PIANO: begin
                a_step  = 32'd4_194_304;
                d_step  = 32'd4_194_304;
                s_level = 32'd1_073_741_824;
            end
            router_pkg::INST_GUITAR, router_pkg::INST_BASS, router_pkg::INST_VIBES: begin
                use_adsr = 1'b0;
                use_dyn  = 1'b1;
            end
            default: use_adsr = 1'b0;   // 常数包络（"无"）
        endcase
    end

    logic signed [15:0][31:0] m_adsr, m_dyn;
    logic               v_adsr, v_dyn;

    envelope_ADSR #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_adsr (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .A_STEP(a_step), .D_STEP(d_step), .S_LEVEL(s_level),
        .note_on(note_on), .note_gate(note_gate),
        .emap(m_adsr), .emap_valid(v_adsr)
    );

    envelope_dyn0 #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_dyn (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .note_on(note_on), .note_gate(note_gate),
        .emap(m_dyn), .emap_valid(v_dyn)
    );

    always_comb begin
        emap_valid = smp_tick;
        for (int i = 0; i < 16; i++)
            emap[i] = use_dyn ? m_dyn[i] : (use_adsr ? m_adsr[i] : 32'sh7FFF_FFFF);
    end
endmodule
