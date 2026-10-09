// -----------------------------------------------------------------------------
// audio_transport.sv -- core <-> 音频串行传输。
//
// 两个时钟域，一个共享的异步置位复位，其释放在
// 每个域中分别同步。唯一的跨域信号是：
//   * 两个 audio_async_fifo 指针（Gray 码，2 级 FF）
//   * 48 kHz 帧翻转和粘滞诊断电平（2 级 FF 电平）
// 数据总线从不直接同步。
//
//   core --(core_tx_* --> TX FIFO --> pt8211_tx)--> DAC_BCK/WS/DIN
//   MIC_BCK/WS/SD --> i2s_mic_rx --> RX FIFO -->(core_rx_*)--> core
//
// TX FIFO 默认 16 个立体声对，RX FIFO 默认 16 个样本。
// 空的 TX FIFO 产生零帧和粘滞下溢；满的 RX FIFO
// 丢弃新的麦克风样本并置位粘滞溢出（旧样本
// 从不被覆盖）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// 音频数据的搬运和节拍传递
// 把clk_core内部sample搬运进clk_audio并且发送
// 把音频域的48khz的帧节拍，诊断状态跨域告诉给核心主控域

// 音频传输模块
module audio_transport #(
    parameter int TX_DEPTH = 16,
    parameter int RX_DEPTH = 16,
    parameter int CH_SEL   = 0,
    // 静态输出格式：1 = 标准 I2S（MAX98357A，默认），
    //                0 = PT8211 Japanese/LSBJ（仅在显式选择时使用）
    parameter int OUT_FORMAT = 1
) (
    input  logic        clk_core,
    input  logic        clk_audio,
    input  logic        rst_n,          // 共享异步置位

    input  logic        mic_en,         // 静态；SONG 模式下为 0
    input  logic        diag_clear,     // core 域诊断清零

    // core 域 DAC 生产者
    input  logic        core_tx_valid,
    output logic        core_tx_ready,
    input  logic [31:0] core_tx_data,

    // core 域麦克风消费者
    output logic        core_rx_valid,
    input  logic        core_rx_ready,
    output logic [23:0] core_rx_data,

    // 音频串行
    input  logic        mic_sd,
    output logic        dac_bck,
    output logic        dac_ws,
    output logic        dac_din,
    output logic        mic_bck,
    output logic        mic_ws,

    // core 域时序与粘滞诊断
    output logic        core_sample_tick,    // 48 kHz 翻转，2 级 FF 同步
    output logic        core_sample_pulse,   // 每帧一个 core clk
    output logic        underflow_sticky,
    output logic        overflow_sticky
);

    // ------------------------------------------------------------------
    // 按域同步的复位释放
    // ------------------------------------------------------------------
    logic [1:0] arst_sync, crst_sync;
    always_ff @(posedge clk_audio or negedge rst_n)
        if (!rst_n) arst_sync <= 2'b00;
        else        arst_sync <= {arst_sync[0], 1'b1};

    always_ff @(posedge clk_core or negedge rst_n)
        if (!rst_n) crst_sync <= 2'b00;
        else        crst_sync <= {crst_sync[0], 1'b1};

    wire arst_n = arst_sync[1];
    wire crst_n = crst_sync[1];

    // ------------------------------------------------------------------
    // diag_clear 是 core 域的一个 *事件*（一个或几个 core 周期，从不是
    // 持续电平）。单个 core 周期脉冲会被（较慢的）音频域中的
    // 电平 2 级 FF 同步器漏掉，因此把它转换为
    // 翻转信号，经同步后重新检测为一个 clk 的音频事件。无论
    // 源脉冲宽度如何，一个事件总会被送达；两个事件
    // 若间隔小于同步器延迟（约 2 个音频 clk）则会合并。
    // ------------------------------------------------------------------
    logic dc_prev, dc_tgl;
    always_ff @(posedge clk_core or negedge crst_n)
        if (!crst_n) begin
            dc_prev <= 1'b0;
            dc_tgl  <= 1'b0;
        end else begin
            dc_prev <= diag_clear;
            if (diag_clear & ~dc_prev) dc_tgl <= ~dc_tgl;
        end

    logic dt_s1, dt_s2, dt_p;
    always_ff @(posedge clk_audio or negedge arst_n)
        if (!arst_n) begin
            dt_s1 <= 1'b0; dt_s2 <= 1'b0; dt_p <= 1'b0;
        end else begin
            dt_s2 <= dt_s1; dt_s1 <= dc_tgl; dt_p <= dt_s2;
        end
    wire a_diag_clear = dt_s2 ^ dt_p;

    // ------------------------------------------------------------------
    // TX 通路：core -> TX FIFO -> 选定的串行发送器
    //   OUT_FORMAT=1 : 标准 I2S（MAX98357A），默认
    //   OUT_FORMAT=0 : PT8211 Japanese/LSBJ，显式选择
    // ------------------------------------------------------------------
    logic        tx_rvalid, tx_rready;
    logic [31:0] tx_rdata;
    logic        tx_underflow, tx_frame_tick;

    audio_async_fifo #(.WIDTH(32), .DEPTH(TX_DEPTH)) u_tx_fifo (
        .wclk  (clk_core),
        .rclk  (clk_audio),
        .rst_n (rst_n),
        .wvalid(core_tx_valid),
        .wready(core_tx_ready),
        .wdata (core_tx_data),
        .rvalid(tx_rvalid),
        .rready(tx_rready),
        .rdata (tx_rdata),
        .wfull (),
        .rempty()
    );

    generate
        if (OUT_FORMAT == 0) begin : g_pt8211
            pt8211_tx u_tx (
                .clk             (clk_audio),
                .rst_n           (arst_n),
                .diag_clear      (a_diag_clear),
                .in_valid        (tx_rvalid),
                .in_ready        (tx_rready),
                .in_data         (tx_rdata),
                .dac_bck         (dac_bck),
                .dac_ws          (dac_ws),
                .dac_din         (dac_din),
                .underflow_pulse (),
                .underflow_sticky(tx_underflow),
                .frame_tick      (tx_frame_tick)
            );
        end else begin : g_i2s_amp
            i2s_amp_tx u_tx (
                .clk             (clk_audio),
                .rst_n           (arst_n),
                .diag_clear      (a_diag_clear),
                .in_valid        (tx_rvalid),
                .in_ready        (tx_rready),
                .in_data         (tx_rdata),
                .amp_bclk        (dac_bck),
                .amp_ws          (dac_ws),
                .amp_din         (dac_din),
                .underflow_pulse (),
                .underflow_sticky(tx_underflow),
                .frame_tick      (tx_frame_tick)
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // RX 通路：i2s_mic_rx -> RX FIFO -> core
    // ------------------------------------------------------------------
    logic        mic_valid;
    logic [23:0] mic_data;
    logic        rx_wready;

    i2s_mic_rx #(.CH_SEL(CH_SEL)) u_mic (
        .clk      (clk_audio),
        .rst_n    (arst_n & mic_en),
        .sd       (mic_sd),
        .mic_bck  (mic_bck),
        .mic_ws   (mic_ws),
        .mic_data (mic_data),
        .mic_valid(mic_valid)
    );

    wire rx_wvalid = mic_valid & mic_en;

    audio_async_fifo #(.WIDTH(24), .DEPTH(RX_DEPTH)) u_rx_fifo (
        .wclk  (clk_audio),
        .rclk  (clk_core),
        .rst_n (rst_n),
        .wvalid(rx_wvalid),
        .wready(rx_wready),
        .wdata (mic_data),
        .rvalid(core_rx_valid),
        .rready(core_rx_ready),
        .rdata (core_rx_data),
        .wfull (),
        .rempty()
    );

    // ------------------------------------------------------------------
    // 粘滞溢出（音频域），由同步后的 diag_clear 清零
    // ------------------------------------------------------------------
    logic rx_overflow;
    always_ff @(posedge clk_audio or negedge arst_n)
        if (!arst_n)                     rx_overflow <= 1'b0;
        else if (rx_wvalid & ~rx_wready) rx_overflow <= 1'b1;
        else if (a_diag_clear)           rx_overflow <= 1'b0;

    // ------------------------------------------------------------------
    // 48 kHz 帧翻转（音频域）-> core
    // ------------------------------------------------------------------
    logic tick_tgl;
    always_ff @(posedge clk_audio or negedge arst_n)
        if (!arst_n)            tick_tgl <= 1'b0;
        else if (tx_frame_tick) tick_tgl <= ~tick_tgl;

    logic tgl_s1, tgl_s2, tgl_prev;
    always_ff @(posedge clk_core or negedge crst_n)
        if (!crst_n) begin
            tgl_s1   <= 1'b0;
            tgl_s2   <= 1'b0;
            tgl_prev <= 1'b0;
        end else begin
            tgl_s2   <= tgl_s1;
            tgl_s1   <= tick_tgl;
            tgl_prev <= tgl_s2;
        end

    assign core_sample_tick  = tgl_s2;
    assign core_sample_pulse = tgl_s2 ^ tgl_prev;

    // ------------------------------------------------------------------
    // 同步到 core 的粘滞诊断（电平，而非裸脉冲）。
    // 直接暴露同步后的音频域粘滞电平（而不是在 core 中
    // 锁存它）意味着事件送达的 diag_clear 能真正清除
    // core 可见的标志：当音频粘滞下降时，本输出也随之下降。
    // ------------------------------------------------------------------
    logic uf_s1, uf_s2, of_s1, of_s2;
    always_ff @(posedge clk_core or negedge crst_n)
        if (!crst_n) begin
            uf_s1 <= 1'b0; uf_s2 <= 1'b0;
            of_s1 <= 1'b0; of_s2 <= 1'b0;
        end else begin
            uf_s2 <= uf_s1; uf_s1 <= tx_underflow;
            of_s2 <= of_s1; of_s1 <= rx_overflow;
        end

    assign underflow_sticky = uf_s2;
    assign overflow_sticky  = of_s2;

endmodule
