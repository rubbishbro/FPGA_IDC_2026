// -----------------------------------------------------------------------------
// eng1：队友引擎的占位（端口与 modal_engine7 完全一致）
//   现在只做"收 start、过 n_modes+8 拍、吐一个 y_valid=0"，让路由器的时序能跑通。
// -----------------------------------------------------------------------------
module eng1 #(
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
