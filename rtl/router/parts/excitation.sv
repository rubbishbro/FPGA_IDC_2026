`timescale 1ns/1ps
// =============================================================================
// 激励生成：整张 strike_level -> 整张 xmap（每个 clk_en 一个样本）
//
// 每个声部一个小的"力包络"状态机，由 note_on / retrigger 起音，slot_clear 强制清除：
//
//   按下上升沿 -> 第 1 个锤击：
//        X_ATT   : 每采样 acc += target>>RISE_SH，共 PW_LEN 个采样（线性上升）
//        X_DECAY : 每采样 acc -= (acc>>6)+(acc>>8)+(acc>>10)   （指数尾巴，tau≈1 ms）
//                  同时数 GAP_LEN 个采样；到期后按 N_PULSE 决定继续/停
//   下一个锤击：target <- target - (target>>2) - (target>>4)   （≈0.7×，锤子回弹）
//   松开 -> 当前脉冲走完（到 X_DECAY 结束）就停
//
// 这一版对齐 sythsound/sim_piano.py::SF 的激励形状（之前是纯矩形，能量全堆在
// 高频，听感"薄、不密集"）：
//   Python: 0.5 ms 线性上升 + 1 ms 指数尾巴 + 10 ms 一个 + 0.7^k 递减，共 4 个
//   这里:   PW_LEN=32(0.67 ms) + 指数尾巴 tau≈48 采样 + GAP_LEN=448 + 0.6875^k
// 全用移位/加法，**没有乘法器**。
//
// 参数全部由上级 router（exc_router）按乐器填：
//   SHIFT    峰值幅度（x = strike_level << SHIFT）
//   RISE_SH  每采样的上升步长 = target>>RISE_SH；配 PW_LEN = 1<<RISE_SH 时刚好升到峰值
//   PW_LEN   上升段长度（采样）
//   GAP_LEN  衰减段长度（采样）；**周期 = PW_LEN + GAP_LEN**
//   N_PULSE  0..6 -> 最多 N+1 个脉冲；7 -> 按住期间一直发
//
// clear：换乐器时把 SLOTS 个声部的状态机全清（router 给一拍，可能不在节拍上，
//        所以用 clr_pend 挂起，见下面的注释）。
// =============================================================================
module excitation_gen #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16,
    parameter bit SUSTAIN_ENABLE = 0
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          clk_en,        // 采样节拍：当**时钟使能**用（不是数据）
    input logic sustain_mode,
    input logic [SLOTS*16-1:0] slot_period,
    input  logic [5:0]                    SHIFT,      // 8 位力值 -> 32 位定点的左移量
    input  logic [5:0]                    RISE_SH,    // 上升步长 = target >> RISE_SH
    input  logic [15:0]                   PW_LEN,     // 上升段长度（采样数，>=1）
    input  logic [15:0]                   GAP_LEN,    // 衰减段长度（采样数）
    input  logic [2:0]                    N_PULSE,    // 0..6 -> 最多 N+1 个；7 -> 按住期间无限
    input  logic                          clear,      // 换乐器：清全部声部状态
    input  logic [SLOTS*8-1:0]            strike_level, // 已选源的激励幅度
    input  logic [SLOTS-1:0]              retrigger,   // 同 gate 下也能重新起音
    input  logic [SLOTS-1:0]              slot_clear,  // 采样边界逐槽清除
    input  logic [SLOTS-1:0]              note_on,    // 按下电平（router 的滞回门控）
    output logic signed [SLOTS-1:0][31:0] xmap,       // 打包：xmap[i] 取第 i 个声部
    output logic                          xmap_valid
);

    // X_ATT = 线性上升段，X_DECAY = 指数尾巴 + 等下一个脉冲
    typedef enum logic [1:0] { X_IDLE, X_ATT, X_DECAY } xs_e;

    xs_e               st  [0:SLOTS-1];
    logic signed [31:0] acc [0:SLOTS-1];    // 当前力（Q 同 xmap）
    logic signed [31:0] tgt [0:SLOTS-1];    // 本轮锤击的目标峰值（0.7^k 递减）
    logic [15:0]       cnt [0:SLOTS-1];     // 本状态已过的采样数
    logic [3:0]        num [0:SLOTS-1];     // 本串第几个脉冲（从 1 起）
    logic [SLOTS-1:0]  note_q;
    // clear 是上层给的一拍脉冲，状态机只在 clk_en 上跑 —— 不挂起会漏掉
    logic              clr_pend;

    // xmap 直接跟随累加器（组合），时序和原来一致（router 那边按 xmap_valid 采）
    for (genvar gi = 0; gi < SLOTS; gi++) begin : g_xmap
        assign xmap[gi] = acc[gi];
    end
    assign xmap_valid = clk_en;

    // 上一拍的门控，用来取沿
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      note_q <= '0;
        else if (clk_en) note_q <= note_on;
    end

    // clear 挂起：任何一拍来都记住，等下一个节拍消费
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      clr_pend <= 1'b0;
        else if (clk_en) clr_pend <= 1'b0;
        else if (clear)  clr_pend <= 1'b1;
    end

    // 这个脉冲之后还能不能接着发
    function automatic logic more_pulse(input logic [3:0] n);
        more_pulse = (N_PULSE == 3'd7) || (n <= 4'(N_PULSE));
    endfunction

    // 指数尾巴的每采样衰减量：0.0205 ≈ (1/64 + 1/256 + 1/1024) -> tau ≈ 48.6 采样 ≈ 1.01 ms
    function automatic logic signed [31:0] decay_step(input logic signed [31:0] v);
        decay_step = (v >>> 6) + (v >>> 8) + (v >>> 10);
    endfunction

    // 下一个锤击的目标：×0.6875 ≈ Python 的 0.7
    function automatic logic signed [31:0] taper(input logic signed [31:0] v);
        taper = v - (v >>> 2) - (v >>> 4);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) begin
                st[i]  <= X_IDLE;
                acc[i] <= '0;
                tgt[i] <= '0;
                cnt[i] <= '0;
                num[i] <= '0;
            end
        end else if (clk_en) begin
            for (int i = 0; i < SLOTS; i++) begin
                if (clear || clr_pend || slot_clear[i]) begin
                    // 换乐器：力归零、状态机复位
                    st[i]  <= X_IDLE;
                    acc[i] <= '0;
                    tgt[i] <= '0;
                    cnt[i] <= '0;
                    num[i] <= '0;
                end else if (SUSTAIN_ENABLE && sustain_mode) begin
                    // One-sample impulses with independent period. No taper/strike tail.
                    st[i] <= X_IDLE; num[i] <= '0;
                    if(!note_on[i] || slot_period[i*16 +:16]<2) begin
                        acc[i]<='0;cnt[i]<='0;tgt[i]<='0;
                    end else if(retrigger[i] || !note_q[i] || cnt[i]==0) begin
                        acc[i] <= signed'(32'(strike_level[i*8 +:8]) <<< SHIFT);
                        tgt[i] <= signed'(32'(strike_level[i*8 +:8]) <<< SHIFT);
                        cnt[i] <= slot_period[i*16 +:16]-1'b1;
                    end else begin acc[i]<='0;cnt[i]<=cnt[i]-1'b1;end
                end else if (note_on[i] && (retrigger[i] || !note_q[i])) begin
                    // 按下那一下：第 1 个锤击，从 0 开始线性上升
                    st[i]  <= X_ATT;
                    acc[i] <= '0;
                    tgt[i] <= signed'(32'(strike_level[i*8 +: 8]) <<< SHIFT);
                    cnt[i] <= 16'd1;
                    num[i] <= 4'd1;
                end else begin
                    case (st[i])
                        // ------------------------------------------------
                        X_IDLE: begin
                            acc[i] <= '0;
                            cnt[i] <= '0;
                            num[i] <= '0;
                        end
                        // ------------------------------------------------
                        // 线性上升：每采样加 target>>RISE_SH，共 PW_LEN 个采样
                        X_ATT: begin
                            acc[i] <= acc[i] + (tgt[i] >>> RISE_SH);
                            if (cnt[i] >= PW_LEN) begin
                                cnt[i] <= '0;
                                st[i]  <= X_DECAY;
                            end else begin
                                cnt[i] <= cnt[i] + 16'd1;
                            end
                        end
                        // ------------------------------------------------
                        // 指数尾巴：一直衰减，同时数 GAP_LEN 个采样
                        X_DECAY: begin
                            acc[i] <= acc[i] - decay_step(acc[i]);
                            if (!note_on[i]) begin
                                // 松开：这一串就结束了
                                st[i]  <= X_IDLE;
                                num[i] <= '0;
                                cnt[i] <= '0;
                            end else if (cnt[i] >= GAP_LEN) begin
                                cnt[i] <= '0;
                                if (more_pulse(num[i])) begin
                                    // 下一次锤击：目标按 0.7 递减，从 0 重新上升
                                    num[i] <= num[i] + 4'd1;
                                    tgt[i] <= taper(tgt[i]);
                                    acc[i] <= '0;
                                    st[i]  <= X_ATT;
                                end else begin
                                    st[i]  <= X_IDLE;
                                    num[i] <= '0;
                                    acc[i] <= '0;
                                end
                            end else begin
                                cnt[i] <= cnt[i] + 16'd1;
                            end
                        end
                        // ------------------------------------------------
                        default: st[i] <= X_IDLE;
                    endcase
                end
            end
        end
    end

endmodule
