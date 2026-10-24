`timescale 1ns/1ps
// =============================================================================
// 激励生成：整张 fmap -> 整张 xmap（每个 smp_tick 一个样本）
//
// 每个声部一个小状态机，**只看 note_on（按下电平，带滞回）**：
//   按下上升沿 -> 开始一串脉冲：高 PW_LEN 个采样 -> 低 GAP_LEN 个采样 -> 再来一个...
//   单次触发最多 N_PULSE+1 个脉冲；N_PULSE=7 表示"按住期间一直发"
//   松开 -> 当前脉冲走完就停
//   脉冲高度 = 当时的 fmap 压力 << SHIFT（跟着压力走）
//
// GAP_LEN = 0 表示没有低电平间隔（连续给力，用来做持续激励的乐器）。
//
// 参数全部由上级 router（exc_router）按乐器填：SHIFT / PW_LEN / GAP_LEN / N_PULSE。
// clear：换乐器时把 16 个声部的状态机全清（router 给一拍）。
//
// 这版把原来的 pulse_single / pulse_train 合成一个：单次拨弦就是 N_PULSE=0、
// 持续力就是 N_PULSE=7 + GAP_LEN=0。
// =============================================================================
module excitation_gen #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        smp_tick,
    input  logic [5:0]                  SHIFT,      // 8 位力值 -> 32 位定点的左移量
    input  logic [15:0]                 PW_LEN,     // 脉冲宽度（采样数，>=1）
    input  logic [15:0]                 GAP_LEN,    // 脉冲间距（采样数，0 = 不留低电平）
    input  logic [2:0]                  N_PULSE,    // 0..6 -> 最多 N+1 个；7 -> 按住期间无限
    input  logic                        clear,      // 换乐器：清全部声部状态
    input  pad_driver_pkg::mat4x4       fmap,
    input  logic [SLOTS-1:0]            note_on,    // 按下电平（router 的滞回门控）
    output logic signed [15:0][31:0]    xmap,       // 打包：xmap[i] 取第 i 个声部
    output logic                        xmap_valid
);

    typedef enum logic [1:0] { X_IDLE, X_HIGH, X_GAP } xs_e;

    xs_e              st  [0:SLOTS-1];
    logic [15:0]      cnt [0:SLOTS-1];      // 本状态已过的采样数
    logic [3:0]       num [0:SLOTS-1];      // 本串第几个脉冲（从 1 起）
    logic [SLOTS-1:0] note_q;


    // 上一拍的门控，用来取沿
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        note_q <= '0;
        else if (smp_tick) note_q <= note_on;
    end

    // 这个脉冲之后还能不能接着发
    function automatic logic more_pulse(input logic [3:0] n);
        more_pulse = (N_PULSE == 3'd7) || (n <= 4'(N_PULSE));
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) begin
                st[i]   <= X_IDLE;
                cnt[i]  <= '0;
                num[i]  <= '0;
                xmap[i] <= '0;
            end
        end else if (smp_tick) begin
            for (int i = 0; i < SLOTS; i++) begin
                if (clear) begin
                    st[i]   <= X_IDLE;
                    cnt[i]  <= '0;
                    num[i]  <= '0;
                    xmap[i] <= '0;
                end else if (note_on[i] && !note_q[i]) begin
                    // 按下那一下：开始第 1 个脉冲（这一拍本身就算脉冲的第 1 个采样）
                    st[i]   <= X_HIGH;
                    cnt[i]  <= 16'd1;
                    num[i]  <= 4'd1;
                    xmap[i] <= signed'(32'(fmap.flat_d[i].val) <<< SHIFT);
                end else begin
                    case (st[i])
                        // ------------------------------------------------
                        X_IDLE: begin
                            xmap[i] <= '0;
                            cnt[i]  <= '0;
                            num[i]  <= '0;
                        end
                        // ------------------------------------------------
                        // cnt = 本脉冲已经出过几个采样（起音那一拍算第 1 个），
                        // 到了 PW_LEN 就收尾：收尾那一拍不再出高电平
                        X_HIGH: begin
                            if (cnt[i] >= PW_LEN) begin
                                cnt[i] <= '0;
                                if (!note_on[i]) begin
                                    // 松开了：脉冲到此为止
                                    st[i]   <= X_IDLE;
                                    num[i]  <= '0;
                                    xmap[i] <= '0;
                                end else if (GAP_LEN == 16'd0) begin
                                    // 没有间距：续下一个脉冲（连续高，不出低电平）
                                    if (more_pulse(num[i])) begin
                                        num[i]  <= num[i] + 1'b1;
                                        xmap[i] <= signed'(32'(fmap.flat_d[i].val) <<< SHIFT);
                                    end else begin
                                        st[i]   <= X_IDLE;
                                        num[i]  <= '0;
                                        xmap[i] <= '0;
                                    end
                                end else begin
                                    // 这一拍就算间距的第 1 个采样（省一拍）
                                    st[i]   <= X_GAP;
                                    cnt[i]  <= 16'd1;
                                    xmap[i] <= '0;
                                end
                            end else begin
                                xmap[i] <= signed'(32'(fmap.flat_d[i].val) <<< SHIFT);
                                cnt[i]  <= cnt[i] + 16'd1;
                            end
                        end
                        // ------------------------------------------------
                        // cnt = 间距里已经出过几个低电平采样
                        X_GAP: begin
                            if (!note_on[i]) begin
                                // 松开：剩下的脉冲取消
                                xmap[i] <= '0;
                                st[i]   <= X_IDLE;
                                num[i]  <= '0;
                            end else if (cnt[i] >= GAP_LEN) begin
                                if (more_pulse(num[i])) begin
                                    // 这一拍直接开始下一个脉冲（别再空一拍低电平）
                                    num[i]  <= num[i] + 1'b1;
                                    st[i]   <= X_HIGH;
                                    cnt[i]  <= 16'd1;
                                    xmap[i] <= signed'(32'(fmap.flat_d[i].val) <<< SHIFT);
                                end else begin
                                    st[i]   <= X_IDLE;
                                    num[i]  <= '0;
                                    cnt[i]  <= '0;
                                    xmap[i] <= '0;
                                end
                            end else begin
                                xmap[i] <= '0;
                                cnt[i]  <= cnt[i] + 16'd1;
                            end
                        end
                        // ------------------------------------------------
                        default: st[i] <= X_IDLE;
                    endcase
                end
            end
        end
    end

    assign xmap_valid = smp_tick;

endmodule
