`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// weight_loader：QSPI -> staging -> 系数块写口（占位：只走时序，不真的读 flash）
// -----------------------------------------------------------------------------
module weight_loader #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 48,
    parameter logic [23:0] LOAD_CYCLES = 24'd200_000   // 占位：假装加载耗时
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic [3:0]                  inst,           // 乐器号（决定 flash 偏移）
    input  logic                        start,
    output logic                        busy,
    output logic                        done,           // 单拍

    // 统一的写口：一个使能 + 一个地址空间
    //   地址 [0, SLOTS*N_MODES)              -> 系数表
    //   地址 [SLOTS*N_MODES, 2*SLOTS*N_MODES) -> 调制参数表
    // 数据仍是两条总线（系数记录 7x32、参数记录 5x32，载荷不同）
    output logic                                    ld_we,
    output logic [$clog2(2*SLOTS*N_MODES)-1:0]      ld_addr,
    output modal_step_pkg::coeff_t                  ld_co,
    output router_pkg::mod_par_t                    ld_pm,

    // QSPI（占位：先引出来，后面对板子）
    output logic                        qspi_cs_n,
    output logic                        qspi_sck,
    output logic [3:0]                  qspi_dq_o,
    output logic                        qspi_dq_oe,
    input  logic [3:0]                  qspi_dq_i
);

    typedef enum logic [1:0] {W_IDLE, W_BUSY, W_DONE} wstate_e;
    wstate_e      st;
    logic [23:0]  cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= W_IDLE;
            cnt       <= '0;
            busy      <= 1'b0;
            done      <= 1'b0;
            ld_we     <= 1'b0;
            ld_addr   <= '0;
            ld_co     <= '0;
            ld_pm     <= '0;
            qspi_cs_n <= 1'b1;
            qspi_sck  <= 1'b0;
            qspi_dq_o <= '0;
            qspi_dq_oe<= 1'b0;
        end else begin
            done   <= 1'b0;
            ld_we  <= 1'b0;

            case (st)
                W_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy      <= 1'b1;
                        cnt       <= '0;
                        qspi_cs_n <= 1'b0;      // TODO: 真正发 QSPI 命令 + 收数据
                        st        <= W_BUSY;
                    end
                end
                W_BUSY: begin
                    if (cnt + 1 >= LOAD_CYCLES) begin
                        qspi_cs_n <= 1'b1;
                        st        <= W_DONE;
                    end else cnt <= cnt + 1'b1;
                end
                W_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= W_IDLE;
                end
                default: st <= W_IDLE;
            endcase
        end
    end

endmodule
