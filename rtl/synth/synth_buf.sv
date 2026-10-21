// -----------------------------------------------------------------------------
// synth_buf.sv -- A/B/C 共享的中间 RAM 缓冲（迁移第一步）
//
// 逻辑上是一块 max-width（256-bit）BUF，按 engine 分 region：
//   * coeff1: ENG1 低 72 bit（G/a2/a1）
//   * coeff2: ENG2 224 bit（a11..wo）
//   * result: 每 engine 两组 ping-pong（64-bit）
//
// 物理上暂时用两个数组实现两个 region（单写 + 各自读），便于先把接口定下来；
// 综合时若要求一块物理 RAM，再把两个 region 合成 256-bit 字、用地址高位选。
// 读口是同步读（1 拍延迟），不要按异步 ROM 用。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module synth_buf #(
    parameter int ENG1_DEPTH = 32 * 48,
    parameter int ENG2_DEPTH = 16 * 48,
    parameter int WIDTH      = 256
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // 写：router / class_loader
    input  logic                 wr_en,
    input  logic                 wr_engine,     // 0=ENG1，1=ENG2
    input  logic [15:0]          wr_addr,
    input  logic [WIDTH-1:0]     wr_data,

    // ENG1 读
    input  logic                 rd1_en,
    input  logic [15:0]          rd1_addr,
    output logic [WIDTH-1:0]     rd1_data,

    // ENG2 读
    input  logic                 rd2_en,
    input  logic [15:0]          rd2_addr,
    output logic [WIDTH-1:0]     rd2_data,

    // 结果 ping-pong：[engine][bank]
    input  logic                 res_we,
    input  logic                 res_engine,
    input  logic                 res_bank,
    input  logic [63:0]          res_data,
    output logic [63:0]          res1_b0, res1_b1,
    output logic [63:0]          res2_b0, res2_b1
);

    logic [WIDTH-1:0] mem1 [0:ENG1_DEPTH-1];
    logic [WIDTH-1:0] mem2 [0:ENG2_DEPTH-1];
    logic [63:0]      res_mem [0:1][0:1];

    integer i;
    initial begin
        for (i = 0; i < ENG1_DEPTH; i = i + 1) mem1[i] = '0;
        for (i = 0; i < ENG2_DEPTH; i = i + 1) mem2[i] = '0;
        res_mem[0][0] = '0; res_mem[0][1] = '0;
        res_mem[1][0] = '0; res_mem[1][1] = '0;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd1_data <= '0;
            rd2_data <= '0;
        end else begin
            if (wr_en) begin
                if (!wr_engine && (wr_addr < ENG1_DEPTH)) mem1[wr_addr] <= wr_data;
                if ( wr_engine && (wr_addr < ENG2_DEPTH)) mem2[wr_addr] <= wr_data;
            end
            if (rd1_en && (rd1_addr < ENG1_DEPTH)) rd1_data <= mem1[rd1_addr];
            if (rd2_en && (rd2_addr < ENG2_DEPTH)) rd2_data <= mem2[rd2_addr];
            if (res_we) res_mem[res_engine][res_bank] <= res_data;
        end
    end

    assign res1_b0 = res_mem[0][0];
    assign res1_b1 = res_mem[0][1];
    assign res2_b0 = res_mem[1][0];
    assign res2_b1 = res_mem[1][1];

endmodule
