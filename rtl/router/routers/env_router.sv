// env_router -- 包络子路由：按乐器选择 ADSR / 常数包络
module env_router #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    smp_tick,
    input logic [SLOTS*32-1:0] slot_a_step,slot_r_step,
    input  logic [SLOTS*8-1:0]      envelope_level, // 保留接口；当前无压力直通分支
    input  logic [SLOTS-1:0]        retrigger, slot_clear,
    input  logic                    midi_mode,
    input  logic [SLOTS-1:0]        note_on,
    input  logic [SLOTS-1:0]        note_gate,
    input  router_pkg::instrument_e inst,
    output logic signed [SLOTS-1:0][31:0] emap,
    output logic                    emap_valid,
    // 每个声部"确实空了"的标志，由包络模块自己产生（顶层拿它清引擎状态）。
    // 常数包络：MIDI 松键报告空闲；压力垫模式保留自然衰减。
    output logic [SLOTS-1:0]        dead
);
    // 从当前 25% Sustain 电平释放约 400 ms；按采样率换算并四舍五入。
    // Release 为线性斜率：若从满幅松键，时间约为 1600 ms。
    localparam logic [31:0] PIANO_R_STEP =
        (64'd536_870_912 * 1000 + 64'(SR_HZ) * 200) / (64'(SR_HZ) * 400);
    logic [31:0] a_step, d_step, s_level, r_step;
    logic use_adsr;

    always_comb begin
        case (inst)
            router_pkg::INST_PIANO,router_pkg::INST_PIANO_ABC: begin
                // TODO: 核听 400 ms Release，其余暂保留现值。
                use_adsr = 1'b1;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'd536_870_912;
                // 本地调音：release 比 400 ms 的 PIANO_R_STEP 更短
                r_step = 32'd21_845;
            end
            router_pkg::INST_GUITAR,router_pkg::INST_GUITAR_ABC: begin
                // 本地调音：满幅 sustain、无 decay，release 走 74_566/2^31 每采样
                use_adsr = 1'b1;
                a_step = 32'd89_478_486;
                d_step = 32'd0;
                s_level = 32'h7fff_ffff;
                r_step = 32'd74_566;
            end
            router_pkg::INST_FLUTE: begin
                // TODO: 核定该乐器的独立包络参数；暂保留现有行为。
                use_adsr = 1'b1;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'h1fff_ffff;
                r_step = 32'd1_048_576;
            end
            router_pkg::INST_TRUMPET: begin
                // TODO: 核定该乐器的独立包络参数；暂保留现有行为。
                use_adsr = 1'b1;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'h1fff_ffff;
                r_step = 32'd1_048_576;
            end
            router_pkg::INST_CELLO: begin
                // TODO: 核定该乐器的独立包络参数；暂保留现有行为。
                use_adsr = 1'b1;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'h1fff_ffff;
                r_step = 32'd1_048_576;
            end
            router_pkg::INST_VIOLIN: begin
                // 本地调音：配合 current_frame 的连续帧包络，满幅 sustain + 559_241 释放斜率
                use_adsr = 1'b1;
                a_step = 32'd2_236_963;
                d_step = 32'd0;
                s_level = 32'h7fff_ffff;
                r_step = 32'd559_241;
            end
            router_pkg::INST_OBOE: begin
                // TODO: 核定该乐器的独立包络参数；暂保留现有行为。
                use_adsr = 1'b0;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'd536_870_912;
                r_step = 32'd1_048_576;
            end
            router_pkg::INST_DRUMS: begin
                // TODO: 核定该乐器的独立包络参数；暂保留现有行为。
                use_adsr = 1'b0;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'd536_870_912;
                r_step = 32'd1_048_576;
            end
            router_pkg::INST_BANJO: begin
                // TODO: 核定该乐器的独立包络参数；暂保留现有行为。
                use_adsr = 1'b0;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'd536_870_912;
                r_step = 32'd1_048_576;
            end
            router_pkg::INST_MANDOLIN: begin
                // TODO: 核定该乐器的独立包络参数；暂保留现有行为。
                use_adsr = 1'b0;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'd536_870_912;
                r_step = 32'd1_048_576;
            end
            router_pkg::INST_NONE: begin
                // TODO: 核定该乐器的独立包络参数；暂保留现有行为。
                use_adsr = 1'b0;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'd536_870_912;
                r_step = 32'd1_048_576;
            end
            default: begin
                use_adsr = 1'b0;
                a_step = 32'd16_777_216;
                d_step = 32'd1_048_576;
                s_level = 32'd536_870_912;
                r_step = 32'd1_048_576;
            end
        endcase
    end

    logic signed [SLOTS-1:0][31:0] m_adsr;
    logic v_adsr;
    logic [SLOTS-1:0] d_adsr;

    // 参数先打一拍再进包络：否则 inst_lat -> 常量 mux -> 32 位加法器 -> 比较 会串成一条长链
    logic [31:0] a_step_r, d_step_r, s_level_r, r_step_r,decay_limit_r;
    wire[31:0] decay_limit_c=(s_level>32'h7fffffff-d_step)?32'h7fffffff:s_level+d_step;
    logic sustain_mode_r,current_frame_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sustain_mode_r <= 1'b0;
            current_frame_r<=0;
            a_step_r <= '0; d_step_r <= '0; s_level_r <= '0; r_step_r <= '0;decay_limit_r<=0;
        end else begin
            sustain_mode_r <= router_pkg::is_sustain(inst) && inst!=router_pkg::INST_VIOLIN;
            current_frame_r<=inst==router_pkg::INST_VIOLIN;
            a_step_r  <= a_step;
            d_step_r  <= d_step;
            s_level_r <= s_level;
            r_step_r  <= r_step;decay_limit_r<=decay_limit_c;
        end
    end

    envelope_ADSR #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .SLOTS(SLOTS),.SUSTAIN_ENABLE(1),.PRECOMPUTED_DECAY_LIMIT(1)) u_adsr (
        .clk(clk), .rst_n(rst_n), .clk_en(smp_tick),
        .sustain_mode(sustain_mode_r),.current_frame(current_frame_r),.slot_a_step(slot_a_step),.slot_r_step(slot_r_step),
        .retrigger(retrigger), .slot_clear(slot_clear),
        .A_STEP(a_step_r), .D_STEP(d_step_r), .S_LEVEL(s_level_r),
        .R_STEP(r_step_r),.decay_limit(decay_limit_r),
        .note_on(note_on), .note_gate(note_gate),
        .emap(m_adsr), .emap_valid(v_adsr), .dead(d_adsr)
    );

    always_comb begin
        emap_valid = smp_tick;
        dead       = use_adsr ? d_adsr : (midi_mode ? ~note_gate : '0);
        dead = dead | slot_clear;
        for (int i = 0; i < SLOTS; i++)
            emap[i] = slot_clear[i] ? 32'sd0 :
                      (use_adsr ? m_adsr[i] :
                       ((midi_mode && !note_gate[i]) ? 32'sd0 : 32'sh7FFF_FFFF));
    end
endmodule
