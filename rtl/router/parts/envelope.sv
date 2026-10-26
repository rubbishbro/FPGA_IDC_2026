// -----------------------------------------------------------------------------
// 包络生成：每声部一个包络，输出 emap[16]
//   * 全局统一 Q1.31：1.0 = 2^31-1（router 用 (y*emap)>>>31）
//   * 采样节拍由 router 统一给（clk_en，当**时钟使能**用），不再自己分频
//   * ADSR 参数（含释放速率 R_STEP）由 router 的常量表按乐器选
// -----------------------------------------------------------------------------
module envelope_ADSR #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int SR_HZ   = 48_000,
    parameter int SLOTS   = 16
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        clk_en,        // 采样节拍：当**时钟使能**用（不是数据）
    // 包络参数（由 router 的常量表按乐器选择；综合成常量网络）
    input  logic [31:0]                 A_STEP,
    input  logic [31:0]                 D_STEP,
    input  logic [31:0]                 S_LEVEL,
    input  logic [31:0]                 R_STEP,        // 松键后的每采样下降量
    input  pad_driver_pkg::mat4x4       fmap,
    input  logic [SLOTS-1:0]            note_on,       // router 给：新音符
    input  logic [SLOTS-1:0]            note_gate,     // router 给：按住电平
    output logic signed [SLOTS-1:0][31:0] emap,         // 打包：emap[i] 取第 i 个声部
    output logic                        emap_valid,
    // 这个声部"确实空了"（= 松键后 release 走完、电平降到 0）。顶层拿它去清引擎状态。
    // 起音阶段 lvl 也是 0，但那时它是"刚开始响"，不是空的 —— 所以不能拿 emap==0 判断。
    output logic [SLOTS-1:0]            dead
);

    typedef enum logic [2:0] { E_IDLE, E_ATK, E_DEC, E_SUS, E_REL } est_e;

    est_e        st  [0:SLOTS-1];
    logic [31:0] lvl [0:SLOTS-1];
    // 衰减阈值只算一次（16 个声部共用）：S_LEVEL 是参数，配大了加法会绕回
    logic [31:0] dec_th;
    always_comb begin
        dec_th = (S_LEVEL > 32'h7FFF_FFFF - D_STEP) ? 32'h7FFF_FFFF : (S_LEVEL + D_STEP);
    end
    logic [SLOTS-1:0] dead_r;
    logic [SLOTS-1:0] gate;

    assign dead = dead_r;

    // 门控直接来自 router（阈值判断已经在那里统一做了）
    assign gate = note_gate;

    // note_on 是"按着就是 1"的滞回电平，不是脉冲：起音门必须自己取一拍沿，
    // 否则按住期间每个采样都会把 lvl 清 0，包络永远升不上去
    logic [SLOTS-1:0] note_on_q, onset;
    // 注意：必须用 clk_en 采样。跟着时钟每拍走的话 onset 只有一拍宽，
    // 而下面那个状态机只在节拍上跑 —— 没撞上节拍的起音就丢了（retrigger 时
    // 更明显：lvl 不会被清 0，直接从旧的包络高度接着走）。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      note_on_q <= '0;
        else if (clk_en) note_on_q <= note_on;
    end
    assign onset = note_on & ~note_on_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) begin
                st[i]     <= E_IDLE;
                lvl[i]    <= '0;
                dead_r[i] <= 1'b1;      // 上电/没弹过 -> 让顶层先把状态清干净
            end
        end else if (clk_en) begin
            for (int i = 0; i < SLOTS; i++) begin
                if (onset[i]) begin
                    lvl[i]    <= '0;
                    st[i]     <= E_ATK;
                    dead_r[i] <= 1'b0;  // 开始响了，不算空
                end else if (!gate[i]) begin
                    // 松开：进释放段，按 R_STEP 线性降到 0（不会再回 IDLE 之前被清掉）
                    if (lvl[i] <= R_STEP) begin
                        lvl[i]    <= '0;
                        st[i]     <= E_IDLE;
                        dead_r[i] <= 1'b1;   // release 走完、电平归零：这才是"真空了"
                    end else begin
                        lvl[i]    <= lvl[i] - R_STEP;
                        st[i]     <= E_REL;
                        dead_r[i] <= 1'b0;
                    end
                end else begin
                    dead_r[i] <= 1'b0;      // 按着（哪怕还在衰减/保持）都不算空
                    case (st[i])
                        E_IDLE: if (gate[i]) st[i] <= E_ATK;
                        // 起音：用 33 位和，只要超过 0x7FFF_FFFF 就钳住并转衰减。
                        //   原来靠 (lvl + A_STEP < lvl) 判溢出，那只抓得住"绕回"
                        //   （结果 >= 2^32）；落在 [2^31, 2^32) 的和判不出来，而有
                        //   符号 Q1.31 把 0x8000_0000 读成 -1.0。默认 A_STEP =
                        //   0x0100_0000 从 0 加上去正好命中 0x8000_0000，等于每次
                        //   起音峰值都打一个满幅负峰。
                        // 起音：**按有符号语义判越界**。lvl 就是 Q1.31，加法结果
                        //   只要第 31 位翻上去（>= 2^31）就说明超过 +1.0 了 ——
                        //   直接看符号位即可，不用 33 位加法，也不用跟 0x7FFFFFFF 比。
                        //   （默认 A_STEP = 0x0100_0000 正好会加到 0x8000_0000，
                        //     旧的无符号绕回判据漏掉了这一段，起音峰值会打一个负峰。）
                        E_ATK: begin
                            if (($signed(lvl[i]) + $signed(A_STEP)) < 0) begin
                                lvl[i] <= 32'h7FFF_FFFF;
                                st[i]  <= E_DEC;
                            end else begin
                                lvl[i] <= lvl[i] + A_STEP;
                            end
                        end
                        // 衰减：阈值也用 33 位算（S_LEVEL 是参数，配大了加法会绕回）
                        E_DEC: begin
                            if (lvl[i] <= dec_th) begin
                                lvl[i] <= S_LEVEL;
                                st[i]  <= E_SUS;
                            end else lvl[i] <= lvl[i] - D_STEP;
                        end
                        E_SUS: ;
                        E_REL: st[i] <= E_IDLE;   // 释放段的 lvl 处理在 !gate 分支里
                        default: st[i] <= E_IDLE;
                    endcase
                end
            end
        end
    end

    // 输出寄存器也走时钟使能（省得每个时钟都翻一次）；emap 只在节拍上更新，
    // 和 emap_valid 对齐
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) emap[i] <= '0;
        end else if (clk_en) begin
            // 兜底也按有符号语义：符号位是 1 就说明 lvl 已经越过 +1.0，钳到最大正数。
            for (int i = 0; i < SLOTS; i++)
                emap[i] <= ($signed(lvl[i]) < 0) ? 32'sh7FFF_FFFF : signed'(lvl[i]);
        end
    end
    assign emap_valid = clk_en;

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
    input  logic                        clk_en,        // 采样节拍：当**时钟使能**用（不是数据）
    input  pad_driver_pkg::mat4x4       fmap,
    input  logic [SLOTS-1:0]            note_on,
    input  logic [SLOTS-1:0]            note_gate,
    output logic signed [SLOTS-1:0][31:0] emap,         // 打包：emap[i] 取第 i 个声部
    output logic                        emap_valid,
    output logic [SLOTS-1:0]            dead           // 没按住 = 这个声部是空的
);

    // 力值 << SHIFT 必须钳在 0x7FFF_FFFF 以内：emap 是有符号 Q1.31，
    // 一旦进位到 bit31 就会被解读成负数（听感是极性翻转）。
    localparam logic [31:0] ENV_MAX = 32'h7FFF_FFFF;
    logic [31:0] lvl_c [0:SLOTS-1];
    always_comb begin
        for (int i = 0; i < SLOTS; i++) begin
            logic [31:0] v;
            v = 32'(fmap.flat_d[i].val) <<< SHIFT;
            lvl_c[i] = (v > ENV_MAX) ? ENV_MAX : v;
        end
    end

    assign dead = ~note_gate;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) emap[i] <= '0;
        end else if (clk_en) begin
            for (int i = 0; i < SLOTS; i++) begin
                if (note_gate[i])
                    emap[i] <= signed'(lvl_c[i]);
                else
                    emap[i] <= '0;
            end
        end
    end
    assign emap_valid = clk_en;

endmodule
