// -----------------------------------------------------------------------------
// router_stubs.sv -- 路由器周围模块的占位实现（先搭结构，后填内容）
//
//   force_pre     : fmap(16x8) -> xmap(16x32)，一次处理整张 fmap
//   weight_loader : QSPI flash -> 系数块写口
//   eng_alt       : 队友的引擎，端口与 modal_engine7 完全一致
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// force_pre：把整张 fmap 变成整张 xmap。
//   * 不需要声部号 —— 路由器负责把 xmap 的第 i 项分给第 i 个槽
//   * 不需要 smp_idx —— 内部按 CLK_HZ/SR_HZ 自己分频计数
//   * 现在是恒等 + 定标（TODO: 换成真正的力预处理，并按乐器号路由到多个模块）
// -----------------------------------------------------------------------------
module force_pre #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SHIFT  = 20            // 8 位力值 -> 32 位定点的左移量（待定）
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  pad_driver_pkg::mat4x4       fmap,
    output logic signed [31:0]          xmap [0:15],
    output logic                        xmap_valid     // 每采样一个脉冲
);

    localparam int DIV = CLK_HZ / SR_HZ;

    logic [$clog2(DIV+1)-1:0] cnt;
    logic                     tick;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= '0;
            tick <= 1'b0;
        end else begin
            tick <= 1'b0;
            if (cnt + 1 >= DIV[$clog2(DIV+1)-1:0]) begin
                cnt  <= '0;
                tick <= 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

    // TODO: 按乐器号选择不同的预处理（多路 mux），现在恒等
    always_ff @(posedge clk) begin
        if (tick) begin
            for (int i = 0; i < 16; i++) begin
                xmap[i] <= signed'(32'(fmap.flat_d[i].val) <<< SHIFT);
            end
        end
    end

    assign xmap_valid = tick;

endmodule


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

    // 系数块写口（真实实现要逐个字写进去）
    output logic                        co_we,
    output logic [$clog2(SLOTS*N_MODES)-1:0] co_addr,
    output modal_step_pkg::coeff_t      co_data,

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
            co_we     <= 1'b0;
            co_addr   <= '0;
            co_data   <= '0;
            qspi_cs_n <= 1'b1;
            qspi_sck  <= 1'b0;
            qspi_dq_o <= '0;
            qspi_dq_oe<= 1'b0;
        end else begin
            done   <= 1'b0;
            co_we  <= 1'b0;

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


// -----------------------------------------------------------------------------
// eng_alt：队友引擎的占位（端口与 modal_engine7 完全一致）
//   现在只做"收 start、过 n_modes+8 拍、吐一个 y_valid=0"，让路由器的时序能跑通。
// -----------------------------------------------------------------------------
module eng_alt #(
    parameter int N_MODES = 48,
    parameter int X_DEPTH = 256
) (
    input  logic                                 clk,
    input  logic                                 rst_n,

    input  logic                                 start,
    input  logic                                 st_zero,
    input  logic [$clog2(N_MODES+1)-1:0]         n_modes,
    output logic                                 y_valid,
    output logic signed [63:0]                   y_data,

    output logic                                 co_re,
    output logic [$clog2(N_MODES)-1:0]           co_addr,
    input  modal_step_pkg::coeff_t               co_data,

    output logic                                 st_re,
    output logic [$clog2(N_MODES)-1:0]           st_addr,
    input  logic signed [31:0]                   st_q,
    input  logic signed [31:0]                   st_qdot,

    output logic                                 st_we,
    output logic [$clog2(N_MODES)-1:0]           st_waddr,
    output logic signed [31:0]                   st_q_wdata,
    output logic signed [31:0]                   st_qdot_wdata,

    output logic                                 x_re,
    output logic [$clog2(X_DEPTH)-1:0]           x_addr,
    input  logic signed [31:0]                   x_data
);

    logic        busy;
    logic [15:0] cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy    <= 1'b0;
            cnt     <= '0;
            y_valid <= 1'b0;
            y_data  <= '0;
        end else begin
            y_valid <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                cnt  <= '0;
            end else if (busy) begin
                if (cnt >= 16'(n_modes) + 16'd8) begin
                    busy    <= 1'b0;
                    y_valid <= 1'b1;
                    y_data  <= '0;              // TODO: 真实引擎的输出
                end else cnt <= cnt + 1'b1;
            end
        end
    end

    // 占位：不访问存储
    assign co_re = 1'b0;   assign co_addr = '0;
    assign st_re = 1'b0;   assign st_addr = '0;
    assign st_we = 1'b0;   assign st_waddr = '0;
    assign st_q_wdata = '0; assign st_qdot_wdata = '0;
    assign x_re = 1'b0;    assign x_addr = '0;

endmodule
