// -----------------------------------------------------------------------------
// tb_modal_voice_top.sv -- 顶层（引擎 + 双份 bank + 声部调度）的整段作业验证（xsim）
//
// 三组测试：
//   A. 单声部逐位对拍 —— 复用 modal_bank_ram 的黄金向量，证明"7 路并联 + 常数移位 +
//      五级流水"与原 TDM bank **逐位相同**；
//   B. 多声部 —— 同一次 start 里跑 2 个声部（钢琴/吉他各一），结果必须各归各位；
//   C. ping-pong —— 引擎跑 bank0 的 2 个声部时，把**另一组**声部装进 bank1（测试台检查
//      此时 busy 仍为 1，即装载真的发生在运行期间），再 `swap` 跑 bank1；两次结果都必须
//      与各自单跑一致，且不串声部。
//
// 向量格式同 gen_golden.py 的 emit_seq：
//     n_modes n_samples / <14>×n_modes 系数 / <n_samples> 激励 /
//     <n_samples> 期望 Σ wo·q / <2>×n_modes 末态
//
// 运行：pwsh -File rtl/simsynth/run_xsim_engine7.ps1
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_modal_voice_top;

    import modal_step_pkg::*;

    localparam int N_MODES = 8;
    localparam int X_DEPTH = 64;
    localparam int VOICES  = 2;

    localparam int CO_SLOT = $clog2(VOICES * N_MODES);   // 每份 bank 的地址位数（voice+mode）
    localparam int X_SLOT  = $clog2(VOICES * X_DEPTH);
    localparam int TB      = CO_SLOT + 1;                // 再加 bank 位
    localparam int XB      = X_SLOT + 1;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic                          co_we;
    logic [TB-1:0]                 co_addr;
    coeff_t                        co_data;

    logic                          st_we;
    logic [TB-1:0]                 st_addr;
    logic signed [QW-1:0]          st_q;
    logic signed [VW-1:0]          st_v;

    logic                          x_we;
    logic [XB-1:0]                 x_addr;
    logic signed [XW-1:0]          x_data;

    logic                          start;
    logic [$clog2(VOICES+1)-1:0]   n_voices;
    logic [$clog2(X_DEPTH+1)-1:0]  n_samples;
    logic [$clog2(N_MODES+1)-1:0]  n_modes;
    logic                          swap_en;
    logic                          run_bank;
    logic                          done;
    logic                          busy;

    logic                          rd_en;
    logic [XB-1:0]                 rd_addr;
    logic signed [YW-1:0]          rd_data;
    logic                          rd_valid;

    logic                          st_rd_en;
    logic [TB-1:0]                 st_rd_addr;
    logic                          st_rd_sel;
    logic signed [31:0]            st_rd_data;
    logic                          st_rd_valid;

    always #5 clk = ~clk;        // 100 MHz

    modal_voice_top #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH), .VOICES(VOICES)) dut (
        .clk(clk), .rst_n(rst_n),
        .co_we(co_we), .co_addr(co_addr), .co_data(co_data),
        .st_we(st_we), .st_addr(st_addr), .st_q(st_q), .st_v(st_v),
        .x_we(x_we), .x_addr(x_addr), .x_data(x_data),
        .start(start), .n_voices(n_voices), .n_samples(n_samples), .n_modes(n_modes),
        .swap_en(swap_en), .run_bank(run_bank), .done(done), .busy(busy),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .st_rd_en(st_rd_en), .st_rd_addr(st_rd_addr), .st_rd_sel(st_rd_sel),
        .st_rd_data(st_rd_data), .st_rd_valid(st_rd_valid)
    );

    int            n_bad;
    int            n_jobs;
    // 作业拍数统计（一帧应该是 N+8 拍）
    int            cyc_cnt;
    logic          cyc_en;

    always @(posedge clk) if (cyc_en) cyc_cnt++;

    // slot 0/1 = 两组向量（0：钢琴；1：吉他）
    int              nm [0:1];
    int              ns [0:1];
    coeff_t          cf [0:1][0:N_MODES-1];
    longint signed   xv [0:1][0:X_DEPTH-1];
    longint signed   yv [0:1][0:X_DEPTH-1];
    longint signed   fq [0:1][0:N_MODES-1];
    longint signed   fv [0:1][0:N_MODES-1];

    task automatic rd_int(input int fd, output longint signed v);
        int nread;
        nread = $fscanf(fd, "%d", v);
        if (nread != 1) begin
            $display("FAIL: unexpected end of golden file");
            $finish;
        end
    endtask

    // 把黄金向量读进 slot 号内存
    task automatic parse_file(input string path, input int slot);
        int            fd;
        longint signed v;
        int            i, m;

        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("FAIL: cannot open %s", path);
            n_bad++;
            return;
        end
        rd_int(fd, v); nm[slot] = v;
        rd_int(fd, v); ns[slot] = v;
        if (nm[slot] > N_MODES || ns[slot] > X_DEPTH) begin
            $display("FAIL: %s needs %0d modes / %0d samples (DUT %0d/%0d)",
                     path, nm[slot], ns[slot], N_MODES, X_DEPTH);
            n_bad++;
            $fclose(fd);
            return;
        end

        for (m = 0; m < nm[slot]; m++) begin
            rd_int(fd, v); cf[slot][m].a11 = v; rd_int(fd, v);
            rd_int(fd, v); cf[slot][m].a12 = v; rd_int(fd, v);
            rd_int(fd, v); cf[slot][m].a21 = v; rd_int(fd, v);
            rd_int(fd, v); cf[slot][m].a22 = v; rd_int(fd, v);
            rd_int(fd, v); cf[slot][m].gq  = v; rd_int(fd, v);
            rd_int(fd, v); cf[slot][m].gv  = v; rd_int(fd, v);
            rd_int(fd, v); cf[slot][m].wo  = v; rd_int(fd, v);
        end
        for (i = 0; i < ns[slot]; i++) rd_int(fd, xv[slot][i]);
        for (i = 0; i < ns[slot]; i++) rd_int(fd, yv[slot][i]);
        for (m = 0; m < nm[slot]; m++) begin
            rd_int(fd, fq[slot][m]);
            rd_int(fd, fv[slot][m]);
        end
        $fclose(fd);
    endtask

    // 把 slot 的系数/初值/激励装进 (bank, voice) 那个槽位
    task automatic load_slot(input int bank, input int voice, input int slot);
        int i, m;
        // 地址与数据必须在时钟沿之前就位（顺序错了会整体错位一格）
        co_we = 1'b1;
        for (m = 0; m < nm[slot]; m++) begin
            co_addr = TB'(bank * (VOICES*N_MODES) + voice * N_MODES + m);
            co_data = cf[slot][m];
            @(negedge clk);
        end
        co_we = 1'b0;

        st_we = 1'b1;
        for (m = 0; m < nm[slot]; m++) begin
            st_addr = TB'(bank * (VOICES*N_MODES) + voice * N_MODES + m);
            st_q    = '0;
            st_v    = '0;
            @(negedge clk);
        end
        st_we = 1'b0;

        x_we = 1'b1;
        for (i = 0; i < ns[slot]; i++) begin
            x_addr = XB'(bank * (VOICES*X_DEPTH) + voice * X_DEPTH + i);
            x_data = xv[slot][i][XW-1:0];
            @(negedge clk);
        end
        x_we = 1'b0;
        @(negedge clk);
    endtask

    task automatic start_job(input logic sw, input int nv);
        start     = 1'b1;
        swap_en   = sw;
        n_voices  = nv;
        n_samples = ns[0];
        n_modes   = nm[0];
        cyc_cnt   = 0;
        cyc_en    = 1'b1;
        @(negedge clk);
        start   = 1'b0;
        swap_en = 1'b0;
    endtask

    task automatic wait_done;
        wait (done === 1'b1);
        cyc_en = 1'b0;
        @(negedge clk);
        n_jobs++;
    endtask

    // 读回结果 RAM 与末态，与 (bank, voice, slot) 的期望逐项比对
    task automatic check_slot(input int bank, input int voice, input int slot,
                              input string tag);
        int            i, m, k;
        longint signed got;
        int            bad0;

        bad0 = n_bad;

        rd_en = 1'b1;
        for (i = 0; i < ns[slot]; i++) begin
            @(negedge clk);
            rd_addr = XB'(bank * (VOICES*X_DEPTH) + voice * X_DEPTH + i);
            @(negedge clk);
            got = rd_data;
            if (got !== yv[slot][i]) begin
                n_bad++;
                if (n_bad <= 8)
                    $display("MISMATCH %s y[%0d]: got %0d want %0d", tag, i, got, yv[slot][i]);
            end
        end
        rd_en = 1'b0;

        for (m = 0; m < nm[slot]; m++) begin
            for (k = 0; k < 2; k++) begin
                @(negedge clk);
                st_rd_addr = TB'(bank * (VOICES*N_MODES) + voice * N_MODES + m);
                st_rd_sel  = k[0];
                st_rd_en   = 1'b1;
                wait (st_rd_valid === 1'b1);
                got = st_rd_data;
                @(negedge clk);
                st_rd_en = 1'b0;
                if (got !== ((k == 0) ? fq[slot][m] : fv[slot][m])) begin
                    n_bad++;
                    if (n_bad <= 8)
                        $display("MISMATCH %s state %0d %s: got %0d want %0d",
                                 tag, m, (k == 0) ? "q" : "qdot", got,
                                 (k == 0) ? fq[slot][m] : fv[slot][m]);
                end
            end
        end
        @(negedge clk);
        $display("  %-10s bank%0d voice%0d slot%0d: %0d modes x %0d samples -> %s",
                 tag, bank, voice, slot, nm[slot], ns[slot], (n_bad == bad0) ? "ok" : "FAILED");
    endtask

    // 完整跑一个作业（装载 + 起跑 + 等 done + 校验），单声部路径
    task automatic run_one(input string path, input string tag);
        parse_file(path, 0);
        load_slot(0, 0, 0);
        start_job(1'b0, 1);
        wait_done;
        check_slot(0, 0, 0, tag);
    endtask

    initial begin
        n_bad  = 0;
        n_jobs = 0;
        cyc_cnt = 0;
        cyc_en  = 1'b0;
        co_we = 1'b0; co_addr = '0; co_data = '0;
        st_we = 1'b0; st_addr = '0; st_q = '0; st_v = '0;
        x_we  = 1'b0; x_addr  = '0; x_data = '0;
        start = 1'b0; n_voices = 1; n_samples = '0; n_modes = '0; swap_en = 1'b0;
        rd_en = 1'b0; rd_addr = '0;
        st_rd_en = 1'b0; st_rd_addr = '0; st_rd_sel = 1'b0;

        $display("=== modal_voice_top: job-level golden check ===");
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("-- A. 单声部逐位对拍（与 modal_bank_ram 同一批黄金向量）--");
        run_one("golden_seq_piano_1.txt",  "piano_1");
        run_one("golden_seq_guitar_1.txt", "guitar_1");
        run_one("golden_seq_piano.txt",    "piano_48");
        run_one("golden_seq_guitar.txt",   "guitar_48");

        $display("-- B. 多声部：一次 start 跑 2 个声部（钢琴 + 吉他）--");
        parse_file("golden_seq_piano_1.txt",  0);
        parse_file("golden_seq_guitar_1.txt", 1);
        load_slot(0, 0, 0);          // bank0 voice0 = 钢琴
        load_slot(0, 1, 1);          // bank0 voice1 = 吉他
        start_job(1'b0, 2);
        wait_done;
        check_slot(0, 0, 0, "multi");
        check_slot(0, 1, 1, "multi");

        $display("-- C. ping-pong：跑 bank0 时把另一组声部装进 bank1，再交换 --");
        // bank0: voice0=钢琴, voice1=吉他（原位重装，状态复位）
        load_slot(0, 0, 0);
        load_slot(0, 1, 1);
        start_job(1'b0, 2);
        // 引擎正在跑 bank0 的这段时间里，把**交换过顺序**的一组装进 bank1
        load_slot(1, 0, 1);          // bank1 voice0 = 吉他
        load_slot(1, 1, 0);          // bank1 voice1 = 钢琴
        if (busy !== 1'b1) begin
            n_bad++;
            $display("FAIL: bank1 装载结束时引擎已停（没有验证到运行中装载）");
        end
        wait_done;
        if (run_bank !== 1'b0) begin
            n_bad++;
            $display("MISMATCH ping-pong: run_bank=%0d want 0 after job A", run_bank);
        end
        check_slot(0, 0, 0, "pong-A");
        check_slot(0, 1, 1, "pong-A");

        // 交换：这次跑 bank1（内容与 bank0 交换过 ⇒ 能抓出 bank/voice 混线）
        start_job(1'b1, 2);
        if (run_bank !== 1'b1) begin
            n_bad++;
            $display("MISMATCH ping-pong: run_bank=%0d want 1 after swap", run_bank);
        end
        wait_done;
        check_slot(1, 0, 1, "pong-B");
        check_slot(1, 1, 0, "pong-B");

        // 再交换回去：bank0 重装一次（状态复位），验证 A/B 交替不串数据
        load_slot(0, 0, 0);
        load_slot(0, 1, 1);
        start_job(1'b1, 2);
        if (run_bank !== 1'b0) begin
            n_bad++;
            $display("MISMATCH ping-pong: run_bank=%0d want 0 after 2nd swap", run_bank);
        end
        wait_done;
        check_slot(0, 0, 0, "pong-A2");
        check_slot(0, 1, 1, "pong-A2");
        $display("  最后一个作业 %0d 拍（2 声部 x (%0d+8) 拍 + 声部切换开销）", cyc_cnt, nm[0]);

        $display("=== %0d jobs, %0d mismatches ===", n_jobs, n_bad);
        if (n_bad == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

endmodule
