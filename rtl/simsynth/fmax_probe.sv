// -----------------------------------------------------------------------------
// fmax_probe.sv -- 时序探针：只有 clk/rst_n/led，激励与系数全部由内部 LFSR 产生
//
// 为什么需要它：真实顶层有上百个 I/O，做 PnR 需要引脚约束；而 Fmax 只取决于内部的
// 数据通路。本探针把系数/激励写进 RAM（综合器不会把它们当常数折叠），跑起来后把结果
// 异或进累加器驱动一个 LED 防止逻辑被优化掉。端口只有 3 个，PnR 无引脚压力。
//
// 配置 = 生产尺寸：N_MODES=48、X_DEPTH=64、SLOTS=8、DEBUG_PORT=0。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module fmax_e7 #(
    parameter int N_MODES = 48,
    parameter int X_DEPTH = 64,
    parameter int SLOTS   = 8
) (
    input  logic clk,
    input  logic rst_n,
    output logic led
);

    import modal_step_pkg::*;

    localparam int NCO = SLOTS * N_MODES;
    localparam int NX  = SLOTS * X_DEPTH;
    localparam int TB  = $clog2(NCO);
    localparam int XB  = $clog2(NX);

    logic                          co_we;
    logic [TB-1:0]                 co_addr;
    coeff_t                        co_data;
    logic                          x_we;
    logic [XB-1:0]                 x_addr;
    logic signed [XW-1:0]          x_data;
    logic                          start;
    logic [$clog2(SLOTS+1)-1:0]    n_voices;
    logic [$clog2(X_DEPTH+1)-1:0]  n_samples;
    logic [$clog2(N_MODES+1)-1:0]  n_modes;
    logic [SLOTS-1:0]              st_zero_mask;
    logic                          done;
    logic                          busy;
    logic                          rd_en;
    logic [$clog2(X_DEPTH)-1:0]    rd_addr;
    logic signed [YW-1:0]          rd_data;
    logic                          rd_valid;

    modal_voice_top #(
        .N_MODES(N_MODES), .X_DEPTH(X_DEPTH), .SLOTS(SLOTS), .DEBUG_PORT(1'b0)
    ) u_vt (
        .clk(clk), .rst_n(rst_n),
        .co_we(co_we), .co_addr(co_addr), .co_data(co_data),
        .x_we(x_we), .x_addr(x_addr), .x_data(x_data),
        .start(start), .n_voices(n_voices), .n_samples(n_samples), .n_modes(n_modes),
        .st_zero_mask(st_zero_mask), .done(done), .busy(busy),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .ns_rd_en(1'b0), .ns_rd_addr('0), .ns_rd_sel(1'b0),
        .ns_rd_data(), .ns_rd_valid()
    );

    localparam int NCO_LAST = NCO - 1;
    localparam int NX_LAST  = NX - 1;

    logic [31:0]   lfsr;
    logic [TB-1:0] ci;
    logic [XB-1:0] xi;
    logic [1:0]    ph;            // 0=装系数 1=清状态 2=装激励 3=循环跑
    logic [63:0]   acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr      <= 32'h1234_5678;
            ci        <= '0;
            xi        <= '0;
            ph        <= 2'd0;
            co_we     <= 1'b0;
            x_we      <= 1'b0;
            co_addr   <= '0;
            x_addr    <= '0;
            co_data   <= '0;
            x_data    <= '0;
            start     <= 1'b0;
            n_voices  <= SLOTS[$clog2(SLOTS+1)-1:0];
            n_samples <= '0;
            n_modes   <= '0;
            rd_en     <= 1'b0;
            rd_addr   <= '0;
            acc       <= '0;
            led       <= 1'b0;
        end else begin
            lfsr  <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            led   <= ^acc;
            start <= 1'b0;

            case (ph)
                2'd0: begin                                   // 系数（整条记录一次写）
                    co_we   <= 1'b1;
                    co_addr <= ci;
                    // 7 个字段必须是**互不相同**的表达式：写成 {7{lfsr}} 会被综合器当成
                    // 公共子表达式，7 个乘法合并成 3 个（实测 MULT27X36 从 14 掉到 6）。
                    co_data.a11 <= lfsr;
                    co_data.a12 <= {lfsr[4:0],  lfsr[31:5]};
                    co_data.a21 <= {lfsr[8:0],  lfsr[31:9]};
                    co_data.a22 <= {lfsr[12:0], lfsr[31:13]};
                    co_data.gq  <= {lfsr[16:0], lfsr[31:17]};
                    co_data.gv  <= {lfsr[20:0], lfsr[31:21]};
                    co_data.wo  <= {lfsr[24:0], lfsr[31:25]};
                    if (ci == TB'(NCO_LAST)) begin
                        co_we <= 1'b0;
                        ci    <= '0;
                        ph    <= 2'd2;
                    end else begin
                        ci <= ci + 1'b1;
                    end
                end

                2'd2: begin                                   // 激励
                    x_we   <= 1'b1;
                    x_addr <= xi;
                    x_data <= lfsr;
                    if (xi == XB'(NX_LAST)) begin
                        x_we <= 1'b0;
                        xi   <= '0;
                        ph   <= 2'd3;
                    end else begin
                        xi <= xi + 1'b1;
                    end
                end

                default: begin                                // 循环跑作业（8 声部 x 8 帧）
                    if (!busy) begin
                        start     <= 1'b1;
                        n_voices  <= SLOTS[$clog2(SLOTS+1)-1:0];
                        n_modes   <= N_MODES[$clog2(N_MODES+1)-1:0];
                        n_samples <= 4'd8;
                        rd_en     <= 1'b1;
                        rd_addr   <= rd_addr + 1'b1;   // 结果每采样一个，地址只有块长那么宽
                    end
                    if (rd_valid) acc <= acc ^ rd_data;
                end
            endcase
        end
    end

endmodule
