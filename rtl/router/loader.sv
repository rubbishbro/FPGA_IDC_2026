`timescale 1ns/1ps
// =============================================================================
// weight_loader -- W25Q64 QSPI 读驱动 + 记录装配 + 系数块写口
//
// 物理层：标准 1 线 SPI（模式 0，CPOL=0/CPHA=0），命令 0x03 (READ)。
//   * SCK = CLK / SCK_DIV，默认 CLK/4（87 MHz 下约 22 MHz，W25Q64 标准读的
//     上限是 50 MHz，留一倍余量；要快就把 SCK_DIV 设成 2）。
//   * 上升沿采 MISO，下降沿换 MOSI（标准 SPI 模式 0，两边的时序都留了半拍）。
//   * 只在发命令/地址时驱动总线（oe=1，DQ2/DQ3 顺便拉高，别让 WP#/HOLD# 浮空），
//     读数据时 oe=0，DQ0/DQ2/DQ3 交给板上拉，DQ1 由 flash 驱动。
//   * 每收满一个 32-bit 字就停一拍 SCK 做装配——W25Q 只按 SCK 边沿走，
//     中间停多久都不影响（CS 只要一直低）。
//
// flash 布局（一个乐器一张表，16 个 slot 共用同一份，loader 负责复制）
//   base = inst * TABLE_BYTES          TABLE_BYTES = N_MODES * 64
//   第 m 个模态占 64 字节（第 m*64 起）：
//     +0  a11   +4  a12   +8  a21   +12 a22
//     +16 gq    +20 gv    +24 wo    +28 保留
//     +32 c0    +36 s0    +40 gam   +44 theta0
//     +48 g     +52 k12   +56 k21   +60 保留
//   每个字段在 flash 里是**大端**（高字节在前）。W25Q 先发低地址字节、每字节
//   高位先出，所以 RTL 里直接移位拼出来的就是字段值，不用再倒字节。
//   上位机打包（rtl/router/tools/flash_image.py）必须照这个来。
//
// 阻塞语义：voice_router 在 S_LOAD 里等 ld_done，这期间不处理 fmap、不出音频
//   （一个模态 2090 拍，80 模态约 1.9 ms @87 MHz）。这是有意的设计选择，不是遗漏；
//   要边放边载得改成双缓冲。加载出错的处理仍待定（本模块只负责给 err）。
//
// 写口：收满一个模态的 16 个字 -> 装配成 coeff_t / mod_par_t -> 写 SLOTS 个 slot
//   系数表地址 = {slot, mode}
//   参数表地址 = SLOTS*N_MODES + {slot, mode}
// =============================================================================
module weight_loader #(
    parameter int SLOTS      = 16,
    parameter int N_MODES    = 48,
    parameter int CLK_HZ     = 100_000_000,
    parameter int SCK_DIV    = 4,               // SCK = CLK / SCK_DIV（必须 >= 4）
    parameter int BLANK_WAIT = 100              // CS 拉高后至少等这么多拍（tSHSL）
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic [3:0]                  inst,       // 乐器号：决定 flash 基地址
    input  logic                        start,
    output logic                        busy,
    output logic                        done,       // 单拍
    output logic                        err,        // 读到全 FF（没烧过）

    // 统一的写口：一个使能 + 一个地址空间
    //   地址 [0, SLOTS*N_MODES)               -> 系数表
    //   地址 [SLOTS*N_MODES, 2*SLOTS*N_MODES) -> 调制参数表
    output logic                                    ld_we,
    output logic [$clog2(2*SLOTS*N_MODES)-1:0]      ld_addr,
    output modal_step_pkg::coeff_t                  ld_co,
    output router_pkg::mod_par_t                    ld_pm,

    // QSPI flash（1 线模式只用 DQ0 出 / DQ1 入）
    output logic                        qspi_cs_n,
    output logic                        qspi_sck,
    output logic [3:0]                  qspi_dq_o,
    output logic                        qspi_dq_oe,
    input  logic [3:0]                  qspi_dq_i
);

    localparam int LDW = $clog2(2*SLOTS*N_MODES);
    localparam int REC_WORDS = 16;                    // 每模态 16 个 32-bit 字
    localparam int TABLE_WORDS = N_MODES * REC_WORDS;
    localparam int TBL_BYTES = N_MODES * 64;
    localparam int MW = (N_MODES > 1) ? $clog2(N_MODES) : 1;
    localparam logic [7:0] CMD_READ = 8'h03;

    typedef enum logic [2:0] { W_IDLE, W_HDR, W_DATA, W_WR, W_END } wstate_e;
    wstate_e     st;

    logic [1:0]  ph;            // SCK 相位：0 低/准备, 1 高(上升沿已过), 2 高, 3 低(下降沿已过)
    logic [5:0]  bit_i;         // 本字已收/发了几位（0..31）
    logic [3:0]  word_i;        // 本记录第几个字（0..15）
    logic [MW-1:0] mode_i;      // 第几个模态
    logic [31:0] tx_sh, rx_sh;

    logic [23:0] faddr;
    logic [23:0] base24;        // 本乐器的 flash 基地址 = inst * TABLE_BYTES
    logic [4:0]  wr_i;          // 写 slot：0..SLOTS-1 写系数表，SLOTS..2*SLOTS-1 写参数表
    logic        blank;         // 第一个字是 FFFFFFFF -> 这表没烧
    logic [BLANK_WAIT-1:0] wait_cnt;

    // SCK：只在收发状态里翻转（其余时间拉低；CS 低时停钟对 flash 没有影响）
    assign base24      = 24'(32'(inst) * 32'(TBL_BYTES));
    assign qspi_sck    = (st == W_HDR || st == W_DATA) && (ph == 2'd1 || ph == 2'd2);
    assign qspi_dq_oe  = (st == W_HDR);          // 只在这阵子驱动总线（发命令+地址）

    // 一个模态的 16 个字收齐后直接装配到写数据口 ld_co / ld_pm
    //   （这两个输出寄存器就是装配寄存器，不再另开一份 staging）
    task automatic decode_word(input logic [3:0] wi, input logic [31:0] w);
        case (wi)
            4'd0:  ld_co.a11 <= w;
            4'd1:  ld_co.a12 <= w;
            4'd2:  ld_co.a21 <= w;
            4'd3:  ld_co.a22 <= w;
            4'd4:  ld_co.gq  <= w;
            4'd5:  ld_co.gv  <= w;
            4'd6:  ld_co.wo  <= w;
            4'd7:  ;                       // 保留
            4'd8:  ld_pm.c0     <= w;
            4'd9:  ld_pm.s0     <= w;
            4'd10: ld_pm.gam    <= w;
            4'd11: ld_pm.theta0 <= w;
            4'd12: ld_pm.g      <= w;
            4'd13: ld_pm.k12    <= w;
            4'd14: ld_pm.k21    <= w;
            default: ;                     // 15 保留
        endcase
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= W_IDLE;
            ph        <= 2'd0;
            bit_i     <= 6'd0;
            word_i    <= 4'd0;
            mode_i    <= '0;
            tx_sh     <= 32'd0;
            rx_sh     <= 32'd0;

            faddr     <= 24'd0;
            wr_i      <= 5'd0;
            blank     <= 1'b0;
            wait_cnt  <= '0;
            busy      <= 1'b0;
            done      <= 1'b0;
            err       <= 1'b0;
            ld_we     <= 1'b0;
            ld_addr   <= '0;
            ld_co     <= '0;
            ld_pm     <= '0;
            qspi_cs_n <= 1'b1;
            qspi_dq_o <= 4'b1111;
        end else begin
            done  <= 1'b0;
            ld_we <= 1'b0;

            case (st)
                // ------------------------------------------------------------
                W_IDLE: begin
                    busy <= 1'b0;
                    ph   <= 2'd0;
                    if (start) begin
                        busy     <= 1'b1;
                        err      <= 1'b0;
                        blank    <= 1'b0;
                        qspi_cs_n<= 1'b0;
                        faddr    <= base24;
                        // 第一个 bit 必须在第一个上升沿之前就摆好：
                        // 头 = {8 bit 命令, 24 bit 地址}，先手工发最高位，其余交给移位
                        qspi_dq_o[0] <= CMD_READ[7];
                        tx_sh    <= {CMD_READ[6:0], base24, 1'b0};
                        rx_sh    <= 32'd0;
                        bit_i    <= 6'd0;
                        word_i   <= 4'd0;
                        mode_i   <= '0;
                        st       <= W_HDR;
                    end
                end

                // ------------------------------------------------------------
                // 发 8 bit 命令 + 24 bit 地址
                W_HDR, W_DATA: begin
                    qspi_dq_o[3:2] <= 2'b11;       // WP# / HOLD# 保持高
                    case (ph)
                        2'd0: rx_sh <= {rx_sh[30:0], qspi_dq_i[1]};   // 上升沿前采 MISO
                        2'd2: begin                                    // 下降沿：换 MOSI
                            qspi_dq_o[0] <= tx_sh[31];
                            tx_sh        <= {tx_sh[30:0], 1'b0};
                        end
                        2'd3: begin
                            if (bit_i == 6'd31) begin
                                bit_i <= 6'd0;
                                if (st == W_HDR) begin
                                    // 命令 + 地址发完，开始收数据（oe 由组合逻辑按状态拉低）
                                    st         <= W_DATA;
                                end else begin
                                    decode_word(word_i, rx_sh);
                                    if (word_i == 4'd0 && mode_i == '0 && !blank)
                                        blank <= (rx_sh == 32'hFFFF_FFFF);
                                    if (word_i == REC_WORDS-1) begin
                                        word_i <= 4'd0;
                                        wr_i   <= 5'd0;
                                        st     <= W_WR;
                                    end else begin
                                        word_i <= word_i + 4'd1;
                                    end
                                end
                            end else begin
                                bit_i <= bit_i + 6'd1;
                            end
                        end
                        default: ;
                    endcase
                    ph <= (ph == 2'd3) ? 2'd0 : ph + 2'd1;
                end

                // ------------------------------------------------------------
                // 把这个模态的记录写进全部 slot（上半段系数表、下半段参数表）
                W_WR: begin
                    if (wr_i < 5'(SLOTS)) begin
                        ld_we          <= 1'b1;
                        ld_addr        <= LDW'(32'(wr_i) * 32'(N_MODES) + 32'(mode_i));

                    end else begin
                        ld_we          <= 1'b1;
                        ld_addr        <= LDW'(32'(SLOTS*N_MODES) +
                                               32'(wr_i - 5'(SLOTS)) * 32'(N_MODES) +
                                               32'(mode_i));

                    end
                    if (wr_i == 5'(2*SLOTS-1)) begin
                        wr_i <= 5'd0;
                        if (mode_i == MW'(N_MODES-1)) st <= W_END;
                        else begin
                            mode_i <= mode_i + 1'b1;
                            bit_i  <= 6'd0;
                            st     <= W_DATA;
                        end
                    end else begin
                        wr_i <= wr_i + 1'b1;
                    end
                end

                // ------------------------------------------------------------
                W_END: begin
                    qspi_cs_n  <= 1'b1;
                    qspi_dq_o  <= 4'b1111;
                    if (wait_cnt == BLANK_WAIT-1) begin
                        wait_cnt <= '0;
                        busy     <= 1'b0;
                        done     <= 1'b1;
                        err      <= blank;
                        st       <= W_IDLE;
                    end else wait_cnt <= wait_cnt + 1'b1;
                end

                default: st <= W_IDLE;
            endcase
        end
    end

endmodule
