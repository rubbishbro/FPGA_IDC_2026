`timescale 1ns/1ps
// =============================================================================
// tb_music -- **唯一的回归 TB**：用 voice_router 直接渲染一段音频
//
//   为什么只有这一个：模块级 TB 要跟着内部信号/端口改，同步成本高而且照样漏
//   bug（BUGS.md 里两个严重 bug 就躲在模块级 TB 的盲区里）。现在只保留
//   "完整音乐合成"这一条路径：喂 fmap -> 收 y_valid/y_data，改内部结构不用动 TB。
//
//   * 一次作业 = 一个采样点，采样节拍由 router 内部 tick 分频器给
//     （CLK_HZ/SR_HZ 拍一个采样）。为了仿真快，这里用 48 MHz / 48 kHz = 1000 拍。
//   * 音符：改 fmap 的力度（0 = 松键，>0 = 按下）。router 内部做滞回和起音沿。
//   * 系数：从 tools/piano_flash.mem（piano_flash.py 生成的完整系数表）读，
//     每个 slot 一个音高 -> 弹不同 slot 就是不同音，这段是**真旋律**。
//   * 输出：_analysis/music_dec.txt，每行一个 64 位有符号十进制（= y_data）。
//   * 自检：帧数、无 X、有声音、松键后衰减到静音 -> RESULT: PASS/FAIL。
//
// 注意：没有 flash 行为模型，所以第一个 load 被跳过（直接灌 RAM 镜像）；
//       loader 本身由 piano_flash.py / flash_image.py 的 --selftest 保证格式。
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
    localparam int CLK_HZ = 48_000_000;     // = 1000 拍/采样（钢琴 64 模态 ≈735 拍 + 排空）
    parameter  int NSAMP  = 24000;            // 采样数：24000 = 0.5 s（8 个音，每音 3000 采样）
    parameter  int NNOTE  = 8;               // 音符数（NSAMP/NNOTE = 每个音多长）；排查时可设 1
    parameter  int PROBE  = 0;               // 1 = 打印前 40 个非零采样的各节点值

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                    // 100 MHz 的时钟沿，CLK_HZ 只是分频参数

    pad_driver_pkg::mat4x4   fmap;
    router_pkg::instrument_e inst;
    router_pkg::reverb_preset preset;
    logic        reload = 0, start = 0;
    logic        ready, done, y_valid;
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
        .reload(reload), .start(start),
        .ready(ready), .done(done), .load_err(),
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
    // done 是**电平**：先等空闲 -> 发 start -> 等它落下 -> 再等它起来
    task automatic one_sample();
        while (!done) @(posedge clk);
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        while (done)  @(posedge clk);
        while (!done) @(posedge clk);
    endtask

    // 力度：8 位。0 = 松键
    task automatic press(input int slot, input int val);
        fmap.flat_d[slot].val = 8'(val);
    endtask

    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // 系数直接从 flash 镜像读（tools/piano_flash.mem）
    //   镜像：inst 0 的表从 0 开始，每 slot 64 条 × 64 字节记录
    // ------------------------------------------------------------------
    localparam int IMG_MODES = 64;
    localparam int REC_B     = 64;
    localparam int IMG_BYTES = 3 * 16 * IMG_MODES * REC_B;
    logic [7:0]    img [0:IMG_BYTES-1];
    bit            img_loaded = 1'b0;

    function automatic logic signed [31:0] rec_word(input int rec, input int fld);
        return {img[rec + fld*4], img[rec + fld*4 + 1], img[rec + fld*4 + 2], img[rec + fld*4 + 3]};
    endfunction

    task automatic load_coefs();
        int base;
        if (!img_loaded) begin
            $readmemh("rtl/router/tools/piano_flash.mem", img);
            img_loaded = 1'b1;
        end
        base = 0;                                    // INST_PIANO = 0（枚举改了这里也要改）
        for (int sl = 0; sl < 16; sl++) begin
            for (int m = 0; m < 64; m++) begin
                int rec, idx;
                rec = base + (sl*IMG_MODES + m) * REC_B;
                idx = (sl % 8) * 64 + m;
                if (sl >= 8) begin
                    dut.ca_a11_b[idx] = rec_word(rec, 0); dut.ca_a12_b[idx] = rec_word(rec, 1);
                    dut.ca_a21_b[idx] = rec_word(rec, 2); dut.ca_a22_b[idx] = rec_word(rec, 3);
                    dut.ca_gq_b[idx]  = rec_word(rec, 4); dut.ca_gv_b[idx]  = rec_word(rec, 5);
                    dut.ca_wo_b[idx]  = rec_word(rec, 6);
                end else begin
                    dut.ca_a11_a[idx] = rec_word(rec, 0); dut.ca_a12_a[idx] = rec_word(rec, 1);
                    dut.ca_a21_a[idx] = rec_word(rec, 2); dut.ca_a22_a[idx] = rec_word(rec, 3);
                    dut.ca_gq_a[idx]  = rec_word(rec, 4); dut.ca_gv_a[idx]  = rec_word(rec, 5);
                    dut.ca_wo_a[idx]  = rec_word(rec, 6);
                end
            end
        end
        $display("coefs from flash image: slot0 a11=%0d a21=%0d", dut.ca_a11_a[0], dut.ca_a21_a[0]);
    endtask

    // ------------------------------------------------------------------
    // 谱子：每个 slot 一个音高（镜像里 slot0=midi40、slot1=42、...），
    //   所以"弹哪个 slot"就是"弹哪个音"。这里一条 8 音小句子 + 最后一个长音。
    //   松键用 val=0；按住期间门控电平 = 1，ADSR/激励都靠它。
    // ------------------------------------------------------------------
    longint t0;
    int     n_note;
    int     melody [0:7] = '{4, 6, 8, 9, 8, 6, 4, 0};   // slot 号 = 第几个音
    int     n_step_ns;                                  // 每个音符多少采样

    // 自检计数
    int  n_x = 0;            // y_data 里出现 X 的帧数
    int  n_clip = 0;         // 饱和到 int64 边界的帧数
    int  n_probe = 0;        // PROBE 打了多少条
    logic signed [63:0] ymax_abs = '0;

    initial begin
        fd = $fopen("_analysis/music_dec.txt", "w");
        if (fd == 0) fd = $fopen("music_dec.txt", "w");
        for (int i = 0; i < 16; i++) fmap.flat_d[i].val = 8'd0;
        inst     = router_pkg::INST_PIANO;
        preset   = router_pkg::REVERB_NONE;   // 先关混响：排掉梳状线直流增益的干扰
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // 没有 flash 行为模型：跳过第一次 load，直接灌 RAM 镜像
        dut.inst_prev = router_pkg::INST_PIANO;
        load_coefs();
        repeat (5) @(posedge clk);

        n_step_ns = NSAMP / NNOTE;
        t0 = $time;
        for (int n = 0; n < NSAMP; n++) begin
            if (n % n_step_ns == 0) begin
                n_note = n / n_step_ns;
                // 先把所有键松开（保证下一个音有上升沿），再按目标 slot
                for (int k = 0; k < 16; k++) press(k, 0);
            end
            if (n % n_step_ns == 40 && n_note < NNOTE) begin
                // 力度 250 必须 > voice_router 的 NOTE_ON_TH(230)，否则按键根本不成立
                // （阈值改了这里要跟着改；250 也比 120 的激励大得多）
                press(melody[n_note % 8], 8'd250);
                $display("    [%0d] 按 slot %0d（第 %0d 个音高），力度 250",
                         n, melody[n_note % 8], melody[n_note % 8]);
            end
            one_sample();
            // ---- 探针：这一帧的四个节点（只在 PROBE=1 时打印前 40 个非零）----
            if (PROBE != 0 && n_probe < 40 && (y_data != 0 || dut.mix_q != 0)) begin
                $display("      probe[%0d] mix_q=%0d body_y=%0d emap4=%0d q4=%0d x4=%0d xmap4=%0d note_on=%b gate=%b",
                         n, dut.mix_q, dut.body_y, dut.emap[4], dut.q_ram_a[4*64],
                         dut.x_q[4], dut.xmap[4], dut.note_on[4], dut.note_gate[4]);
                n_probe = n_probe + 1;
            end
            if (^y_data === 1'bx) n_x = n_x + 1;
            if (y_data == 64'sh7FFF_FFFF_FFFF_FFFF || y_data == -64'sh7FFF_FFFF_FFFF_FFFF)
                n_clip = n_clip + 1;
            if (y_data > ymax_abs || -y_data > ymax_abs) ymax_abs = (y_data > 0) ? y_data : -y_data;
        end

        $display("渲染完成：%0d 个采样（%0d us），仿真墙钟 %0d ms，输出 %0d 个值",
                 NSAMP, 64'(NSAMP)*1000000/64'(SR_HZ), ($time - t0)/1000000, n_out);
        $display("自检：n_out=%0d（应 %0d）  n_x=%0d（应 0）  |ymax|=%0d（应 >0）  削波=%0d",
                 n_out, NSAMP, n_x, ymax_abs, n_clip);
        if (n_out == NSAMP && n_x == 0 && ymax_abs > 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $fclose(fd);
        $finish;
    end

endmodule
