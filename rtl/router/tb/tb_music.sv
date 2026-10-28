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
    parameter  int NSAMP  = 24000;           // 采样数：24000 = 0.5 s（够 FFT 出 2 Hz 分辨率）
    parameter  int PROBE  = 0;               // 1 = 打印前 40 个非零采样的各节点值
    parameter  int DBG    = 0;               // 1 = 前 4 个采样逐级打印（定位 X）
    parameter  int NOTE_SLOT = 0;            // 弹哪个 slot（镜像里 slot0 = midi40，每 slot +2 半音）
    parameter  int HOLD   = 20000;           // 按住多少采样后松键（剩下的是自由衰减）
    parameter  int ALL16  = 0;               // 1 = 开头 16 个键一起按下（测饱和）；0 = 只弹一个音

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

    // ---- W25Q128 基准模型（真 loader 的对手盘）----
    wire [3:0] qspi_dq;
    assign qspi_dq = qspi_dq_oe ? qspi_dq_o : 4'bzzzz;

    w25q_dut u_flash (.cs_n(qspi_cs_n), .sck(qspi_sck), .dq(qspi_dq));

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
        .qspi_dq_o(qspi_dq_o), .qspi_dq_oe(qspi_dq_oe), .qspi_dq_i(qspi_dq)
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
        begin
            int guard;
            guard = 0;
            while (!done && guard < 4_000_000) begin @(posedge clk); guard++; end
            if (guard >= 4_000_000) $display("    !! one_sample 等 done 超时");
        end
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        while (done)  @(posedge clk);
        while (!done) @(posedge clk);
    endtask

    // 力度：8 位。0 = 松键
    task automatic press(input int slot, input int val);
        fmap.flat_d[slot].val = 8'(val);
    endtask

    // ---- 加载写口覆盖统计：每个 (sel, slot) 有没有被写过 ----
    bit          wr_cov [0:1][0:15];
    int          n_ld_wr = 0;
    initial for (int i = 0; i < 16; i++) begin wr_cov[0][i] = 1'b0; wr_cov[1][i] = 1'b0; end

    always @(posedge clk) begin
        if (rst_n && dut.ld_we) begin
            n_ld_wr <= n_ld_wr + 1;
            wr_cov[dut.ld_addr[9]][dut.ld_addr[8:5]] <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // 系数直接从 flash 镜像读（tools/piano_flash.mem / guitar_flash.mem）
    //   运行期用 plusargs 选乐器/是否扫力度：
    //     xsim tb_mu -testplusarg INS=0|1 -testplusarg SWEEP=0|1
    //   INS=0 钢琴（inst 0，每 slot 64 模态，镜像从 0 开始）
    //   INS=1 吉他（inst 1，每 slot 20 模态，镜像从 16*20*64 开始）
    // ------------------------------------------------------------------
    int    ins_sel   = 0;
    int    sweep_sel = 0;
    int    nsamp_v   = 0;        // case.txt 第三个数：>0 时覆盖 NSAMP（快速调试用）
    int    act_modes = 64;          // 本乐器实际用的模态数（决定从镜像里读几条）
    int    img_modes = 64;          // 镜像里每 slot 有几条记录
    int    img_base  = 0;           // 本乐器的表在镜像里的起始字节
    localparam int REC_B = 64;
    localparam int IMG_BYTES = 3 * 16 * 64 * REC_B;     // 够大，两种乐器都能装
    logic [7:0]    img [0:IMG_BYTES-1];
    bit            img_loaded = 1'b0;

    function automatic logic signed [31:0] rec_word(input int rec, input int fld);
        return {img[rec + fld*4], img[rec + fld*4 + 1], img[rec + fld*4 + 2], img[rec + fld*4 + 3]};
    endfunction

    task automatic load_coefs();
        if (!img_loaded) begin
            if (ins_sel == 1) begin
                $readmemh("rtl/router/tools/guitar_flash.mem", img);
                act_modes = 20;  img_modes = 20;
                img_base  = 1 * 16 * 20 * REC_B;        // INST_GUITAR = 1
            end else begin
                $readmemh("rtl/router/tools/piano_flash.mem", img);
                act_modes = 64;  img_modes = 64;
                img_base  = 0;                          // INST_PIANO = 0
            end
            img_loaded = 1'b1;
        end
        for (int sl = 0; sl < 16; sl++) begin
            for (int m = 0; m < 4; m++)
                $display("    DBG dump mode%0d a11=%0d a12=%0d a21=%0d a22=%0d wo=%0d",
                         m, dut.ca_a11_a[(NOTE_SLOT%8)*64+m], dut.ca_a12_a[(NOTE_SLOT%8)*64+m],
                         dut.ca_a21_a[(NOTE_SLOT%8)*64+m], dut.ca_a22_a[(NOTE_SLOT%8)*64+m],
                         dut.ca_wo_a [(NOTE_SLOT%8)*64+m]);
            for (int m = 0; m < act_modes; m++) begin
                int rec, idx, pmidx;
                rec = img_base + (sl*img_modes + m) * REC_B;
                // 系数表拆成两个 bank：bank 内地址 = {slot mod HS, mode}
                idx = (sl % 8) * 64 + m;
                // 参数表**不拆 bank**：地址 = {slot, mode} = slot*NMP + mode
                pmidx = sl * 64 + m;
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
                // 调制参数表（8 个字）：4 基值 + 4 斜率，按 {slot, mode} 平铺
                dut.pm_a11[pmidx] = rec_word(rec, 8);  dut.pm_a12[pmidx] = rec_word(rec, 9);
                dut.pm_a22[pmidx] = rec_word(rec, 10); dut.pm_wo[pmidx]  = rec_word(rec, 11);
                dut.pm_s11[pmidx] = rec_word(rec, 12); dut.pm_s12[pmidx] = rec_word(rec, 13);
                dut.pm_s22[pmidx] = rec_word(rec, 14); dut.pm_swo[pmidx] = rec_word(rec, 15);
            end
        end
        $display("coefs from flash image: inst=%0d modes=%0d  slot0 a11=%0d a21=%0d pm_s12=%0d",
                 ins_sel, act_modes, dut.ca_a11_a[0], dut.ca_a21_a[0], dut.pm_s12[0]);
        $display("    DBG img base=%0d bytes52..55=%02h %02h %02h %02h -> word13=%0d",
                 img_base, img[img_base + 52], img[img_base + 53],
                 img[img_base + 54], img[img_base + 55], rec_word(img_base, 13));
    endtask

    // ------------------------------------------------------------------
    // 谱子：每个 slot 一个音高（镜像里 slot0=midi40、slot1=42、...），
    //   所以"弹哪个 slot"就是"弹哪个音"。这里一条 8 音小句子 + 最后一个长音。
    //   松键用 val=0；按住期间门控电平 = 1，ADSR/激励都靠它。
    // ------------------------------------------------------------------
    longint t0;

    // 自检计数
    int  n_x = 0;            // y_data 里出现 X 的帧数
    int  n_clip = 0;         // 饱和到 int64 边界的帧数
    int  n_probe = 0;        // PROBE 打了多少条
    logic signed [63:0] ymax_abs = '0;
    logic signed [63:0] mix_abs  = '0;      // |mix_q| 峰值（进腔体前）
    logic signed [63:0] body_abs = '0;      // |body_y| 峰值（进混响前）
    int  n_mix_sat = 0, n_body_sat = 0;     // 这两级各自贴边（饱和）的样本数
    // 探针：单模态状态峰值（和 Python 模型对拍，用来验定点标度）
    logic signed [31:0] q_abs = '0;

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
        // 用例选择走**文件**（xsim 的 -testplusarg 在 .bat 里会被 '=' 拆开，
        // 跟它较劲不划算）：_analysis/case.txt 三行：INS、SWEEP、采样数(<=0 用 NSAMP)
        begin : read_case
            int fd_c, r;
            fd_c = $fopen("_analysis/case.txt", "r");
            if (fd_c != 0) begin
                r = $fscanf(fd_c, "%d", ins_sel);
                r = $fscanf(fd_c, "%d", sweep_sel);
                r = $fscanf(fd_c, "%d", nsamp_v);
                $fclose(fd_c);
            end
            if (nsamp_v <= 0) nsamp_v = NSAMP;
        end
        inst          = (ins_sel == 1) ? router_pkg::INST_GUITAR : router_pkg::INST_PIANO;
        load_coefs();
        $display("    INS=%0d（%0s）  SWEEP=%0d", ins_sel,
                 (ins_sel == 1) ? "吉他" : "钢琴", sweep_sel);
        repeat (5) @(posedge clk);

        t0 = $time;
        for (int n = 0; n < nsamp_v; n++) begin
            // ---- 弹法：ALL16=1 是"开头 16 个键一起按下"（测饱和）；
            //     否则只弹 NOTE_SLOT 一个音，之后自由衰减 ----
            if (n == 40) begin
                // 力度 250 必须 > voice_router 的 NOTE_ON_TH(230)，否则按键根本不成立
                if (ALL16 != 0) begin
                    for (int k = 0; k < 16; k++) press(k, 8'd250);
                    $display("    [%0d] 16 个键**同时**按下，力度 250，按住 %0d 采样", n, HOLD);
                end else begin
                    press(NOTE_SLOT, (ins_sel == 1) ? 8'd240 : 8'd250);
                    $display("    [%0d] 按 slot %0d（镜像里 midi40 + 2*%0d），力度 %0d，按住 %0d 采样后松开",
                             n, NOTE_SLOT, NOTE_SLOT, (ins_sel == 1) ? 240 : 250, HOLD);
                end
            end
            // ---- SWEEP=1：按住期间力度走 232 -> 252 -> 232（揉弦）----
            //   必须一直 > NOTE_ON_TH(230)，否则会被当成松键；
            //   按临时映射 lambda=(fmap-242)<<21/2^30，这段对应 λ ≈ -0.021 .. +0.021
            if (sweep_sel == 2 && ins_sel == 1 && n > 60) begin
                fmap.flat_d[NOTE_SLOT].val = 8'd250;      // 固定 lambda=+0.015625
            end else if (sweep_sel == 1 && ins_sel == 1 && n > 200 && n < HOLD) begin
                int ph, v;
                // 揉弦 6 Hz：一个完整三角波周期 = 48000/6 = 8000 采样
                ph = ((n - 200) % 8000) * 200 / 8000;      // 0..199（上 100 / 下 100）
                v  = (ph < 100) ? (232 + ph * 23 / 100)
                                : (255 - (ph - 100) * 23 / 100);
                // ALL16 时 16 个声部一起扫（压力测试：16 音齐响 + 揉弦）
                if (ALL16 != 0) begin
                    for (int k = 0; k < 16; k++) fmap.flat_d[k].val = 8'(v);
                end else begin
                    fmap.flat_d[NOTE_SLOT].val = 8'(v);
                end
            end
            if (n == 40 + HOLD) begin
                if (ALL16 != 0) begin
                    for (int k = 0; k < 16; k++) press(k, 8'd0);
                    $display("    [%0d] 16 个键同时松开，之后自由衰减", n);
                end else begin
                    press(NOTE_SLOT, 8'd0);
                    $display("    [%0d] 松键，之后是 ADSR release + 自由衰减", n);
                end
            end
            one_sample();
            // ---- 前几个采样逐级打印：定位 X 从哪一级冒出来（DBG=1 时）----
            // 每 1000 采样打印一次"实际应用到系数上的调制"（查调制速率）
            if (DBG != 0 && n % 1000 == 0)
                $display("    MODTRK n=%0d fmap=%0d a12=%0d a11=%0d wo=%0d",
                         n, fmap.flat_d[NOTE_SLOT].val, dut.ca_a12_a[(NOTE_SLOT%8)*64],
                         dut.ca_a11_a[(NOTE_SLOT%8)*64], dut.ca_wo_a[(NOTE_SLOT%8)*64]);
            if (DBG != 0 && n < 4)
                $display("    DBG n=%0d y=%0d mix_q=%0d body_y=%0d emap=%0d x_q=%0d a11=%0d wo=%0d",
                         n, y_data, dut.mix_q, dut.body_y, dut.emap[NOTE_SLOT],
                         dut.x_q[NOTE_SLOT], dut.ca_a11_a[0], dut.ca_wo_a[0]);
            // ---- 探针：这一帧的四个节点（只在 PROBE=1 时打印前 40 个非零）----
            if (PROBE != 0 && n_probe < 40 && (y_data != 0 || dut.mix_q != 0)) begin
                $display("      probe[%0d] mix_q=%0d body_y=%0d q4=%0d x4=%0d emap4=%0d",
                         n, dut.mix_q, dut.body_y, dut.q_ram_a[NOTE_SLOT*64],
                         dut.x_q[NOTE_SLOT], dut.emap[NOTE_SLOT]);
                n_probe = n_probe + 1;
            end
            if (^y_data === 1'bx) n_x = n_x + 1;
            if (y_data == 64'sh7FFF_FFFF_FFFF_FFFF || y_data == -64'sh7FFF_FFFF_FFFF_FFFF)
                n_clip = n_clip + 1;
            if (y_data > ymax_abs || -y_data > ymax_abs) ymax_abs = (y_data > 0) ? y_data : -y_data;
            if (dut.q_ram_a[NOTE_SLOT*64] > q_abs || -dut.q_ram_a[NOTE_SLOT*64] > q_abs)
                q_abs = (dut.q_ram_a[NOTE_SLOT*64] > 0) ? dut.q_ram_a[NOTE_SLOT*64] : -dut.q_ram_a[NOTE_SLOT*64];
            if (dut.mix_q  > mix_abs  || -dut.mix_q  > mix_abs)  mix_abs  = (dut.mix_q  > 0) ? dut.mix_q  : -dut.mix_q;
            if (dut.body_y > body_abs || -dut.body_y > body_abs) body_abs = (dut.body_y > 0) ? dut.body_y : -dut.body_y;
        end

        $display("渲染完成：%0d 个采样（%0d us），仿真墙钟 %0d ms，输出 %0d 个值",
                 NSAMP, 64'(NSAMP)*1000000/64'(SR_HZ), ($time - t0)/1000000, n_out);
        $display("    flash 加载：写入 %0d 笔", n_ld_wr);
        begin
            int miss;
            miss = 0;
            for (int sl = 0; sl < 16; sl++)
                if (!(wr_cov[0][sl] && wr_cov[1][sl])) begin
                    miss++;
                    $display("    !! slot %0d 没写全：系数=%0b 参数=%0b", sl, wr_cov[0][sl], wr_cov[1][sl]);
                end
            if (miss == 0) $display("    loader 覆盖：16 个 slot × 2 个半区 全部写到 ✓");
            else           $display("    loader 覆盖：%0d 个 slot 没写全 ✗", miss);
        end
        // ---- DBG：逐模态扫一遍 slot NOTE_SLOT 的系数和状态（查调制写坏没）----
        if (DBG != 0) begin
            $display("    DBG mode scan (slot %0d): a11(Q28) a12(Q30) wo(Q29) q(Q24)   |q|>2^24 或 |a11|>2^28 会标 *",
                     NOTE_SLOT);
            for (int m = 0; m < 4; m++)
                $display("    DBG dump mode%0d a11=%0d a12=%0d a21=%0d a22=%0d wo=%0d",
                         m, dut.ca_a11_a[(NOTE_SLOT%8)*64+m], dut.ca_a12_a[(NOTE_SLOT%8)*64+m],
                         dut.ca_a21_a[(NOTE_SLOT%8)*64+m], dut.ca_a22_a[(NOTE_SLOT%8)*64+m],
                         dut.ca_wo_a [(NOTE_SLOT%8)*64+m]);
            for (int m = 0; m < act_modes; m++) begin
                int  qa, a11v;
                qa   = (NOTE_SLOT < 8) ? dut.q_ram_a[(NOTE_SLOT % 8) * 64 + m]
                                       : dut.q_ram_b[(NOTE_SLOT % 8) * 64 + m];
                a11v = (NOTE_SLOT < 8) ? dut.ca_a11_a[(NOTE_SLOT % 8) * 64 + m]
                                       : dut.ca_a11_b[(NOTE_SLOT % 8) * 64 + m];
                if ((qa > (1 << 24)) || (qa < -(1 << 24)) ||
                    (a11v > (1 << 28)) || (a11v < -(1 << 28)))
                    $display("    DBG * mode%0d a11=%0d q=%0d", m, a11v, qa);
            end
        end
        $display("探针：slot%0d mode0 状态峰值 |q| = %0d = %f（Q24；Python 模型 midi40 mode0 是 0.0277）",
                 NOTE_SLOT, q_abs, real'(q_abs) / 16777216.0);
        $display("自检：n_out=%0d（应 %0d）  n_x=%0d（应 0）  |ymax|=%0d（应 >0）  削波=%0d",
                 n_out, NSAMP, n_x, ymax_abs, n_clip);
        // 三级余量（都是 64 位有符号）：mix_q（进腔体）-> body_y（进混响）-> y_data
        //   括号里是"占 2^63-1 的百分之几"，四舍五入到 0.0001%
        $display("余量：mix_q %0d (%0d.%04d%%)  body_y %0d (%0d.%04d%%)  y_data %0d (%0d.%04d%%)  y 削波=%0d",
                 mix_abs,
                 mix_abs  / (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000),
                 (mix_abs  % (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000)) * 64'd10000
                     / (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000),
                 body_abs,
                 body_abs / (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000),
                 (body_abs % (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000)) * 64'd10000
                     / (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000),
                 ymax_abs,
                 ymax_abs / (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000),
                 (ymax_abs % (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000)) * 64'd10000
                     / (64'sh7FFF_FFFF_FFFF_FFFF / 64'd10000),
                 n_clip);
        if (n_out == NSAMP && n_x == 0 && ymax_abs > 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $fclose(fd);
        $finish;
    end

endmodule
