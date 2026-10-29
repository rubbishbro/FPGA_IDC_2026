// -----------------------------------------------------------------------------
// 包络生成：每声部一个包络，输出 emap[SLOTS]
//   * 全局统一 Q1.31：1.0 = 2^31-1（router 用 (y*emap)>>>31）
//   * 采样节拍由 router 统一给（clk_en，当**时钟使能**用），不再自己分频
//   * ADSR 参数（含释放速率 R_STEP）由 router 的常量表按乐器选
// -----------------------------------------------------------------------------
module envelope_ADSR #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int SR_HZ   = 48_000,
    parameter int SLOTS   = 16,
    parameter bit SUSTAIN_ENABLE=0,
    parameter bit PRECOMPUTED_DECAY_LIMIT=0
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        clk_en,        // 采样节拍：当**时钟使能**用（不是数据）
    // 包络参数（由 router 的常量表按乐器选择；综合成常量网络）
    input logic sustain_mode,
    input logic [SLOTS*32-1:0] slot_a_step,slot_r_step,
    input  logic [31:0]                 A_STEP,
    input  logic [31:0]                 D_STEP,
    input  logic [31:0]                 S_LEVEL,
    input logic [31:0] decay_limit,
    input  logic [31:0]                 R_STEP,        // 松键后的每采样下降量
    input  logic [SLOTS-1:0]            retrigger, slot_clear,
    input  logic [SLOTS-1:0]            note_on,       // router 给：新音符
    input  logic [SLOTS-1:0]            note_gate,     // router 给：按住电平
    output logic signed [SLOTS-1:0][31:0] emap,         // 打包：emap[i] 取第 i 个声部
    output logic                        emap_valid,
    // 这个声部"确实空了"（= 松键后 release 走完、电平降到 0）。顶层拿它去清引擎状态。
    // 起音阶段 lvl 也是 0，但那时它是"刚开始响"，不是空的 —— 所以不能拿 emap==0 判断。
    output logic [SLOTS-1:0]            dead
);

    typedef enum logic [2:0] { E_IDLE,E_ATK,E_DEC,E_SUS,E_REL } est_e;
    est_e st[0:SLOTS-1],next_st[0:SLOTS-1];
    logic [31:0] lvl[0:SLOTS-1],next_lvl[0:SLOTS-1];
    logic [SLOTS-1:0] dead_r,next_dead,note_on_q,onset;
    wire use_slot=SUSTAIN_ENABLE && sustain_mode;
    assign dead=dead_r;
    assign onset=(note_on & ~note_on_q) | retrigger;
    // Four independent octet comparisons plus a balanced prefix, avoiding
    // a LUT carry chain across the entire 32-bit release/decay comparator.
    function automatic logic le32(input logic[31:0] a,b);
        logic[3:0] lt,eq;
        begin
            for(integer j=0;j<4;j++)begin
                lt[j]=a[j*8 +:8]<b[j*8 +:8];eq[j]=a[j*8 +:8]==b[j*8 +:8];
            end
            return lt[3] || (eq[3]&&lt[2]) || (eq[3]&&eq[2]&&lt[1]) ||
                   (eq[3]&&eq[2]&&eq[1]&&(lt[0]||eq[0]));
        end
    endfunction
    always_comb begin
        for(int i=0;i<SLOTS;i++) begin
            logic [31:0] a,r,dec_th;
            logic [32:0] attack_sum;
            a=use_slot ? slot_a_step[i*32 +:32] : A_STEP;
            r=use_slot ? slot_r_step[i*32 +:32] : R_STEP;
            dec_th=PRECOMPUTED_DECAY_LIMIT ? decay_limit :
                ((S_LEVEL>32'h7fffffff-D_STEP) ? 32'h7fffffff : S_LEVEL+D_STEP);
            attack_sum={1'b0,lvl[i]}+{1'b0,a};
            next_lvl[i]=lvl[i];next_st[i]=st[i];next_dead[i]=dead_r[i];
            if(slot_clear[i]) begin next_lvl[i]=0;next_st[i]=E_IDLE;next_dead[i]=1;end
            else if(onset[i]) begin next_lvl[i]=0;next_st[i]=E_ATK;next_dead[i]=0;end
            else if(!note_gate[i]) begin
                if(le32(lvl[i],r))begin next_lvl[i]=0;next_st[i]=E_IDLE;next_dead[i]=1;end
                else begin next_lvl[i]=lvl[i]-r;next_st[i]=E_REL;next_dead[i]=0;end
            end else begin
                next_dead[i]=0;
                case(st[i])
                    E_IDLE:next_st[i]=E_ATK;
                    E_ATK:if((attack_sum[32] || attack_sum[31]))begin next_lvl[i]=32'h7fffffff;next_st[i]=E_DEC;end
                          else next_lvl[i]=attack_sum[31:0];
                    E_DEC:if(le32(lvl[i],dec_th))begin next_lvl[i]=S_LEVEL;next_st[i]=E_SUS;end
                          else next_lvl[i]=lvl[i]-D_STEP;
                    E_SUS:;
                    E_REL:next_st[i]=E_IDLE;
                    default:next_st[i]=E_IDLE;
                endcase
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            note_on_q<='0;dead_r<='1;
            for(int i=0;i<SLOTS;i++)begin st[i]<=E_IDLE;lvl[i]<=0;emap[i]<=0;end
        end else if(clk_en)begin
            note_on_q<=note_on;dead_r<=next_dead;
            for(int i=0;i<SLOTS;i++)begin
                st[i]<=next_st[i];lvl[i]<=next_lvl[i];
                // B uses this frame's envelope; the legacy piano keeps its old latency.
                emap[i]<=use_slot ? signed'(next_lvl[i]) :
                    ((slot_clear[i] || retrigger[i]) ? 32'sd0 :
                     ($signed(lvl[i])<0 ? 32'sh7fffffff : signed'(lvl[i])));
            end
        end
    end
    assign emap_valid=clk_en;
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
    input  logic [SLOTS*8-1:0]          envelope_level,
    input  logic [SLOTS-1:0]            slot_clear,
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
            v = 32'(envelope_level[i*8 +: 8]) <<< SHIFT;
            lvl_c[i] = (v > ENV_MAX) ? ENV_MAX : v;
        end
    end

    assign dead = ~note_gate | slot_clear;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) emap[i] <= '0;
        end else if (clk_en) begin
            for (int i = 0; i < SLOTS; i++) begin
                if (note_gate[i] && !slot_clear[i])
                    emap[i] <= signed'(lvl_c[i]);
                else
                    emap[i] <= '0;
            end
        end
    end
    assign emap_valid = clk_en;

endmodule
