// -----------------------------------------------------------------------------
// 系数调制器（揉弦）：按 aftertouch 压力调制系数表
//
//   端口约定（和 router 的接线）：
//     * p_*  ：调制参数表读口（每模态 c0 / s0 / gamma，全局 Q1.31 约定）
//     * co_* ：系数表"读名义值 + 写调制值"两个口
//     * alpha_q：频率比 α（Q1.31，1.0 = 1<<30 或 2^31？—— 待定，先按 Q1.31）
//
//   v0 只走流程：读出 → 原样写回（数学部分留 TODO），用来验证接线和时序。
// -----------------------------------------------------------------------------
module modulation0 #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 48,
    parameter int CYC_PER_MODE = 8        // 每模态占用的周期（先给个保守值）
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        start,        // 开始一轮调制
    input  logic [SLOTS-1:0]            active,       // 哪些声部在发声
    input  logic signed [31:0]          alpha_q,      // 频率比（Q1.31）
    output logic                        busy,
    output logic                        done,

    // 参数表读口
    output logic                        p_re,
    output logic [$clog2(SLOTS*N_MODES)-1:0] p_addr,
    input  logic signed [31:0]          p_c0,
    input  logic signed [31:0]          p_s0,
    input  logic signed [31:0]          p_g,         // gamma

    // 系数表：读名义值 + 写调制值
    output logic                        co_re,
    output logic                        co_we,
    output logic [$clog2(SLOTS*N_MODES)-1:0] co_addr,
    input  modal_step_pkg::coeff_t      co_data,
    output modal_step_pkg::coeff_t      co_wdata
);

    typedef enum logic [1:0] { M_IDLE, M_READ, M_WRITE, M_NEXT } mstate_e;
    mstate_e  st;
    logic [$clog2(SLOTS*N_MODES)-1:0] idx;
    logic [3:0]                       cyc;
    logic [SLOTS-1:0]                 act_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= M_IDLE;
            idx     <= '0;
            cyc     <= '0;
            busy    <= 1'b0;
            done    <= 1'b0;
            act_lat <= '0;
            p_re    <= 1'b0;
            co_re   <= 1'b0;
            co_we   <= 1'b0;
            p_addr  <= '0;
            co_addr <= '0;
            co_wdata<= '0;
        end else begin
            done   <= 1'b0;
            p_re   <= 1'b0;
            co_re  <= 1'b0;
            co_we  <= 1'b0;

            case (st)
                M_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy    <= 1'b1;
                        idx     <= '0;
                        cyc     <= '0;
                        act_lat <= active;
                        st      <= M_READ;
                    end
                end

                M_READ: begin
                    // 发读地址（参数表 + 系数表同一个索引）
                    p_addr  <= idx;
                    co_addr <= idx;
                    p_re    <= 1'b1;
                    co_re   <= 1'b1;
                    st      <= M_WRITE;
                end

                M_WRITE: begin
                    // TODO: 真正的线性近似（c0/s0/gamma/alpha 算 a11..a22）
                    //       v0 先原样写回，验证接线与时序
                    co_addr  <= idx;
                    co_wdata <= co_data;
                    co_we    <= 1'b1;
                    cyc      <= '0;
                    st       <= M_NEXT;
                end

                M_NEXT: begin
                    if (cyc + 1'b1 >= CYC_PER_MODE[3:0]) begin
                        if (idx + 1'b1 >= (SLOTS*N_MODES)) begin
                            done <= 1'b1;
                            busy <= 1'b0;
                            st   <= M_IDLE;
                        end else begin
                            idx <= idx + 1'b1;
                            st  <= M_READ;
                        end
                    end else cyc <= cyc + 1'b1;
                end

                default: st <= M_IDLE;
            endcase
        end
    end

endmodule
