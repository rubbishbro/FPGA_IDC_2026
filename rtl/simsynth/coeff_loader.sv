// -----------------------------------------------------------------------------
// coeff_loader.sv -- 窄口系数装载器：32 位数据 + 3 位字段选择，7 次写装一个模态
//
// 为什么需要它：coeff_t 有 7 个 (尾数, 移位) 对 = 210 位。如果顶层直接开 210 位端口，
// 光这一个口就要 210 个引脚（整机 I/O 预算 312），PnR 根本跑不动。
//
// 字格式（32 位，只用到低 30 位）：
//     [23:0]  尾数 mant（24 位有符号）
//     [29:24] 移位 shift（6 位无符号）
//     [31:30] 保留（写 0）
//
// 字段选择 co_sel：
//     0=a11 1=a12 2=a21 3=a22 4=gq 5=gv 6=wo
//
// 每写一次就输出"目前累积的整条记录"（ld_we 一拍），因此写满 7 次后记录才完整；
// 中间状态写进 RAM 无害（第 7 次会整体覆盖）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module coeff_loader #(
    parameter int N_MODES = 32
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        we,
    input  logic [$clog2(N_MODES)-1:0]  addr,
    input  logic [2:0]                  sel,
    input  logic [35:0]                 wdata,

    output logic                        ld_we,
    output logic [$clog2(N_MODES)-1:0]  ld_addr,
    output modal_step_pkg::coeff_t      ld_data
);

    import modal_step_pkg::*;

    logic signed [CW-1:0] mant_in;

    assign mant_in  = wdata[CW-1:0];      // 只有尾数；小数点由字段 Q 决定

    coeff_t co_acc;
    coeff_t co_next;

    // 累积：把选中的字段替换掉
    always_comb begin
        co_next = co_acc;
        case (sel)
            3'd0: begin co_next.a11 = mant_in; end
            3'd1: begin co_next.a12 = mant_in; end
            3'd2: begin co_next.a21 = mant_in; end
            3'd3: begin co_next.a22 = mant_in; end
            3'd4: begin co_next.gq  = mant_in; end
            3'd5: begin co_next.gv  = mant_in; end
            default: begin co_next.wo = mant_in; end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            co_acc  <= '0;
            ld_we   <= 1'b0;
            ld_addr <= '0;
            ld_data <= '0;
        end else begin
            ld_we <= we;
            if (we) begin
                co_acc  <= co_next;
                ld_addr <= addr;
                ld_data <= co_next;
            end
        end
    end

endmodule
