// -----------------------------------------------------------------------------
// eng1：ABC 谐振器 + 可选鼓噪声；一次 start = 递推一个采样。
//
// 递推核（router Q2.24 系数合同；旧 abc_lane_core 仍用 Q2.20 a1）：
//     acc  = G*x - a1*y1 - a2*y2
//     ynew = clamp((acc + 2^23) >>> 24, -2^31, 2^31-1)
//     y2'  = y1 ,  y1' = ynew
//
//   G   Q2.24 signed   （存在 co_data.a11，低 26 位有效）
//   a1  Q2.24 signed 26（存在 co_data.a12，低 26 位有效）
//   a2  UQ0.24 unsigned（存在 co_data.a21，零扩展到 Q2.24）
//   x / y1 / y2 signed 32，沿用激励的二进制小数位（当前 router 为 Q24）
//
// 五级跨模态流水：R 同步读 -> M 三乘法 -> S 加减 -> N 舍入饱和 -> W 写回/累加。
// 每拍送入一个模态；地址和旧 y1 随 valid 一起前进，排空后才报告 y_valid。
// 存储复用 router 的阵列：ca_a11=G、ca_a12=a1、ca_a21=a2、q_ram=y1、v_ram=y2。
//
// 数据驱动鼓噪声合同：n_modes<=48时全部按原ABC计算；n_modes>48时
// 0..47为ABC，48/49、50/51等每两槽为噪声支路。不增加任何输入输出。
// n_modes表示总有效槽数（鼓组固定50/52），开关无需改变它；物理深度仍为64。
// 注意：>48槽的新布局不再表示49..64个普通ABC模态；现用普通ENG1资源为48模态。
// 主槽co字段：a11=LFSR seed(raw u32)，a12=包络初值(UQ24,<=1)，
// a21=每采样衰减(UQ24,<=1)，a22=低截止alpha(UQ24)，
// gq=高截止alpha(UQ24,0<=低<=高<=1)，gv=非负增益(s32 Q16)。
// seed=0即禁用，非0即启用；wo与扩展槽全部co字段保留，不要求tag/enable位。
// 主槽q/v=LFSR位图/包络；扩展槽q/v=低/高截止低通状态(s32 Q24)。
// st_zero始终优先清理并静音。之后运行LFSR=0且现有x_data>0时自动起音：
// 装载非零seed、包络初值*min(x_data,1.0 Q24)，滤波历史清零。
// x<=0不会从静音启动；运行后x变化不重复触发/不改变尾音力度。
// 重击须经现有st_zero重新准备；起音首帧x可能为0，可等后续正激励启动。
// 维护清理/重载期间上层须让x_data=0，否则后续正激励仍会被解释为新击打。
// 全0 Flash记录=禁用：seed=0、参数非法、无正激励的零运行态或st_zero
// 都直接输出0并清两槽运行态；不能将LFSR=0直接映射成持续-1。
// 改Flash参数不自动清RAM；重载须先清理旧范围，再演奏或缩小n_modes。
// 每采样LFSR bit0映射+/-1；右移Galois mask=32'h80200003；
// 两低通之差整形后乘旧包络/增益，包络衰减和LFSR推进后写回。
// 单独末尾残槽清零不发声。噪声与ABC分时复用原1R1W端口，不增加RAM读口。
// 此整形只用于噪声，公共body_router腔体和混响仍在引擎外。
// -----------------------------------------------------------------------------
module eng1 #(
    parameter int N_MODES = 64
) (
    input  logic                                 clk,
    input  logic                                 rst_n,

    input  logic                                 start,
    input  logic                                 st_zero,     // 1 = 本作业先清零状态
    input  logic [$clog2(N_MODES+1)-1:0]         n_modes,

    output logic                                 co_re,
    output logic [$clog2(N_MODES)-1:0]           co_addr,
    input  modal_step_pkg::coeff_t               co_data,

    output logic                                 st_re,
    output logic [$clog2(N_MODES)-1:0]           st_addr,
    input  logic signed [31:0]                   st_q,        // y1
    input  logic signed [31:0]                   st_qdot,     // y2

    output logic                                 st_we,
    output logic [$clog2(N_MODES)-1:0]           st_waddr,
    output logic signed [31:0]                   st_q_wdata,  // y1'
    output logic signed [31:0]                   st_qdot_wdata, // y2' = y1

    output logic                                 x_re,
    input  logic signed [31:0]                   x_data,

    output logic                                 y_valid,
    output logic signed [63:0]                   y_data
);

    import modal_step_pkg::*;

    localparam int IW = $clog2(N_MODES);
    localparam int NOISE_FIRST = 48;
    localparam logic signed [63:0] YMIN  = -64'sd2147483648;
    localparam logic signed [63:0] YMAX  =  64'sd2147483647;
    localparam logic signed [63:0] ROUND =  64'sd1 <<< 23;    // 2^23

    function automatic logic signed [63:0] mul64(
        input logic signed [63:0] a,
        input logic signed [63:0] b
    );
        mul64 = a * b;
    endfunction

    typedef enum logic [4:0] {
        S_IDLE, S_X, S_SETUP, S_RUN, S_DONE,
        N_READ0, N_WAIT0, N_READ1, N_WAIT1, N_FILTER, N_ENV,
        N_GAIN, N_WRITE0, N_WRITE1, N_NEXT
    } state_t;
    state_t state;
    logic [IW:0] issued, nmod_lat;
    logic zero_job;
    logic noise_job, noise_restart;
    logic [IW:0] total_lat, noise_addr;
    logic noise_disabled;
    logic [31:0] noise_lfsr, noise_env, noise_decay, alpha_lo, alpha_hi;
    logic signed [31:0] noise_gain, noise_lo, noise_hi, noise_shaped, noise_out;
    wire noise_pair = noise_addr + 1'b1 < total_lat;
    wire noise_read = state == N_READ0 || state == N_READ1;
    wire noise_write = state == N_WRITE0 || state == N_WRITE1;
    wire [31:0] lfsr_next = (noise_lfsr >> 1) ^
        (noise_lfsr[0] ? 32'h80200003 : 32'd0);
    wire signed [63:0] noise_bit = noise_lfsr[0] ? 64'sd16777216 : -64'sd16777216;

    function automatic logic signed [31:0] clamp32(input logic signed [63:0] value);
        return value > YMAX ? 32'sh7fffffff :
               value < YMIN ? 32'sh80000000 : 32'(value);
    endfunction
    logic signed [31:0] x_lat;
    logic signed [63:0] p_g, p_a1, p_a2, acc_q, y_acc;
    logic signed [31:0] y_new;
    logic m_valid, s_valid, n_valid, w_valid;
    logic [IW-1:0] m_addr, s_addr, n_addr, w_addr;
    logic signed [31:0] s_old_y1, n_old_y1, w_old_y1;
    wire signed [31:0] y1_eff = zero_job ? 32'sd0 : st_q;
    wire signed [31:0] y2_eff = zero_job ? 32'sd0 : st_qdot;
    wire signed [63:0] x_ext = {{32{x_lat[31]}}, x_lat};
    wire signed [63:0] y1_ext = {{32{y1_eff[31]}}, y1_eff};
    wire signed [63:0] y2_ext = {{32{y2_eff[31]}}, y2_eff};
    wire signed [63:0] y_shr = (acc_q + ROUND) >>> 24;
    wire signed [31:0] y_clp = (y_shr > YMAX) ? 32'sh7fffffff :
                               (y_shr < YMIN) ? 32'sh80000000 : 32'(y_shr);

    assign co_re = (state == S_RUN && issued < nmod_lat) || noise_read;
    assign co_addr = noise_read ? IW'(noise_addr + (state == N_READ1)) : issued[IW-1:0];
    assign st_re = co_re;
    assign st_addr = co_addr;
    assign x_re = state == S_X;
    assign st_we = w_valid || noise_write;
    assign st_waddr = noise_write ? IW'(noise_addr + (state == N_WRITE1)) : w_addr;
    assign st_q_wdata = state == N_WRITE0 ? (noise_disabled ? 32'd0 : lfsr_next) :
                        state == N_WRITE1 ? noise_lo : y_new;
    assign st_qdot_wdata = state == N_WRITE0 ?
        (noise_disabled ? 32'd0 : 32'((mul64({32'd0,noise_env}, {32'd0,noise_decay}) + ROUND) >>> 24)) :
        state == N_WRITE1 ? noise_hi : w_old_y1;
    assign y_valid = state == S_DONE;
    assign y_data = y_acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; issued<='0; nmod_lat<='0; zero_job<=0; x_lat<='0;
            noise_job<=0;noise_restart<=0;total_lat<=0;noise_addr<=0;
            noise_disabled<=1;noise_lfsr<=0;noise_env<=0;noise_decay<=0;
            alpha_lo<=0;alpha_hi<=0;noise_gain<=0;noise_lo<=0;noise_hi<=0;
            noise_shaped<=0;noise_out<=0;
            m_valid<=0; s_valid<=0; n_valid<=0; w_valid<=0;
            m_addr<='0; s_addr<='0; n_addr<='0; w_addr<='0;
            s_old_y1<='0; n_old_y1<='0; w_old_y1<='0;
            p_g<='0; p_a1<='0; p_a2<='0; acc_q<='0; y_new<='0; y_acc<='0;
        end else begin
            // R: external synchronous RAM samples these addresses on this edge.
            m_valid <= co_re && state == S_RUN;
            s_valid <= m_valid;
            n_valid <= s_valid;
            w_valid <= n_valid;
            if (co_re && state == S_RUN) begin
                m_addr <= co_addr;
                issued <= issued + 1'b1;
            end
            // M: returned RAM data, NOT a previous mode's state register.
            if (m_valid) begin
                p_g <= mul64(x_ext, {{38{co_data.a11[25]}},co_data.a11[25:0]});
                p_a1 <= mul64(y1_ext, {{38{co_data.a12[25]}},co_data.a12[25:0]});
                p_a2 <= mul64(y2_ext, {40'b0,co_data.a21[23:0]});
                s_addr <= m_addr;
                s_old_y1 <= y1_eff;
            end
            // S: retain the original signed 64-bit wrap before rounding.
            if (s_valid) begin
                acc_q <= p_g - p_a1 - p_a2;
                n_addr <= s_addr;
                n_old_y1 <= s_old_y1;
            end
            // N: exactly the original positive-bias rounding and signed clamp.
            if (n_valid) begin
                y_new <= y_clp;
                w_addr <= n_addr;
                w_old_y1 <= n_old_y1;
            end
            // W: RAM and sum commit together. Last address is widened before +1.
            if (w_valid) begin
                y_acc <= y_acc + 64'(y_new);
                if ({1'b0,w_addr}+1'b1 >= nmod_lat)
                    begin
                        if (noise_job && total_lat > NOISE_FIRST) state <= N_READ0;
                        else state <= S_DONE;
                    end
            end
            case (state)
                S_IDLE: if (start) begin
                    issued<='0;
                    total_lat <= n_modes > N_MODES ? (IW+1)'(N_MODES) : (IW+1)'(n_modes);
                    nmod_lat <= n_modes > NOISE_FIRST ? (IW+1)'(NOISE_FIRST) :
                        (n_modes > N_MODES ? (IW+1)'(N_MODES) : (IW+1)'(n_modes));
                    // N_MODES<48 cannot contain noise records.
                    if (N_MODES < NOISE_FIRST) nmod_lat <=
                        n_modes > N_MODES ? (IW+1)'(N_MODES) : (IW+1)'(n_modes);
                    noise_job <= N_MODES > NOISE_FIRST;
                    noise_addr <= (IW+1)'(NOISE_FIRST);
                    zero_job<=st_zero; y_acc<='0;
                    if (n_modes=='0) state <= S_DONE; else state <= S_X;
                end
                S_X: state<=S_SETUP;
                S_SETUP: begin x_lat<=x_data; state<=S_RUN; end
                N_READ0: state <= N_WAIT0;
                N_WAIT0: begin
                    // Coefficients and state are synchronous RAM responses.
                    noise_disabled <= zero_job || !noise_pair ||
                        co_data.a11 == 0 ||
                        $unsigned(co_data.a12) > 32'd16777216 ||
                        $unsigned(co_data.a21) > 32'd16777216 ||
                        $unsigned(co_data.a22) > $unsigned(co_data.gq) ||
                        $unsigned(co_data.gq) > 32'd16777216 || co_data.gv <= 0 ||
                        (st_q == 0 && x_lat <= 0) ||
                        (st_q != 0 && $unsigned(st_qdot) > 32'd16777216);
                    noise_restart <= st_q == 0 && x_lat > 0;
                    noise_lfsr <= st_q == 0 ? co_data.a11 : st_q;
                    noise_env <= st_q == 0 ?
                        32'((mul64({32'd0,co_data.a12},
                            x_lat > 32'sd16777216 ? 64'sd16777216 : 64'(x_lat)) + ROUND) >>> 24) : st_qdot;
                    noise_decay <= co_data.a21;
                    alpha_lo <= co_data.a22; alpha_hi <= co_data.gq;
                    noise_gain <= co_data.gv;
                    noise_lo <= 0; noise_hi <= 0;
                    if (noise_pair) state <= N_READ1; else state <= N_FILTER;
                end
                N_READ1: state <= N_WAIT1;
                N_WAIT1: begin
                    noise_lo <= noise_restart ? 32'd0 : st_q;
                    noise_hi <= noise_restart ? 32'd0 : st_qdot;
                    state <= N_FILTER;
                end
                N_FILTER: begin
                    if (noise_disabled) begin noise_lo<=0; noise_hi<=0; end
                    else begin
                        noise_lo <= clamp32(64'(noise_lo) +
                            ((mul64(noise_bit - 64'(noise_lo), {32'd0,alpha_lo}) + ROUND) >>> 24));
                        noise_hi <= clamp32(64'(noise_hi) +
                            ((mul64(noise_bit - 64'(noise_hi), {32'd0,alpha_hi}) + ROUND) >>> 24));
                    end
                    state <= N_ENV;
                end
                N_ENV: begin
                    noise_shaped <= noise_disabled ? 32'd0 : clamp32(
                        (mul64(64'(noise_hi)-64'(noise_lo), {32'd0,noise_env}) + ROUND) >>> 24);
                    state <= N_GAIN;
                end
                N_GAIN: begin
                    noise_out <= noise_disabled ? 32'd0 : clamp32(
                        (mul64(64'(noise_shaped), 64'(noise_gain)) + 64'sd32768) >>> 16);
                    state <= N_WRITE0;
                end
                N_WRITE0: begin
                    y_acc <= y_acc + 64'(noise_out);
                    if (noise_pair) state <= N_WRITE1; else state <= N_NEXT;
                end
                N_WRITE1: state <= N_NEXT;
                N_NEXT: begin
                    noise_addr <= noise_addr + 2'd2;
                    if (noise_addr + 2'd2 < total_lat) state <= N_READ0; else state <= S_DONE;
                end
                S_DONE: state<=S_IDLE;
                default: ;
            endcase
        end
    end
endmodule
