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
//   x / y1 / y2  Q2.30 signed 32
//
// 结构照 eng0：三个乘法器**并行**（G*x、a1*y1、a2*y2），先乘、下一拍再移位。
// 存储复用 router 的阵列：ca_a11=G、ca_a12=a1、ca_a21=a2、q_ram=y1、v_ram=y2。
// -----------------------------------------------------------------------------
module eng1 #(
    parameter int N_MODES = 48,
    parameter int X_DEPTH = 64
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
    output logic [$clog2(X_DEPTH)-1:0]           x_addr,
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

    typedef enum logic [2:0] { S_IDLE, S_RD, S_MUL, S_RND, S_WB, S_DONE } est_e;
    est_e st;

    logic [IW-1:0] mi, mi_q, nmod_lat;

    logic signed [63:0] p_g, p_a1, p_a2;
    logic signed [31:0] y1_cur, y2_cur, y_new;
    logic signed [63:0] acc_q;
    logic signed [63:0] y_acc;
    logic               st_zero_lat, first_done;

    // ---- 三个并行乘法（操作数在 S_MUL 这一拍都有效）----
    wire signed [63:0] x_ext  = {{32{x_data[31]}}, x_data};
    wire signed [63:0] y1_ext = {{32{y1_cur[31]}}, y1_cur};
    wire signed [63:0] y2_ext = {{32{y2_cur[31]}}, y2_cur};

    wire signed [63:0] mul_g  = mul64(x_ext,  {{38{co_data.a11[25]}}, co_data.a11[25:0]});
    wire signed [63:0] mul_a1 = mul64(y1_ext, {{38{co_data.a12[21]}}, co_data.a12[21:0], 4'b0});
    wire signed [63:0] mul_a2 = mul64(y2_ext, {6'b0, co_data.a21[23:0], 4'b0});

    // ---- 舍入 + 饱和（S_RND 的下一拍用它）----
    wire signed [63:0] acc_w = acc_q;
    wire signed [63:0] y_shr = (acc_w + ROUND) >>> 24;
    wire signed [31:0] y_clp = (y_shr > YMAX) ? 32'sh7FFF_FFFF :
                               (y_shr < YMIN) ? 32'sh8000_0000 : 32'(y_shr);

    assign co_re   = (st == S_RD);
    assign co_addr = mi;
    assign st_re   = (st == S_RD);
    assign st_addr = mi;
    assign x_re    = (st == S_RD);
    assign x_addr  = '0;

    assign st_we         = (st == S_WB);
    assign st_waddr      = mi_q;
    assign st_q_wdata    = y_new;
    assign st_qdot_wdata = y1_cur;

    assign y_valid = (st == S_DONE);
    assign y_data  = YW'(y_acc);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            mi         <= '0;
            mi_q       <= '0;
            nmod_lat   <= '0;
            p_g        <= '0;
            p_a1       <= '0;
            p_a2       <= '0;
            y1_cur     <= '0;
            y2_cur     <= '0;
            y_new      <= '0;
            acc_q      <= '0;
            y_acc      <= '0;
            st_zero_lat<= 1'b0;
            first_done <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    y_acc <= '0;
                    if (start) begin
                        mi          <= '0;
                        nmod_lat    <= n_modes[IW-1:0];
                        st_zero_lat <= st_zero;
                        first_done  <= 1'b0;
                        st          <= S_RD;
                    end
                end

                // 给地址；状态在下一拍有效
                S_RD: st <= S_MUL;

                // 三个乘法（并行）
                S_MUL: begin
                    p_g    <= mul_g;
                    p_a1   <= mul_a1;
                    p_a2   <= mul_a2;
                    y1_cur <= (st_zero_lat && !first_done) ? 32'sd0 : st_q;
                    y2_cur <= (st_zero_lat && !first_done) ? 32'sd0 : st_qdot;
                    mi_q   <= mi;
                    first_done <= 1'b1;
                    st     <= S_RND;
                end

                // 先乘后移：这一拍只做加减 + 寄存器
                S_RND: begin
                    acc_q <= p_g - p_a1 - p_a2;
                    st    <= S_WB;
                end

                // 移位 + 饱和 + 写状态 + 累加
                S_WB: begin
                    y_new <= y_clp;
                    y_acc <= y_acc + 64'(y_clp);
                    if (mi_q + 1'b1 >= nmod_lat) st <= S_DONE;
                    else begin
                        mi <= mi_q + 1'b1;
                        st <= S_RD;
                    end
                end

                S_DONE: st <= S_IDLE;

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
