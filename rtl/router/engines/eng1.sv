// -----------------------------------------------------------------------------
// eng1：ABC 谐振器引擎（端口与 eng0 完全一致：一次 start = 递推一个采样）
//
// 递推核（队友 abc_lane_core 的算术契约，逐位一致）：
//     acc  = G*x - (a1<<4)*y1 - a2*y2
//     ynew = clamp((acc + 2^23) >>> 24, -2^31, 2^31-1)
//     y2'  = y1 ,  y1' = ynew
//
//   G   Q2.24 signed   （存在 co_data.a11，低 26 位有效）
//   a1  Q2.20 signed   （存在 co_data.a12，<<4 后为 Q2.24）
//   a2  UQ0.24 unsigned（存在 co_data.a21，零扩展到 Q2.24）
//   x / y1 / y2 signed 32，沿用激励的二进制小数位（当前 router 为 Q24）
//
// 五级跨模态流水：R 同步读 -> M 三乘法 -> S 加减 -> N 舍入饱和 -> W 写回/累加。
// 每拍送入一个模态；地址和旧 y1 随 valid 一起前进，排空后才报告 y_valid。
// 存储复用 router 的阵列：ca_a11=G、ca_a12=a1、ca_a21=a2、q_ram=y1、v_ram=y2。
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
    localparam logic signed [63:0] YMIN  = -64'sd2147483648;
    localparam logic signed [63:0] YMAX  =  64'sd2147483647;
    localparam logic signed [63:0] ROUND =  64'sd1 <<< 23;    // 2^23

    function automatic logic signed [63:0] mul64(
        input logic signed [63:0] a,
        input logic signed [63:0] b
    );
        mul64 = a * b;
    endfunction

    typedef enum logic [2:0] {S_IDLE, S_X, S_SETUP, S_RUN, S_DONE} state_t;
    state_t state;
    logic [IW:0] issued, nmod_lat;
    logic zero_job;
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

    assign co_re = state == S_RUN && issued < nmod_lat;
    assign co_addr = issued[IW-1:0];
    assign st_re = co_re;
    assign st_addr = co_addr;
    assign x_re = state == S_X;
    assign st_we = w_valid;
    assign st_waddr = w_addr;
    assign st_q_wdata = y_new;
    assign st_qdot_wdata = w_old_y1;
    assign y_valid = state == S_DONE;
    assign y_data = y_acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; issued<='0; nmod_lat<='0; zero_job<=0; x_lat<='0;
            m_valid<=0; s_valid<=0; n_valid<=0; w_valid<=0;
            m_addr<='0; s_addr<='0; n_addr<='0; w_addr<='0;
            s_old_y1<='0; n_old_y1<='0; w_old_y1<='0;
            p_g<='0; p_a1<='0; p_a2<='0; acc_q<='0; y_new<='0; y_acc<='0;
        end else begin
            // R: external synchronous RAM samples these addresses on this edge.
            m_valid <= co_re;
            s_valid <= m_valid;
            n_valid <= s_valid;
            w_valid <= n_valid;
            if (co_re) begin
                m_addr <= co_addr;
                issued <= issued + 1'b1;
            end
            // M: returned RAM data, NOT a previous mode's state register.
            if (m_valid) begin
                p_g <= mul64(x_ext, {{38{co_data.a11[25]}},co_data.a11[25:0]});
                p_a1 <= mul64(y1_ext, {{38{co_data.a12[21]}},co_data.a12[21:0],4'b0});
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
                if ({1'b0,w_addr}+1'b1 >= nmod_lat) state <= S_DONE;
            end
            case (state)
                S_IDLE: if (start) begin
                    issued<='0;
                    nmod_lat <= n_modes > N_MODES ? (IW+1)'(N_MODES) : (IW+1)'(n_modes);
                    zero_job<=st_zero; y_acc<='0;
                    state <= n_modes=='0 ? S_DONE : S_X;
                end
                S_X: state<=S_SETUP;
                S_SETUP: begin x_lat<=x_data; state<=S_RUN; end
                S_DONE: state<=S_IDLE;
                default: ;
            endcase
        end
    end
endmodule
