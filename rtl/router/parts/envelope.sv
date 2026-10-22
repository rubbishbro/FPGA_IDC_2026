// -----------------------------------------------------------------------------
// 包络生成：每声部一个包络，输出 emap[16]
//   * 全局统一 Q1.31：1.0 = 2^31-1（router 用 (y*emap)>>>31）
//   * 采样节拍由 router 统一给（smp_tick），不再自己分频
//   * ADSR 参数走 parameter
// -----------------------------------------------------------------------------
module envelope_ADSR #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int SR_HZ   = 48_000,
    parameter int SLOTS   = 16,
    parameter int unsigned A_STEP  = 32'd16_777_216,   // 起振每采样增量
    parameter int unsigned D_STEP  = 32'd1_048_576,    // 衰减每采样减量
    parameter int unsigned S_LEVEL = 32'd536_870_912,  // 延音电平
    parameter int unsigned GATE_ON_TH  = 1,            // 按下阈值
    parameter int unsigned GATE_OFF_TH = 1             // 松开阈值（< 它立即归零）
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        smp_tick,
    input  pad_driver_pkg::mat4x4       fmap,
    input  logic [SLOTS-1:0]            note_on,       // router 给：新音符
    input  logic [SLOTS-1:0]            note_gate,     // router 给：按住电平
    output logic signed [31:0]          emap [0:15],
    output logic                        emap_valid
);

    typedef enum logic [2:0] { E_IDLE, E_ATK, E_DEC, E_SUS } est_e;
    est_e        st  [0:SLOTS-1];
    logic [31:0] lvl [0:SLOTS-1];
    logic [SLOTS-1:0] gate;

    // 门控直接来自 router（阈值判断已经在那里统一做了）
    assign gate = note_gate;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) begin
                st[i]  <= E_IDLE;
                lvl[i] <= '0;
            end
        end else if (smp_tick) begin
            for (int i = 0; i < SLOTS; i++) begin
                if (note_on[i]) begin
                    lvl[i] <= '0;
                    st[i]  <= E_ATK;
                end else if (!gate[i]) begin
                    lvl[i] <= '0;              // 低于松开阈值：立即归零（任何状态）
                    st[i]  <= E_IDLE;
                end else begin
                    case (st[i])
                        E_IDLE: if (gate[i]) st[i] <= E_ATK;
                        E_ATK: begin
                            lvl[i] <= (lvl[i] + A_STEP < lvl[i]) ? 32'h7FFF_FFFF
                                    : (lvl[i] + A_STEP);
                            if (lvl[i] + A_STEP >= 32'h7FFF_FFFF) st[i] <= E_DEC;
                        end
                        E_DEC: begin
                            if (lvl[i] <= S_LEVEL + D_STEP) begin
                                lvl[i] <= S_LEVEL;
                                st[i]  <= E_SUS;
                            end else lvl[i] <= lvl[i] - D_STEP;
                        end
                        E_SUS: ;
                        default: st[i] <= E_IDLE;
                    endcase
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        for (int i = 0; i < SLOTS; i++) emap[i] <= signed'(lvl[i]);
    end
    assign emap_valid = smp_tick;

endmodule


// -----------------------------------------------------------------------------
// 动态包络：直接跟随压力（Q1.31），按下才有效
// -----------------------------------------------------------------------------
module envelope_dyn0 #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int SR_HZ   = 48_000,
    parameter int SLOTS   = 16,
    parameter int SHIFT   = 23,          // 8 位力值 -> Q1.31（8+23 = 31）
    parameter int unsigned GATE_TH = 1
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        smp_tick,
    input  pad_driver_pkg::mat4x4       fmap,
    input  logic [SLOTS-1:0]            note_on,
    input  logic [SLOTS-1:0]            note_gate,
    output logic signed [31:0]          emap [0:15],
    output logic                        emap_valid
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) emap[i] <= '0;
        end else if (smp_tick) begin
            for (int i = 0; i < SLOTS; i++) begin
                if (note_gate[i])
                    emap[i] <= signed'(32'(fmap.flat_d[i].val) <<< SHIFT);
                else
                    emap[i] <= '0;
            end
        end
    end
    assign emap_valid = smp_tick;

endmodule

// -----------------------------------------------------------------------------
// envelope_const -- "无"包络：恒为 1.0（Q1.31）
// -----------------------------------------------------------------------------
module envelope_const #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        smp_tick,
    output logic signed [31:0]          emap [0:15],
    output logic                        emap_valid
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) emap[i] <= 32'sh7FFF_FFFF;
        end else begin
            for (int i = 0; i < SLOTS; i++) emap[i] <= 32'sh7FFF_FFFF;
        end
    end
    assign emap_valid = smp_tick;

endmodule
