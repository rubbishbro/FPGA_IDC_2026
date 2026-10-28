// =============================================================================
// 文件 : pad_voice_top.sv
// 模块 : pad_voice_top
// 功能 : pad_driver + voice_router 的端到端板级/仿真适配顶层
// 说明 : pad_driver 提供 4×4 压力矩阵；voice_router 内部已完成 fmap→note_on、
//        激励、包络、引擎、腔体、混响；本模块只负责时钟节拍、固定配置和启动。
//        摇杆原始采样接口供外部 joystick_adapter 使用。
// =============================================================================
`timescale 1ns/1ps

module pad_voice_top #(
    parameter int  CLK_HZ        = 100_000_000,
    parameter int  SR_HZ         = 48_000,
    parameter int  N_MODES       = 48,
    parameter int  SLOTS         = 16,
    parameter bit  USE_PAD_DRIVER = 1'b1
) (
    input  logic clk,
    input  logic rst_n,

    // 演奏配置
    input  router_pkg::instrument_e   inst,
    input  router_pkg::reverb_preset  reverb_preset,
    input  logic                      reload,
    input  logic                      run,          // 高电平=持续出采样

    // 运行时音源选择：0=pad_driver，1=fmap_ext（外部 MIDI/上位机桥接）
    // 注意：这是寄存器输入，不是 parameter；切换时只换 fmap 源。
    input  logic                      src_sel,

    // 仿真/Midi解析：USE_PAD_DRIVER=0 时使用外部 fmap
    input  pad_driver_pkg::mat4x4     fmap_ext,

    // pad_driver 原始接口（调试/外部模拟前端）
    output logic [3:0]                pad_row_s,
    output logic [2:0]                pad_ch_s,
    output pad_driver_pkg::mat4x4     pad_fmap,
    output pad_driver_pkg::vec2       pad_pos,
    output logic                      led_dat,

    // voice_router 输出
    output logic                      ready,
    output logic                      busy,
    output logic                      done,
    output logic                      y_valid,
    output logic signed [63:0]        y_data,

    // W25Q64 QSPI
    output logic                      qspi_cs_n,
    output logic                      qspi_sck,
    output logic [3:0]                qspi_dq_o,
    output logic                      qspi_dq_oe,
    input  logic [3:0]                qspi_dq_i,

    // 同 clk 域的成对摇杆采样，可直接接 joystick_adapter。
    output logic                     joy_sample_valid,
    output logic [13:0]              joy_raw_x,
    output logic [13:0]              joy_raw_y
);
    import clk_rst_pkg::*;
    import pad_driver_pkg::*;

    // pad_driver 要求有效时钟周期 400ns；100MHz 下 clk_en 每 40 拍一次。
    localparam int PAD_DIV = (CLK_HZ / 2_500_000); // 有效周期 400ns
    logic [7:0] pad_div;
    logic       pad_clk_en;
    clk_rst     pad_cr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pad_div    <= '0;
            pad_clk_en <= 1'b0;
        end else begin
            if (pad_div + 1 >= PAD_DIV[7:0]) begin
                pad_div    <= '0;
                pad_clk_en <= 1'b1;
            end else begin
                pad_div    <= pad_div + 1'b1;
                pad_clk_en <= 1'b0;
            end
        end
    end

    always_comb begin
        pad_cr.clk    = clk;
        pad_cr.clk_en = pad_clk_en;
        pad_cr.rst_n  = rst_n;
    end

    // ---- pad_driver：16 个压力单元 + 摇杆 ----
    pad_driver_pkg::input_param pad_in;
    generate
        if (USE_PAD_DRIVER) begin : g_pad
            pad_driver u_pad (
                .cr(pad_cr),
                .led_p('0),          // 本适配层不驱动 LED；需要时另接 visualizer
                .dat(led_dat),
                .input_p(pad_in),
                .joy_sample_valid(joy_sample_valid),
                .joy_raw_x(joy_raw_x),
                .joy_raw_y(joy_raw_y)
            );
        end else begin : g_no_pad
            assign pad_in.row_s = '0;
            assign pad_in.ch_s  = '0;
            assign pad_in.fmap  = '0;
            assign pad_in.pos   = '0;
            assign led_dat      = 1'b0;
            assign joy_sample_valid = 1'b0;
            assign joy_raw_x = '0;
            assign joy_raw_y = '0;
        end
    endgenerate

    assign pad_row_s = pad_in.row_s;
    assign pad_ch_s  = pad_in.ch_s;
    assign pad_fmap  = pad_in.fmap;
    assign pad_pos   = pad_in.pos;

    // ---- 运行时音源选择 ----
    // USE_PAD_DRIVER 只决定 pad_driver 是否综合进去；
    // src_sel_r 才是运行时可切换的寄存器。
    logic src_sel_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) src_sel_r <= 1'b0;
        else        src_sel_r <= src_sel;
    end

    pad_driver_pkg::mat4x4 fmap_use;
    assign fmap_use = (USE_PAD_DRIVER && !src_sel_r) ? pad_in.fmap : fmap_ext;

    // ---- 端到端：fmap 直接进 voice_router ----
    // voice_router 内部用滞回阈值生成 note_on/note_gate；
    // 16 个压力单元对应 16 个 slot，不需要外部 keycode/voice 分配。
    voice_router #(
        .SLOTS(SLOTS),
        .N_MODES(N_MODES),
        .CLK_HZ(CLK_HZ),
        .SR_HZ(SR_HZ)
    ) u_voice (
        .clk(clk),
        .rst_n(rst_n),
        .fmap(fmap_use),
        .inst(inst),
        .reverb_preset(reverb_preset),
        .reload(reload),
        .start(run),
        // n_voices / n_modes / n_samples 已经从 voice_router 删掉：
        //   声部数 = SLOTS 参数，模态数 = router_pkg::n_modes_of(inst)（内部定）。
        // busy 也没了（done 是电平，1 = 空闲可以 start）—— 这里给上层留个等价信号。
        .ready(ready),
        .done(done),
        .load_err(),
        .y_valid(y_valid),
        .y_data(y_data),
        .qspi_cs_n(qspi_cs_n),
        .qspi_sck(qspi_sck),
        .qspi_dq_o(qspi_dq_o),
        .qspi_dq_oe(qspi_dq_oe),
        .qspi_dq_i(qspi_dq_i),
        .ns_rd_en(1'b0),
        .ns_rd_addr('0),
        .ns_rd_sel(1'b0),
        .ns_rd_data(),
        .ns_rd_valid()
    );

    assign busy = ~done;      // 兼容旧接口：busy = "没在空闲"

endmodule
