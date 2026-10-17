// -----------------------------------------------------------------------------
// top_ram.sv -- 方案 B 的顶层：modal_bank_ram（系数/状态/激励/结果全在 bank 内）
//
// 端口与 top_seq.sv **完全一致**，所以两次综合的差值就是"存储与控制放在哪一侧"的代价：
//   co_we/co_addr/co_sel/co_wdata : 窄口装载系数（7 次 32 位写装一个模态）
//   x_valid/x_data                : 每个采样给一个激励值（写进 bank 的激励 RAM 再启动作业）
//   y_valid/y_data                : 每个采样输出 Σ wo·q（读 bank 的结果 RAM）
//
// 本顶层等价于"每采样一个 n_samples=1 的作业"（10N+2 拍/采样，N=48 时 482 拍）。
// 真实系统更可能用块处理（n_samples>1）降低 start/done 频率，但资源对比要用同样的
// 逐采样边界才公平。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module top_ram #(
    parameter int N_MODES = 32
) (
    input  logic                                 clk,
    input  logic                                 rst_n,

    input  logic                                 co_we,
    input  logic [$clog2(N_MODES)-1:0]           co_addr,
    input  logic [2:0]                           co_sel,
    input  logic [31:0]                          co_wdata,

    input  logic                                 x_valid,
    input  logic signed [modal_step_pkg::XW-1:0] x_data,
    output logic                                 y_valid,
    output logic signed [modal_step_pkg::YW-1:0] y_data
);

    import modal_step_pkg::*;

    localparam int IW = $clog2(N_MODES);
    localparam int JW = 1;                    // 每采样一个作业

    // ---- 窄口 -> coeff_t --------------------------------------------------
    logic          ld_we;
    logic [IW-1:0] ld_addr;
    coeff_t        ld_data;

    coeff_loader #(.N_MODES(N_MODES)) u_ld (
        .clk(clk), .rst_n(rst_n),
        .we(co_we), .addr(co_addr), .sel(co_sel), .wdata(co_wdata),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data)
    );

    // ---- bank ------------------------------------------------------------
    logic                 bank_start;
    logic                 bank_done;
    logic                 bank_busy;
    logic                 x_we;
    logic [JW-1:0]        x_addr;
    logic signed [XW-1:0] x_wdata;
    logic                 rd_en;
    logic [JW-1:0]        rd_addr;
    logic signed [YW-1:0] rd_data;
    logic                 rd_valid;

    modal_bank_ram #(.N_MODES(N_MODES), .X_DEPTH(2), .DEBUG_PORT(1'b0)) u_bank (
        .clk(clk), .rst_n(rst_n),
        .co_we(ld_we), .co_addr(ld_addr), .co_data(ld_data),
        .st_we(1'b0), .st_addr('0), .st_q('0), .st_v('0),
        .x_we(x_we), .x_addr(x_addr), .x_data(x_wdata),
        .start(bank_start),
        .n_samples(1'b1),
        .n_modes(N_MODES[$clog2(N_MODES+1)-1:0]),
        .done(bank_done), .busy(bank_busy),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .st_rd_en(1'b0), .st_rd_addr('0), .st_rd_sel(1'b0),
        .st_rd_data(), .st_rd_valid()
    );

    // ---- 逐采样控制：写 x -> start -> 等 done -> 读结果 -------------------
    typedef enum logic [2:0] { T_IDLE, T_WR, T_GO, T_WAIT, T_RD, T_OUT } tstate_t;
    tstate_t              st;
    logic signed [XW-1:0] x_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= T_IDLE;
            bank_start <= 1'b0;
            x_we       <= 1'b0;
            x_addr     <= '0;
            x_wdata    <= '0;
            rd_en      <= 1'b0;
            rd_addr    <= '0;
            y_valid    <= 1'b0;
            y_data     <= '0;
            x_lat      <= '0;
        end else begin
            bank_start <= 1'b0;
            y_valid    <= 1'b0;

            case (st)
                T_IDLE: begin
                    x_we  <= 1'b0;
                    rd_en <= 1'b0;
                    if (x_valid && !bank_busy) begin
                        x_lat <= x_data;
                        st    <= T_WR;
                    end
                end

                T_WR: begin
                    x_we    <= 1'b1;
                    x_addr  <= '0;
                    x_wdata <= x_lat;
                    st      <= T_GO;
                end

                T_GO: begin
                    x_we       <= 1'b0;
                    bank_start <= 1'b1;
                    st         <= T_WAIT;
                end

                T_WAIT: begin
                    if (bank_done) begin
                        rd_en   <= 1'b1;
                        rd_addr <= '0;
                        st      <= T_RD;
                    end
                end

                T_RD: begin
                    rd_en <= 1'b0;
                    st    <= T_OUT;
                end

                T_OUT: begin
                    y_data  <= rd_data;
                    y_valid <= 1'b1;
                    st      <= T_IDLE;
                end

                default: st <= T_IDLE;
            endcase
        end
    end

endmodule
