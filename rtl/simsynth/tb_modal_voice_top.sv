// -----------------------------------------------------------------------------
// tb_modal_voice_top.sv -- 顶层（引擎 + 多槽存储 + 状态 ping-pong）的整段作业验证
//
// 四组测试：
//   A. 单声部逐位对拍 —— 复用 modal_bank_ram 的黄金向量，证明"7 路并联 + 常数移位 +
//      五级流水 + 每帧 ping-pong"与原 TDM bank **逐位相同**；
//   B. 多声部 —— 同一次 start 里跑 2 个槽（钢琴/吉他各一），结果必须各归各位；
//   C. 运行中装载 —— 引擎跑槽 0 的时候把另一组系数装进槽 1（测试台检查 busy 仍为 1），
//      槽 0 的结果不能受影响；
//   D. 换音色重刷 —— 停机后整块刷系数再跑一遍，结果必须与"新开一次作业"完全一致。
//
// 向量格式同 gen_golden.py 的 emit_seq：
//     n_modes n_samples / <14>×n_modes 系数 / <n_samples> 激励 /
//     <n_samples> 期望 Σ wo·q / <2>×n_modes 末态
//
// 运行：pwsh -File rtl/simsynth/tb/run_xsim_engine7.ps1
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_modal_voice_top;

    import modal_step_pkg::*;

    localparam int N_MODES = 8;
    localparam int X_DEPTH = 64;
    localparam int SLOTS   = 2;

    localparam int CO_SLOT = $clog2(SLOTS * N_MODES);    // {槽号, 模态号}
    localparam int X_SLOT  = $clog2(SLOTS * X_DEPTH);

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic                          co_we;
    logic [CO_SLOT-1:0]            co_addr;
    coeff_t                        co_data;

    logic                          x_we;
    logic [X_SLOT-1:0]             x_addr;
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

    logic                          ns_rd_en;
    logic [CO_SLOT-1:0]            ns_rd_addr;
    logic                          ns_rd_sel;
    logic signed [31:0]            ns_rd_data;
    logic                          ns_rd_valid;

    always #5 clk = ~clk;        // 100 MHz

    modal_voice_top #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH), .SLOTS(SLOTS)) dut (
        .clk(clk), .rst_n(rst_n),
        .co_we(co_we), .co_addr(co_addr), .co_data(co_data),
        .x_we(x_we), .x_addr(x_addr), .x_data(x_data),
        .start(start), .n_voices(n_voices), .n_samples(n_samples), .n_modes(n_modes),
        .st_zero_mask(st_zero_mask),
        .done(done), .busy(busy),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .ns_rd_en(ns_rd_en), .ns_rd_addr(ns_rd_addr), .ns_rd_sel(ns_rd_sel),
        .ns_rd_data(ns_rd_data), .ns_rd_valid(ns_rd_valid)
    );

    int            n_bad;
    int            n_jobs;
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

        // 黄金向量所在目录（由 +GOLDEN_DIR= 指定，默认当前目录）——
    // 这样仿真产物可以统一落到 local/scratch，而向量仍留在源码目录
    string gdir;
    initial if (!$value$plusargs("GOLDEN_DIR=%s", gdir)) gdir = "";

task automatic rd_int(input int fd, output longint signed v);
        int nread;
        nread = $fscanf(fd, "%d", v);
        if (nread != 1) begin
            $display("FAIL: unexpected end of golden file");
            $finish;
        end
    endtask

    task automatic parse_file(input string path, input int slot);
        int            fd;
        longint signed v;
        int            i, m;

        fd = $fopen({gdir, path}, "r");
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

    // 把 slot 的系数/初值/激励装进 voice 号槽位
    task automatic load_slot(input int voice, input int slot);
        int i, m;
        co_we = 1'b1;
        for (m = 0; m < nm[slot]; m++) begin
            co_addr = CO_SLOT'(voice * N_MODES + m);
            co_data = cf[slot][m];
            @(negedge clk);
        end
        co_we = 1'b0;

        x_we = 1'b1;
        for (i = 0; i < ns[slot]; i++) begin
            x_addr = X_SLOT'(voice * X_DEPTH + i);
            x_data = xv[slot][i][XW-1:0];
            @(negedge clk);
        end
        x_we = 1'b0;
        @(negedge clk);
    endtask

    task automatic start_job(input int nv, input int nfr, input logic [SLOTS-1:0] mask);
        start        = 1'b1;
        n_voices     = nv;
        n_samples    = nfr;
        n_modes      = nm[0];
        st_zero_mask = mask;
        cyc_cnt   = 0;
        cyc_en    = 1'b1;
        @(negedge clk);
        start = 1'b0;
    endtask

    task automatic wait_done;
        wait (done === 1'b1);
        cyc_en = 1'b0;
        @(negedge clk);
        n_jobs++;
    endtask

    // 读回结果（每采样一个和）与末态（走"新状态读口"）
    task automatic check_y(input int s0, input int s1, input int two, input string tag);
        int            i;
        longint signed got, want;
        int            bad0;

        bad0  = n_bad;
        rd_en = 1'b1;
        for (i = 0; i < ns[s0]; i++) begin
            @(negedge clk);
            rd_addr = i[$clog2(X_DEPTH)-1:0];
            @(negedge clk);
            got  = rd_data;
            want = two ? (yv[s0][i] + yv[s1][i]) : yv[s0][i];
            if (got !== want) begin
                n_bad++;
                if (n_bad <= 8)
                    $display("MISMATCH %s y[%0d]: got %0d want %0d", tag, i, got, want);
            end
        end
        rd_en = 1'b0;
        $display("  %-10s y[0..%0d] (%0d 声部和) -> %s",
                 tag, ns[s0]-1, two ? 2 : 1, (n_bad == bad0) ? "ok" : "FAILED");
    endtask

    task automatic check_state(input int voice, input int slot, input string tag);
        int            m, k;
        longint signed got;
        int            bad0;

        bad0 = n_bad;
        for (m = 0; m < nm[slot]; m++) begin
            for (k = 0; k < 2; k++) begin
                @(negedge clk);
                ns_rd_addr = CO_SLOT'(voice * N_MODES + m);
                ns_rd_sel  = k[0];
                ns_rd_en   = 1'b1;
                wait (ns_rd_valid === 1'b1);
                got = ns_rd_data;
                @(negedge clk);
                ns_rd_en = 1'b0;
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
        $display("  %-10s voice%0d slot%0d state (%0d modes) -> %s",
                 tag, voice, slot, nm[slot], (n_bad == bad0) ? "ok" : "FAILED");
    endtask

    task automatic run_one(input string path, input string tag);
        parse_file(path, 0);
        load_slot(0, 0);
        start_job(1, ns[0], 1'b1);
        wait_done;
        check_y(0, 0, 0, tag);
        check_state(0, 0, tag);
    endtask

    initial begin
        n_bad  = 0;
        n_jobs = 0;
        cyc_cnt = 0;
        cyc_en  = 1'b0;
        co_we = 1'b0; co_addr = '0; co_data = '0;
        x_we  = 1'b0; x_addr  = '0; x_data = '0;
        start = 1'b0; n_voices = 1; n_samples = '0; n_modes = '0; st_zero_mask = '0;
        rd_en = 1'b0; rd_addr = '0;
        ns_rd_en = 1'b0; ns_rd_addr = '0; ns_rd_sel = 1'b0;

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

        $display("-- B. 多声部：一次 start 跑 2 个槽（钢琴 + 吉他）--");
        parse_file("golden_seq_piano_1.txt",  0);
        parse_file("golden_seq_guitar_1.txt", 1);
        load_slot(0, 0);
        load_slot(1, 1);
        start_job(2, ns[0], 2'b11);
        wait_done;
        check_y(0, 1, 1, "multi");
        check_state(0, 0, "multi");
        check_state(1, 1, "multi");

        $display("-- C. 运行中装载：跑槽 0 时把另一组装进槽 1 --");
        parse_file("golden_seq_piano.txt",    0);   // 48 帧，作业够长
        parse_file("golden_seq_guitar_1.txt", 1);
        load_slot(0, 0);
        start_job(1, ns[0], 1'b1);
        load_slot(1, 1);                            // 引擎还在跑槽 0
        if (busy !== 1'b1) begin
            n_bad++;
            $display("FAIL: 槽 1 装载结束时引擎已停（没有验证到运行中装载）");
        end
        wait_done;
        check_y(0, 0, 0, "live-ld");
        check_state(0, 0, "live-ld");

        $display("-- D. 换音色重刷：停机后整块刷系数，再跑一遍 --");
        parse_file("golden_seq_guitar.txt", 0);     // 48 帧吉他
        parse_file("golden_seq_piano.txt",  1);     // 48 帧钢琴
        // 两个槽整块换掉（换音色时本来也不弹，直接停机刷）
        load_slot(0, 0);                            // 槽 0 <- 吉他
        load_slot(1, 1);                            // 槽 1 <- 钢琴
        start_job(2, ns[0], 2'b11);
        wait_done;
        check_y(0, 1, 1, "reload");
        check_state(0, 0, "reload");
        check_state(1, 1, "reload");

        $display("=== %0d jobs, %0d mismatches ===", n_jobs, n_bad);
        if (n_bad == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

endmodule
