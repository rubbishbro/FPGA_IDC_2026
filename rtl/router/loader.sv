// -----------------------------------------------------------------------------
// weight_loader -- 从 W25Q64 读一张乐器表（N_MODES 条记录）并写进 router 的阵列
//
// 物理层：**标准四线（Quad）SPI，模式 0**，命令 0x6B（Fast Read Quad Output）
//   * 指令 0x6B：8 个钟，只有 DQ0 出（DQ1 不用，DQ2/DQ3 当 WP#/HOLD# 拉高）
//   * 24 位地址：**4 位一拍**，6 个钟
//   * 8 个空钟（dummy）
//   * 之后数据 4 位一拍（DQ0..DQ3 全部由 flash 驱动）
//   * SCK = CLK / SCK_DIV（SCK_DIV 必须 >= 4，取 4 的整数倍；
//     一个 SCK 的四个相位各占 SCK_DIV/4 个时钟）
//   注意：Quad 模式要求 flash 的 **QE 位**已经置位（状态寄存器 2 的 bit1），
//   那是一次性配置（烧片/上电时做），这里不做——不然每次加载都要写状态寄存器、
//   等 tSR（~10 ms）。
//
// flash 布局（和 tools/flash_image.py 是同一份契约）：
//   base = inst * TABLE_BYTES          TABLE_BYTES = SLOTS * N_MODES * 64
//   记录顺序 = RAM 地址顺序（slot-major）：slot 0 的 N_MODES 条，然后 slot 1 ...
//   第 (slot, mode) 条记录占 64 字节（16 个 32-bit 大端字）：
//     +0 a11  +4 a12  +8 a21  +12 a22  +16 gq  +20 gv  +24 wo  (+28 保留)
//     +32 c0  +36 s0  +40 gam +44 theta0 +48 g  +52 k12 +56 k21 (+60 保留)
//   **每个 slot 一张独立的表**（可以给 16 个声部预置不同音高），loader 一对一写入。
//   坏表（第一条记录全 FF 或全 0，比如没烧过 / QE 位不对）→ 走 W_FILL 把两张表
//   全填 0，并拉高 err（电平）交给上层；不做重试。
//
// 写口：{sel, addr} —— 最高位选表（0 = 系数表，1 = 调制参数表），低位 = {slot, mode}。
//
// 加载是阻塞的：busy 期间 voice_router 不处理 fmap、不出音频（见 README）。
// -----------------------------------------------------------------------------
module weight_loader #(
    parameter int SLOTS      = 16,
    parameter int N_MODES    = 64,
    parameter int CLK_HZ     = 100_000_000,
    parameter int SCK_DIV    = 4,               // SCK = CLK / SCK_DIV（>= 4，取 4 的倍数）
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
    output logic [$clog2(SLOTS*N_MODES):0]          ld_addr,   // {sel, slot, mode}
    output modal_step_pkg::coeff_t                  ld_co,
    output router_pkg::mod_par_t                    ld_pm,

    // QSPI flash：四线模式，DQ0..DQ3 双向
    output logic                        qspi_cs_n,
    output logic                        qspi_sck,
    output logic [3:0]                  qspi_dq_o,
    output logic                        qspi_dq_oe,
    input  logic [3:0]                  qspi_dq_i
);

    // 每声部的模态槽数补齐到 2 的幂：地址 = {slot, mode} 纯拼接，不做乘法
    localparam int MW_  = $clog2(N_MODES);
    localparam int NMP  = 1 << MW_;
    localparam int VW_  = $clog2(SLOTS);
    localparam int AW   = VW_ + MW_;                 // {slot, mode} 的位宽
    localparam int LDW  = AW + 1;                    // 最高位选表
    localparam int REC_WORDS = 16;                    // 每模态 16 个 32-bit 字
    localparam int TABLE_WORDS = N_MODES * REC_WORDS;
    localparam int TBL_BYTES = SLOTS * N_MODES * 64;   // 每个声部一张表
    localparam int MW = (N_MODES > 1) ? $clog2(N_MODES) : 1;
    localparam logic [7:0] CMD_QUAD = 8'h6B;          // Fast Read Quad Output

    // SCK 分频：一个 SCK 有 4 个相位，每个相位占 DIV4 个时钟
    localparam int DIV4 = (SCK_DIV / 4 < 1) ? 1 : (SCK_DIV / 4);
    localparam int DPW  = (DIV4 > 1) ? $clog2(DIV4) : 1;

    // 头部 = 8 钟指令 + 6 钟地址（4 位一拍）+ 8 钟 dummy = 22 个 SCK
    localparam int HDR_BEATS = 22;
    localparam logic [5:0] HDR_LAST = 6'(HDR_BEATS - 1);

    typedef enum logic [2:0] { W_IDLE, W_HDR, W_DATA, W_WR, W_FILL, W_END } wstate_e;
    wstate_e     st;

    logic [1:0]  ph;            // SCK 相位：0 低(等上升沿), 1 高, 2 高(等下降沿), 3 低
    logic [DPW-1:0] dph;        // 相位内分频计数
    logic        ph_last;       // 本相位最后一个时钟
    logic [5:0]  beat;          // 头部第几个 SCK（0..21）
    logic [2:0]  nib_i;         // 数据阶段：本字已收几个 nibble（0..7）
    logic [3:0]  word_i;        // 本记录第几个字（0..15）
    logic [MW-1:0] mode_i;      // 第几个模态
    logic [VW_-1:0] slot_i;     // 第几个声部（flash 里每个声部一条独立的表）
    logic [31:0] rx_sh;

    logic [23:0] base24;        // 本乐器的 flash 基地址 = inst * TABLE_BYTES
    logic [4:0]  wr_i;          // 本记录的第几笔写（0=系数表, 1=调制参数表；选表位在 ld_addr 最高位）
    // 第一条记录的健康检查：全 FF（没烧过）/ 全 0（QE 位不对、读不到）都算坏表
    logic [4:0]  ff_cnt, z_cnt;
    logic        err_rec;       // 判出来这表是坏的（保持到下次 start）
    logic        bad_ff, bad_z;
    // 坏表兜底：把两张表的全部地址写 0（比完整加载快得多）
    //   用 {sel, slot, mode} 三重计数，N_MODES 不是 2 的幂时地址也对
    logic           fill_sel;
    logic [VW_-1:0] fill_s;
    logic [MW-1:0]  fill_m;
    // 按计数终值开位宽（BLANK_WAIT 位太浪费；BLANK_WAIT=1 时也要能编过）
    localparam int BWW = (BLANK_WAIT > 1) ? $clog2(BLANK_WAIT) : 1;
    logic [BWW-1:0] wait_cnt;

    assign base24     = 24'(32'(inst) * 32'(TBL_BYTES));
    assign ph_last    = (dph == DPW'(DIV4 - 1));
    // 判"全 FF / 全 0"要把**当前这个字**算进去（计数器是非阻塞更新的）
    assign bad_ff     = (ff_cnt + 5'(rx_sh == 32'hFFFF_FFFF)) >= 5'(REC_WORDS);
    assign bad_z      = (z_cnt  + 5'(rx_sh == 32'h0000_0000)) >= 5'(REC_WORDS);
    // SCK：相位 1、2 为高；只在收发状态翻钟
    assign qspi_sck   = (st == W_HDR || st == W_DATA) && (ph == 2'd1 || ph == 2'd2);
    // 只有"指令 + 地址"这 14 个 SCK 驱动总线；dummy 阶段松开（换向给 flash）
    assign qspi_dq_oe = (st == W_HDR) && (beat < 6'd14);

    // 头部第 b 个 SCK 要送出的 4 位
    function automatic logic [3:0] hdr_dq(input logic [5:0] b);
        if (b < 6'd8)                       // 指令：只走 DQ0，DQ1..3 给 1
            hdr_dq = {1'b1, 1'b1, 1'b1, CMD_QUAD[7 - b[2:0]]};
        else                                // 地址：4 位一拍，MSB 先
            hdr_dq = base24[23 - 4*(b - 6'd8) -: 4];
    endfunction

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
            // 参数表（8 个字）：4 个基值 + 4 个对 lambda 的斜率
            //   a21 不存（= -a12）、S21 不存（= -2*a12 - S12），都用时算出来
            4'd8:  ld_pm.a11  <= w;
            4'd9:  ld_pm.a12  <= w;
            4'd10: ld_pm.a22  <= w;
            4'd11: ld_pm.wo   <= w;
            4'd12: ld_pm.s11  <= w;
            4'd13: ld_pm.s12  <= w;
            4'd14: ld_pm.s22  <= w;
            4'd15: ld_pm.swo  <= w;
        endcase
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= W_IDLE;
            ph        <= 2'd0;
            dph       <= '0;
            beat      <= 6'd0;
            nib_i     <= 3'd0;
            word_i    <= 4'd0;
            mode_i    <= '0;
            rx_sh     <= 32'd0;
            wr_i      <= 5'd0;
            ff_cnt    <= '0;
            z_cnt     <= '0;
            err_rec   <= 1'b0;
            fill_sel  <= 1'b0;
            fill_s    <= '0;
            fill_m    <= '0;
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
                    dph  <= '0;
                    if (start) begin
                        busy      <= 1'b1;
                        err       <= 1'b0;
                        err_rec   <= 1'b0;
                        ff_cnt    <= '0;
                        z_cnt     <= '0;
                        fill_sel  <= 1'b0;
            fill_s    <= '0;
            fill_m    <= '0;
                        qspi_cs_n <= 1'b0;
                        // 第 0 个 SCK 的指令位要在第一个上升沿之前就摆好
                        qspi_dq_o <= hdr_dq(6'd0);
                        beat      <= 6'd0;
                        nib_i     <= 3'd0;
                        word_i    <= 4'd0;
                        mode_i    <= '0;
                        slot_i    <= '0;
                        rx_sh     <= 32'd0;
                        st        <= W_HDR;
                    end
                end

                // ------------------------------------------------------------
                W_HDR, W_DATA: begin
                    // 相位内分频：每个相位占 DIV4 个时钟
                    if (ph_last) begin
                        dph <= '0;
                        case (ph)
                            // ---- 上升沿之前：采 4 位（数据阶段） ----
                            2'd0: if (st == W_DATA) rx_sh <= {rx_sh[27:0], qspi_dq_i};
                            // ---- 下降沿之后：换下一拍的输出 ----
                            2'd2: if (st == W_HDR) qspi_dq_o <= hdr_dq(beat + 6'd1);
                            // ---- 本 SCK 结束 ----
                            2'd3: begin
                                if (st == W_HDR) begin
                                    if (beat == HDR_LAST) begin
                                        beat      <= 6'd0;
                                        nib_i     <= 3'd0;
                                        qspi_dq_o <= 4'b1111;   // dummy 之后总线交给 flash
                                        st        <= W_DATA;
                                    end else begin
                                        beat <= beat + 6'd1;
                                    end
                                end else begin
                                    // 数据阶段：8 个 nibble = 一个 32 位字
                                    if (nib_i == 3'd7) begin
                                        nib_i <= 3'd0;
                                        decode_word(word_i, rx_sh);
                                        // 第一条记录逐字统计"全 FF"/"全 0"：
                                        //   全 FF = 没烧过；全 0 = QE 位没置 / 四线读不到数据
                                        if (slot_i == '0 && mode_i == '0) begin
                                            if (rx_sh == 32'hFFFF_FFFF) ff_cnt <= ff_cnt + 1'b1;
                                            if (rx_sh == 32'h0000_0000) z_cnt  <= z_cnt  + 1'b1;
                                        end
                                        if (word_i == REC_WORDS-1) begin
                                            word_i <= 4'd0;
                                            wr_i   <= 5'd0;
                                            if (slot_i == '0 && mode_i == '0 && (bad_ff || bad_z)) begin
                                                // 表是坏的：别再把这堆垃圾当系数用，
                                                //   收 CS 直接转"把 RAM 全填 0"
                                                err_rec   <= 1'b1;
                                                qspi_cs_n <= 1'b1;
                                                qspi_dq_o <= 4'b1111;
                                                st        <= W_FILL;
                                            end else begin
                                                st <= W_WR;
                                            end
                                        end else begin
                                            word_i <= word_i + 4'd1;
                                        end
                                    end else begin
                                        nib_i <= nib_i + 3'd1;
                                    end
                                end
                            end
                            default: ;
                        endcase
                        ph <= (ph == 2'd3) ? 2'd0 : ph + 2'd1;
                    end else begin
                        dph <= dph + 1'b1;
                    end
                end

                // ------------------------------------------------------------
                // 一条记录只写**它自己那个声部**（flash 里每个 slot 是不同音高的表）
                //   一次记录 = 16 个字 = 8 个系数 + 8 个调制参数 -> 两笔写（选表位不同）
                W_WR: begin
                    ld_we <= 1'b1;
                    // 地址 = {sel, 声部, 模态}，sel 最高位选表
                    if (wr_i == 5'd0) ld_addr <= {1'b0, slot_i[VW_-1:0], mode_i};
                    else              ld_addr <= {1'b1, slot_i[VW_-1:0], mode_i};
                    if (wr_i == 5'd1) begin
                        wr_i <= 5'd0;
                        // 下一个模态；一个声部写完就换下一个声部（顺序 = RAM 地址顺序）
                        if (mode_i == MW'(N_MODES-1)) begin
                            mode_i <= '0;
                            if (slot_i == VW_'(SLOTS-1)) st <= W_END;
                            else begin
                                slot_i <= slot_i + 1'b1;
                                nib_i  <= 3'd0;
                                st     <= W_DATA;
                            end
                        end else begin
                            mode_i <= mode_i + 1'b1;
                            nib_i  <= 3'd0;
                            st     <= W_DATA;
                        end
                    end else begin
                        wr_i <= wr_i + 1'b1;
                    end
                end

                // ------------------------------------------------------------
                // 坏表兜底：把两张表的**每个地址**都写 0（2*SLOTS*N_MODES 笔，
                //   比完整加载快得多）。这样即使键被按下，引擎算出来也是 0，
                //   不会有非预期的声音；坏消息通过 err（电平）交给上层。
                W_FILL: begin
                    ld_we   <= 1'b1;
                    ld_co   <= '0;
                    ld_pm   <= '0;
                    // 地址 = {sel, slot, mode}（= slot*NMP + mode，N_MODES 不是 2 的幂也对）
                    ld_addr <= {fill_sel, fill_s, fill_m};
                    if (fill_sel == 1'b1 && fill_s == VW_'(SLOTS-1) &&
                        fill_m == MW'(N_MODES-1)) begin
                        fill_sel <= 1'b0;
                        fill_s   <= '0;
                        fill_m   <= '0;
                        st       <= W_END;
                    end else if (fill_m == MW'(N_MODES-1)) begin
                        fill_m <= '0;
                        if (fill_s == VW_'(SLOTS-1)) begin
                            fill_s   <= '0;
                            fill_sel <= 1'b1;      // 系数表填完 -> 填参数表
                        end else begin
                            fill_s <= fill_s + 1'b1;
                        end
                    end else begin
                        fill_m <= fill_m + 1'b1;
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
                        err      <= err_rec;
                        st       <= W_IDLE;
                    end else wait_cnt <= wait_cnt + 1'b1;
                end

                default: st <= W_IDLE;
            endcase
        end
    end

endmodule
