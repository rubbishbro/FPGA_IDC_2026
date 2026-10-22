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
    // 占位加载器也真的写数据：否则综合器会把系数/参数阵列当成常量（全 0），
    // 整个引擎跟着被折叠，PnR 面积/Fmax 完全没有意义。
    logic [$clog2(2*SLOTS*N_MODES)-1:0] wa;
    logic [31:0]  lfsr;

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
            wa        <= '0;
            lfsr      <= 32'h1234_5678;
            qspi_cs_n <= 1'b1;
            qspi_sck  <= 1'b0;
            qspi_dq_o <= '0;
            qspi_dq_oe<= 1'b0;
        end else begin
            done   <= 1'b0;
            ld_we  <= 1'b0;
            lfsr   <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

            case (st)
                W_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy      <= 1'b1;
                        cnt       <= '0;
                        wa        <= '0;
                        qspi_cs_n <= 1'b0;      // TODO: 真正发 QSPI 命令 + 收数据
                        st        <= W_BUSY;
                    end
                end
                W_BUSY: begin
                    // 每个周期写一条记录：地址低半区写系数表、高半区写参数表
                    // （真实实现是 QSPI 收数据后按同样的地址空间写）
                    ld_we   <= 1'b1;
                    ld_addr <= wa;
                    ld_co.a11 <= lfsr;
                    ld_co.a12 <= {lfsr[4:0],  lfsr[31:5]};
                    ld_co.a21 <= {lfsr[8:0],  lfsr[31:9]};
                    ld_co.a22 <= {lfsr[12:0], lfsr[31:13]};
                    ld_co.gq  <= {lfsr[16:0], lfsr[31:17]};
                    ld_co.gv  <= {lfsr[20:0], lfsr[31:21]};
                    ld_co.wo  <= {lfsr[24:0], lfsr[31:25]};
                    ld_pm.c0     <= {lfsr[3:0],  lfsr[31:4]};
                    ld_pm.s0     <= {lfsr[7:0],  lfsr[31:8]};
                    ld_pm.gam    <= {lfsr[11:0], lfsr[31:12]};
                    ld_pm.theta0 <= {lfsr[15:0], lfsr[31:16]};
                    ld_pm.g      <= {lfsr[19:0], lfsr[31:20]};
                    if (wa + 1'b1 == 2*SLOTS*N_MODES) begin
                        qspi_cs_n <= 1'b1;
                        st        <= W_DONE;
                    end else wa <= wa + 1'b1;
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
