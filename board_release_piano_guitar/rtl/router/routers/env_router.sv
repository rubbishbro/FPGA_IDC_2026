// env_router -- 包络子路由：常数包络 / 两套 ADSR 参数 / 动态包络
module env_router #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    smp_tick,
    input logic [SLOTS*32-1:0] slot_a_step,slot_r_step,
    input  logic [SLOTS*8-1:0]      envelope_level,
    input  logic [SLOTS-1:0]        retrigger, slot_clear,
    input  logic                    midi_mode,
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
            router_pkg::INST_PIANO: begin
                use_adsr = 1'b1;
            end
            // router_pkg::INST_GUITAR: begin
            //     use_adsr = 1'b0;
            //     use_dyn  = 1'b1;
            // end
            router_pkg::INST_FLUTE,router_pkg::INST_TRUMPET,
            router_pkg::INST_CELLO,router_pkg::INST_VIOLIN:begin
                use_adsr=1; s_level=32'h1fffffff;
            end
            default: use_adsr = 1'b0;   // 常数包络（"无"）
        endcase
    end

    logic signed [SLOTS-1:0][31:0] m_adsr, m_dyn;
    logic               v_adsr, v_dyn;
    logic [SLOTS-1:0]   d_adsr, d_dyn;

    // 参数先打一拍再进包络：否则 inst_lat -> 常量 mux -> 32 位加法器 -> 比较 会串成一条长链
    logic [31:0] a_step_r, d_step_r, s_level_r, r_step_r,decay_limit_r;
    wire[31:0] decay_limit_c=(s_level>32'h7fffffff-d_step)?32'h7fffffff:s_level+d_step;
    logic sustain_mode_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sustain_mode_r <= 1'b0;
            a_step_r <= '0; d_step_r <= '0; s_level_r <= '0; r_step_r <= '0;decay_limit_r<=0;
        end else begin
            sustain_mode_r <= router_pkg::is_sustain(inst);
            a_step_r  <= a_step;
            d_step_r  <= d_step;
            s_level_r <= s_level;
            r_step_r  <= r_step;decay_limit_r<=decay_limit_c;
        end
    end

    envelope_ADSR #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SLOTS(SLOTS),.SUSTAIN_ENABLE(1),.PRECOMPUTED_DECAY_LIMIT(1)) u_adsr (
        .clk(clk), .rst_n(rst_n), .clk_en(smp_tick),
        .sustain_mode(sustain_mode_r),.slot_a_step(slot_a_step),.slot_r_step(slot_r_step),
        .retrigger(retrigger), .slot_clear(slot_clear),
        .A_STEP(a_step_r), .D_STEP(d_step_r), .S_LEVEL(s_level_r),
        .R_STEP(r_step_r),.decay_limit(decay_limit_r),
        .note_on(note_on), .note_gate(note_gate),
        .emap(m_adsr), .emap_valid(v_adsr), .dead(d_adsr)
    );

    envelope_dyn0 #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SLOTS(SLOTS)) u_dyn (
        .clk(clk), .rst_n(rst_n), .clk_en(smp_tick),
        .envelope_level(envelope_level), .slot_clear(slot_clear),
        .note_on(note_on), .note_gate(note_gate),
        .emap(m_dyn), .emap_valid(v_dyn), .dead(d_dyn)
    );

    always_comb begin
        emap_valid = smp_tick;
        dead       = use_dyn ? d_dyn : (use_adsr ? d_adsr :
                     (midi_mode ? ~note_gate : '0));
        dead = dead | slot_clear;
        for (int i = 0; i < SLOTS; i++)
            emap[i] = slot_clear[i] ? 32'sd0 :
                      (use_dyn ? m_dyn[i] : (use_adsr ? m_adsr[i] :
                       ((midi_mode && !note_gate[i]) ? 32'sd0 : 32'sh7FFF_FFFF)));
    end
endmodule
