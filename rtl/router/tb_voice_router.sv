`timescale 1ns/1ps
//          eng0 +          /  /
module tb_voice_router;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    pad_driver_pkg::mat4x4 fmap;
    router_pkg::instrument_e inst;
    router_pkg::reverb_preset preset;
    logic        reload = 0, start = 0, mod_req = 0;
    logic [4:0]  n_voices;
    logic [6:0]  n_modes;
    logic [6:0]  n_samples;
    logic        ready, busy, done, y_valid;
    logic signed [63:0] y_data;
    logic        ns_rd_en = 0, ns_rd_sel = 0;
    logic [11:0] ns_rd_addr = 0;
    logic signed [31:0] ns_rd_data;
    logic        ns_rd_valid;

    // 功能性 tb：把采样节拍调快（每 100 拍一个采样），好让包络/释放段在几十个作业里跑完
    voice_router #(.SR_HZ(1_000_000)) dut (
        .clk(clk), .rst_n(rst_n), .fmap(fmap), .inst(inst), .reverb_preset(preset),
        .reload(reload), .start(start),
        .n_voices(n_voices), .n_modes(n_modes), .n_samples(n_samples),
        .ready(ready), .busy(busy), .done(done),
        .y_valid(y_valid), .y_data(y_data),
        .qspi_cs_n(), .qspi_sck(), .qspi_dq_o(), .qspi_dq_oe(), .qspi_dq_i(4'b0),
        .ns_rd_en(ns_rd_en), .ns_rd_addr(ns_rd_addr), .ns_rd_sel(ns_rd_sel),
        .ns_rd_data(ns_rd_data), .ns_rd_valid(ns_rd_valid)
    );

    int fd, a11m,a11s,a12m,a12s,a21m,a21s,a22m,a22s,gqm,gqs,gvm,gvs,wom,wos;
    int n_yv = 0, n_nz = 0, n_mod_wr = 0;
    bit r2_ok = 0, body_ok = 0, rev_ok = 0;
    longint ymax = 0;

    always @(posedge clk) if (|dut.mod_co_we) begin
        n_mod_wr++;
        $display("  MODWR slot=%0d mode=%0d c0=%0d th=%0d a11=%0d we=%b",
                 dut.mod_slot, dut.mod_co_mode, dut.mod_c0_r, dut.mod_theta0_r,
                 dut.mod_co_wdata.a11, dut.mod_co_we);
    end

    // y_data 是腔体出来的样本；y_out[] 是腔体**前**的混音（voice_router 里写的）。
    // 两个一对比就能确认腔体真的接在路径上：直通乐器应逐位相等，吉他不等。
    longint ys [0:255];
    int     n_eq = 0, n_mix_nz = 0, n_diff = 0, n_mixnz = 0;
    bit     body_pass_ok = 0;

    always @(posedge clk) if (y_valid) begin
        if (n_yv < 256) ys[n_yv] = y_data;
        n_yv++;
        if (y_data != 0) n_nz++;
        if (y_data > ymax || -y_data > ymax) ymax = (y_data > 0) ? y_data : -y_data;
    end

    task automatic load_coefs();
        // 系数激励入库在 tools/ 下（原来是 rtl/simsynth 的 scratch，跟着目录一起没了）
        fd = $fopen("rtl/router/tools/golden_seq_piano.txt", "r");
        if (fd == 0) fd = $fopen("golden_seq_piano.txt", "r");
        if (fd == 0) fd = $fopen("../tools/golden_seq_piano.txt", "r");
        if (fd == 0) begin $display("FAIL: no golden_seq_piano.txt"); $finish; end
        for (int i = 0; i < 4; i++) begin
            void'($fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                a11m,a11s,a12m,a12s,a21m,a21s,a22m,a22s,gqm,gqs,gvm,gvs,wom,wos));
            dut.ca_a11[i] = a11m; dut.ca_a12[i] = a12m;
            dut.ca_a21[i] = a21m; dut.ca_a22[i] = a22m;
            dut.ca_gq[i]  = gqm;  dut.ca_gv[i]  = gvm;
            dut.ca_wo[i]  = wom;
        end
        $fclose(fd);
        $display("coefs loaded: a11=%0d a12=%0d a21=%0d wo=%0d", a11m, a12m, a21m, wom);
    endtask

    int dbg_n = 0;
    always @(posedge clk) begin
        #1;
        if (dut.xmap_valid && dbg_n < 10) begin
            $display("TICK fmap0=%0d xmap0=%0d x_ram0=%0d st=%0d fidx=%0d xw=%0b",
                     fmap.flat_d[0].val, dut.xmap[0], dut.x_ram[0], dut.state, dut.fidx, dut.xw_run);
            dbg_n++;
        end
    end

    initial begin
        router_pkg::reverb_preset rv_tmp;
        for (int i = 0; i < 16; i++) fmap.flat_d[i].val = 0;
        inst   = router_pkg::INST_PIANO;   // piano: eng0 + ADSR
        preset = router_pkg::REVERB_NONE;  // 先直通，验证腔体/混响都是透明的
        n_voices = 1; n_modes = 4; n_samples = 64;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        load_coefs();
        repeat (5) @(posedge clk);

        // 空作业：让 weight_loader 的先走完（否则按键脉冲会在加载期间被吃掉）
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        repeat (5) @(posedge clk);
        load_coefs();               // 加载器是占位实现，不真的写表，重新灌一次
        repeat (5) @(posedge clk);

        // ---- R1: 钢琴 + 混响 NONE ----
        fmap.flat_d[0].val = 8'd255;
        n_yv = 0; n_nz = 0; ymax = 0;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;

        wait (done);
        // 钢琴的腔体是直通段、混响是 NONE：y_data 必须逐位等于 y_out[]（腔体前混音）
        n_eq = 0;
        for (int i = 0; i < 64; i++) if (ys[i] == longint'(dut.y_out[i])) n_eq++;
        body_pass_ok = (n_eq == 64);
        $display("R1: yv=%0d nz=%0d ymax=%0d emap=%0d body+rev_passthru_eq=%0d/64",
                 n_yv, n_nz, ymax, dut.emap[0], n_eq);

        // ---- R1b: 换成 HALL 再按一次，输出必须和腔体前混音不同（证明预设真的到了混响）----
        preset = router_pkg::REVERB_HALL;
        fmap.flat_d[0].val = 8'd0;           // 先松键
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        fmap.flat_d[0].val = 8'd255;         // 再按（新的上升沿）
        n_yv = 0; n_nz = 0; ymax = 0;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        n_diff = 0; n_mixnz = 0;
        for (int i = 0; i < 64; i++)
            if (longint'(dut.y_out[i]) != 0) begin
                n_mixnz++;
                if (ys[i] !== longint'(dut.y_out[i])) n_diff++;
            end
        rev_ok = (n_mixnz > 8) && (n_diff >= n_mixnz / 2);
        $display("R1b: HALL  yv=%0d  mix_nz=%0d  和干声不同=%0d  rev_ok=%0b",
                 n_yv, n_mixnz, n_diff, rev_ok);
        preset = router_pkg::REVERB_NONE;

        // ---- R2: 松键后包络走 release，跑够采样后状态应归零 ----
        fmap.flat_d[0].val = 8'd0;
        for (int j = 0; j < 60; j++) begin       // 60 x 64 个采样，释放段一定走得完
            @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
            wait (done);
        end
        repeat (3) @(posedge clk);
        $display("R2: emap=%0d  q0=%0d v0=%0d  dead=%0b",
                 dut.emap[0], dut.q_ram[0], dut.v_ram[0], dut.voice_dead[0]);
        r2_ok = (dut.emap[0] == 0) && (dut.q_ram[0] == 0) && (dut.v_ram[0] == 0);

        // ---- R3: 吉他（有揉弦）—— 验证参数表读 + 调制器写系数 ----
        inst = router_pkg::INST_GUITAR;
        // 先跑一个空作业，让加载器（现在会真的写表）把所有表灌完
        fmap.flat_d[0].val = 8'd0;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        repeat (5) @(posedge clk);
        load_coefs();               // 加载器写的是 LFSR 占位数据，覆盖回真系数
        repeat (5) @(posedge clk);
        // 加载完成后再写参数（否则会被加载器覆盖）
        for (int m = 0; m < 4; m++) begin
            real th; th = (m == 3) ? 0.9 : (2.0*3.14159265*82.4*(m+1)/48000.0);
            dut.pm_c0 [m] = longint'($rtoi($cos(th)*1073741824.0));
            dut.pm_s0 [m] = longint'($rtoi($sin(th)*1073741824.0));
            dut.pm_gam[m] = 32'sd65536;
            dut.pm_th [m] = longint'($rtoi(th*1073741824.0));
            dut.pm_g  [m] = longint'($rtoi((1.0/48000.0)/th*1073741824.0));
        end
        n_mod_wr = 0; n_yv = 0; ymax = 0;
        fmap.flat_d[0].val = 8'd200;      // 有 aftertouch
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        repeat (5) @(posedge clk);
        // 吉他腔体不是直通：凡是腔体前混音非零的样本，腔体后必须和它不同
        n_eq = 0; n_mix_nz = 0;
        for (int i = 0; i < 64; i++) begin
            if (longint'(dut.y_out[i]) != 0) begin
                n_mix_nz++;
                if (ys[i] !== longint'(dut.y_out[i])) n_eq++;
            end
        end
        body_ok = (n_mix_nz >= 1) && (n_eq == n_mix_nz) && (ymax != 0) &&
                  ($signed(dut.u_body.coef_q[0]) == -1384742);   // 吉他段 0 的 b0
        $display("R3: guitar y_valid=%0d mod_writes=%0d a11=%0d emap=%0d",
                 n_yv, n_mod_wr, dut.ca_a11[0], dut.emap[0]);
        $display("R3b: body coef_q[0]=%0d ymax=%0d mix_nz=%0d differs=%0d body_ok=%0b",
                 $signed(dut.u_body.coef_q[0]), ymax, n_mix_nz, n_eq, body_ok);

        if (n_nz > 0 && ymax != 0 && r2_ok && n_mod_wr > 0 && body_ok && body_pass_ok && rev_ok)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
