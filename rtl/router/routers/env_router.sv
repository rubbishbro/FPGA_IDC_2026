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
    output logic signed [SLOTS-1:0][31:0] emap,
    output logic                    emap_valid,
    // 每个声部"确实空了"的标志，由包络模块自己产生（顶层拿它清引擎状态）。
    // 常数包络永远不空，所以那一路恒 0。
    output logic [SLOTS-1:0]        dead
);
    // 参数常量表：加乐器 = 加一行，不用再加硬件
    logic [31:0] a_step, d_step, s_level, r_step;
    logic        use_adsr, use_dyn;

    always_comb begin
        // 默认（无包络）：直接用 dyn0 的直通也行，这里用 ADSR 的值占位
        a_step  = 32'd16_777_216;
        d_step  = 32'd1_048_576;
        s_level = 32'd536_870_912;
        r_step  = 32'd1_048_576;      // 满量程约 2048 采样 = 43 ms
        use_adsr = 1'b1;
        use_dyn  = 1'b0;
        case (inst)
            router_pkg::INST_PIANO: ;
            router_pkg::INST_MARIMBA, router_pkg::INST_E_PIANO: begin
                a_step  = 32'd4_194_304;
                d_step  = 32'd4_194_304;
                s_level = 32'd1_073_741_824;
                r_step  = 32'd2_097_152;   // 打击乐：短促一点（约 21 ms）
            end
            router_pkg::INST_GUITAR, router_pkg::INST_BASS, router_pkg::INST_VIBES: begin
                use_adsr = 1'b0;
                use_dyn  = 1'b1;
            end
            default: use_adsr = 1'b0;   // 常数包络（"无"）
        endcase
    end

    logic signed [SLOTS-1:0][31:0] m_adsr, m_dyn;
    logic               v_adsr, v_dyn;
    logic [SLOTS-1:0]   d_adsr, d_dyn;

    // 参数先打一拍再进包络：否则 inst_lat -> 常量 mux -> 32 位加法器 -> 比较 会串成一条长链
    logic [31:0] a_step_r, d_step_r, s_level_r, r_step_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_step_r <= '0; d_step_r <= '0; s_level_r <= '0; r_step_r <= '0;
        end else begin
            a_step_r  <= a_step;
            d_step_r  <= d_step;
            s_level_r <= s_level;
            r_step_r  <= r_step;
        end
    end

    envelope_ADSR #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_adsr (
        .clk(clk), .rst_n(rst_n), .clk_en(smp_tick), .fmap(fmap),
        .A_STEP(a_step_r), .D_STEP(d_step_r), .S_LEVEL(s_level_r),
        .R_STEP(r_step_r),
        .note_on(note_on), .note_gate(note_gate),
        .emap(m_adsr), .emap_valid(v_adsr), .dead(d_adsr)
    );

    envelope_dyn0 #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_dyn (
        .clk(clk), .rst_n(rst_n), .clk_en(smp_tick), .fmap(fmap),
        .note_on(note_on), .note_gate(note_gate),
        .emap(m_dyn), .emap_valid(v_dyn), .dead(d_dyn)
    );

    always_comb begin
        emap_valid = smp_tick;
        dead       = use_dyn ? d_dyn : (use_adsr ? d_adsr : '0);
        for (int i = 0; i < 16; i++)
            emap[i] = use_dyn ? m_dyn[i] : (use_adsr ? m_adsr[i] : 32'sh7FFF_FFFF);
    end
endmodule
