`timescale 1ns/1ps
// =============================================================================
// tb_music -- 用 voice_router 直接"渲染"一段音频，输出给 Python 转 WAV
//
//   * 一次作业 = 一个采样点，采样节拍由 router 内部 tick 分频器给
//     （CLK_HZ/SR_HZ 拍一个采样）。为了仿真快，这里用 48 MHz / 48 kHz = 1000 拍，
//     留 1000-865 = 135 拍余量给每帧的其它开销。
//   * 音符：改 fmap 的力度（0 = 松键，200 = 重按）。router 内部做滞回和起音沿。
//   * 系数：与 tb_voice_router 一样从 tools/golden_seq_piano.txt 读 4 个模态
//     （真实钢琴表的子集），beat 靠 note_gate + ADSR + 激励串。
//   * 输出：_analysis/music_dec.txt，每行一个 64 位有符号十进制（= y_data）。
//
// 注意：现在**一张系数表只对应一个音高**（loader 把同一张表灌给全部 16 个声部），
//       所以这段"音乐"是同一音高的节奏，不是旋律。要出旋律得让每个声部有自己的
//       系数表（loader 布局改动），这是下一步的事。
//
// 运行（仓根目录）：
//   xvlog -sv rtl/math/pkg/fxp_pkg.sv rtl/drivers/pkg/clk_rst_pkg.sv ^
//             rtl/drivers/pkg/pad_driver_pkg.sv rtl/router/pkg/modal_step_pkg.sv ^
//             rtl/router/pkg/router_pkg.sv rtl/router/parts/*.sv rtl/router/engines/*.sv ^
//             rtl/router/routers/*.sv rtl/router/loader.sv rtl/router/voice_router.sv ^
//             rtl/router/tb_music.sv
//   xelab tb_music -s tb_mu --debug typical -timescale 1ns/1ps
//   xsim tb_mu --runall
// =============================================================================
module tb_music;

    localparam int SR_HZ  = 48000;
    localparam int CLK_HZ = 48_000_000;     // = 1000 拍/采样（作业 865 拍，留余量）
    parameter  int NSAMP  = 12000;           // 采样数：12000=0.25s, 48000=1s（可用 -generic_top 覆盖）
    parameter  int NPER   = 12000;           // 每 0.25 s 触键一次

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                    // 100 MHz 的时钟沿，CLK_HZ 只是分频参数

    pad_driver_pkg::mat4x4   fmap;
    router_pkg::instrument_e inst;
    router_pkg::reverb_preset preset;
    logic        reload = 0, start = 0;
    logic [4:0]  n_voices;
    logic [6:0]  n_modes;
    logic        ready, busy, done, y_valid;
    logic signed [63:0] y_data;
    logic [9:0]  ns_rd_addr = 0;
    logic        ns_rd_en = 0, ns_rd_sel = 0;
    logic signed [31:0] ns_rd_data;
    logic        ns_rd_valid;
    logic        qspi_cs_n, qspi_sck;
    logic [3:0]  qspi_dq_o;
    logic        qspi_dq_oe;

    voice_router #(
        .SLOTS(16), .N_MODES(64), .CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ), .DEBUG_PORT(1'b1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .fmap(fmap), .inst(inst), .reverb_preset(preset),
        .reload(reload), .start(start), .n_voices(n_voices), .n_modes(n_modes),
        .ready(ready), .busy(busy), .done(done),
        .y_valid(y_valid), .y_data(y_data),
        .ns_rd_en(ns_rd_en), .ns_rd_addr(ns_rd_addr), .ns_rd_sel(ns_rd_sel),
        .ns_rd_data(ns_rd_data), .ns_rd_valid(ns_rd_valid),
        .qspi_cs_n(qspi_cs_n), .qspi_sck(qspi_sck),
        .qspi_dq_o(qspi_dq_o), .qspi_dq_oe(qspi_dq_oe), .qspi_dq_i(4'b0)
    );

    // ------------------------------------------------------------------
    // 采集：每出来一个采样就写一行
    // ------------------------------------------------------------------
    int fd, n_out = 0;

    always @(posedge clk) if (y_valid) begin
        if (fd != 0) $fdisplay(fd, "%0d", y_data);
        n_out <= n_out + 1;
    end

    // ------------------------------------------------------------------
    // 一个作业 = 一个采样
    // ------------------------------------------------------------------
    task automatic one_sample();
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;
        wait (done);
        @(posedge clk);
    endtask

    // 力度：8 位。0 = 松键
    task automatic press(input int slot, input int val);
        fmap.flat_d[slot].val = 8'(val);
    endtask

    // ------------------------------------------------------------------
    // 读工具 golden_seq_piano.txt（4 个模态的真实钢琴系数）
    // ------------------------------------------------------------------
    int a11m,a11s,a12m,a12s,a21m,a21s,a22m,a22s,gqm,gqs,gvm,gvs,wom,wos;
    task automatic load_coefs();
        int f;
        f = $fopen("rtl/router/tools/golden_seq_piano.txt", "r");
        if (f == 0) f = $fopen("tools/golden_seq_piano.txt", "r");
        if (f == 0) f = $fopen("../tools/golden_seq_piano.txt", "r");
        if (f == 0) begin $display("FAIL: 找不到 golden_seq_piano.txt"); $finish; end
        for (int i = 0; i < 4; i++) begin
            void'($fscanf(f, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                a11m,a11s,a12m,a12s,a21m,a21s,a22m,a22s,gqm,gqs,gvm,gvs,wom,wos));
            // 灌给**全部 16 个声部**（loader 也是把同一张表灌给所有 slot），
            //   否则没灌到的声部系数是 X，累加出来整条链都是 X
            for (int sl = 0; sl < 16; sl++) begin
                int idx;
                idx = (sl % 8) * 64 + i;
                if (sl >= 8) begin
                    dut.ca_a11_b[idx] = a11m; dut.ca_a12_b[idx] = a12m;
                    dut.ca_a21_b[idx] = a21m; dut.ca_a22_b[idx] = a22m;
                    dut.ca_gq_b[idx]  = gqm;  dut.ca_gv_b[idx]  = gvm;
                    dut.ca_wo_b[idx]  = wom;
                end else begin
                    dut.ca_a11_a[idx] = a11m; dut.ca_a12_a[idx] = a12m;
                    dut.ca_a21_a[idx] = a21m; dut.ca_a22_a[idx] = a22m;
                    dut.ca_gq_a[idx]  = gqm;  dut.ca_gv_a[idx]  = gvm;
                    dut.ca_wo_a[idx]  = wom;
                end
            end
        end
        $fclose(f);
    endtask

    // ------------------------------------------------------------------
    // 谱子：0.25 秒里 4 下（每下 0.0625 s = 3000 采样），力度递增
    //   松键用 val=0；按住期间门控电平 = 1，ADSR/激励都靠它
    // ------------------------------------------------------------------
    longint t0;
    int     n_note;

    initial begin
        fd = $fopen("_analysis/music_dec.txt", "w");
        if (fd == 0) fd = $fopen("music_dec.txt", "w");
        for (int i = 0; i < 16; i++) fmap.flat_d[i].val = 8'd0;
        inst     = router_pkg::INST_PIANO;
        preset   = router_pkg::REVERB_HALL;
        n_voices = 5'd1;        // 单声部（系数表里 4 个模态）
        n_modes  = 7'd4;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // 跳过第一次 loader（假 flash 读出来全是 0），直接用真实系数
        dut.inst_prev = router_pkg::INST_PIANO;
        load_coefs();
        repeat (5) @(posedge clk);

        // 墙钟
        t0 = $time;
        for (int n = 0; n < NSAMP; n++) begin
            // 每 3000 采样一次触键：先松 40 拍再按，保证有上升沿
            if (n % NPER == 0) begin
                n_note = n / NPER;
                press(0, 0);
                for (int k = 1; k < 4; k++) press(k, 0);
            end
            if (n % NPER == 40) begin
                press(0, 120 + 40*n_note);
            end
            one_sample();
            if (n % NPER == 0) begin
                $display("    [%0d/%0d] t=%0t  y=%0d", n, NSAMP, $time, y_data);
            end
        end

        $display("渲染完成：%0d 个采样（%0d us），仿真墙钟 %0d ms，输出 %0d 个值",
                 NSAMP, (NSAMP*1000000)/SR_HZ, ($time - t0)/1000000, n_out);
        $fclose(fd);
        $finish;
    end

endmodule
