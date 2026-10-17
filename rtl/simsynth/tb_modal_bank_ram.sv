// -----------------------------------------------------------------------------
// tb_modal_bank_ram.sv -- modal_bank_ram 的整段作业验证（xsim）
//
// 流程完全按"顶层怎么用它"来：读黄金向量 -> 装载系数/激励/初值 -> start -> done
// -> 读结果 RAM 逐采样比对 -> 读末态比对。
//
// 向量是纯整数流（gen_golden.py 的 emit_seq）：
//     n_modes n_samples
//     <14> × n_modes      系数
//     <n_samples>         激励
//     <n_samples>         期望的 Σ wo·q（结果 RAM 内容）
//     <2> × n_modes       末态 q / q'
//
// 运行：pwsh -File _analysis/rtl_modal/run_xsim_ram.ps1
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_modal_bank_ram;

    import modal_step_pkg::*;

    localparam int N_MODES = 8;
    localparam int X_DEPTH = 64;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic                        co_we;
    logic [$clog2(N_MODES)-1:0]  co_addr;
    coeff_t                      co_data;

    logic                        st_we;
    logic [$clog2(N_MODES)-1:0]  st_addr;
    logic signed [QW-1:0]        st_q;
    logic signed [VW-1:0]        st_v;

    logic                        x_we;
    logic [$clog2(X_DEPTH)-1:0]  x_addr;
    logic signed [XW-1:0]        x_data;

    logic                        start;
    logic [$clog2(X_DEPTH+1)-1:0] n_samples;
    logic [$clog2(N_MODES+1)-1:0] n_modes;
    logic                        done;
    logic                        busy;

    logic                        rd_en;
    logic [$clog2(X_DEPTH)-1:0]  rd_addr;
    logic signed [YW-1:0]        rd_data;
    logic                        rd_valid;

    logic                        st_rd_en;
    logic [$clog2(N_MODES)-1:0]  st_rd_addr;
    logic                        st_rd_sel;
    logic signed [31:0]          st_rd_data;
    logic                        st_rd_valid;

    always #5 clk = ~clk;        // 100 MHz

    modal_bank_ram #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .co_we(co_we), .co_addr(co_addr), .co_data(co_data),
        .st_we(st_we), .st_addr(st_addr), .st_q(st_q), .st_v(st_v),
        .x_we(x_we), .x_addr(x_addr), .x_data(x_data),
        .start(start), .n_samples(n_samples), .n_modes(n_modes),
        .done(done), .busy(busy),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .st_rd_en(st_rd_en), .st_rd_addr(st_rd_addr), .st_rd_sel(st_rd_sel),
        .st_rd_data(st_rd_data), .st_rd_valid(st_rd_valid)
    );

    int              n_bad;
    int              n_frames_run;

    // 从当前文件位置读下一个整数
    task automatic rd_int(input int fd, output longint signed v);
        int nread;
        nread = $fscanf(fd, "%d", v);
        if (nread != 1) begin
            $display("FAIL: unexpected end of golden file");
            $finish;
        end
    endtask

    task automatic run_file(input string path);
        int              fd;
        longint signed   v, nm, ns;
        longint signed   xv [0:X_DEPTH-1];
        longint signed   yv [0:X_DEPTH-1];
        longint signed   fq [0:N_MODES-1];
        longint signed   fv [0:N_MODES-1];
        longint signed   got;
        longint signed   want;
        int              i, m, k;

        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("FAIL: cannot open %s", path);
            n_bad++;
            return;
        end

        rd_int(fd, nm);
        rd_int(fd, ns);
        if (nm > N_MODES || ns > X_DEPTH) begin
            $display("FAIL: %s needs %0d modes / %0d samples (DUT %0d/%0d)",
                     path, nm, ns, N_MODES, X_DEPTH);
            n_bad++;
            $fclose(fd);
            return;
        end

        // 装载系数：地址与数据都要在时钟沿**之前**就位（顺序错了会整体错位一格）
        co_we = 1'b1;
        for (m = 0; m < nm; m++) begin
            rd_int(fd, v); co_data.a11 = v; rd_int(fd, v); co_data.s11 = v[SW-1:0];
            rd_int(fd, v); co_data.a12 = v; rd_int(fd, v); co_data.s12 = v[SW-1:0];
            rd_int(fd, v); co_data.a21 = v; rd_int(fd, v); co_data.s21 = v[SW-1:0];
            rd_int(fd, v); co_data.a22 = v; rd_int(fd, v); co_data.s22 = v[SW-1:0];
            rd_int(fd, v); co_data.gq  = v; rd_int(fd, v); co_data.sgq = v[SW-1:0];
            rd_int(fd, v); co_data.gv  = v; rd_int(fd, v); co_data.sgv = v[SW-1:0];
            rd_int(fd, v); co_data.wo  = v; rd_int(fd, v); co_data.swo = v[SW-1:0];
            co_addr = m[($clog2(N_MODES)-1):0];
            @(negedge clk);
        end
        co_we = 1'b0;
        @(negedge clk);

        // 状态初值清零（同样：地址先就位）
        st_we = 1'b1;
        for (m = 0; m < nm; m++) begin
            st_addr = m[($clog2(N_MODES)-1):0];
            st_q    = '0;
            st_v    = '0;
            @(negedge clk);
        end
        st_we = 1'b0;
        @(negedge clk);

        x_we = 1'b1;
        for (i = 0; i < ns; i++) begin
            rd_int(fd, v);
            x_data = v[XW-1:0];
            x_addr = i[($clog2(X_DEPTH)-1):0];
            @(negedge clk);
        end
        x_we = 1'b0;

        // 期望结果与末态
        for (i = 0; i < ns; i++) rd_int(fd, yv[i]);
        for (m = 0; m < nm; m++) begin
            rd_int(fd, fq[m]);
            rd_int(fd, fv[m]);
        end
        $fclose(fd);

        // 跑一个作业
        start     = 1'b1;
        n_samples = ns[($clog2(X_DEPTH+1)-1):0];
        n_modes   = nm[($clog2(N_MODES+1)-1):0];
        @(negedge clk);
        start = 1'b0;
        wait (done == 1'b1);
        @(negedge clk);
        n_frames_run++;

        // 读结果 RAM 逐采样比对
        rd_en = 1'b1;
        for (i = 0; i < ns; i++) begin
            @(negedge clk);
            rd_addr = i[($clog2(X_DEPTH)-1):0];
            @(negedge clk);
            got = rd_data;
            if (got !== yv[i]) begin
                n_bad++;
                if (n_bad <= 6)
                    $display("MISMATCH %s y[%0d]: got %0d want %0d", path, i, got, yv[i]);
            end
        end
        rd_en = 1'b0;

        // 读末态（等 st_rd_valid 再取样，避免拍数对不上）
        for (m = 0; m < nm; m++) begin
            for (k = 0; k < 2; k++) begin
                @(negedge clk);
                st_rd_addr = m[($clog2(N_MODES)-1):0];
                st_rd_sel  = k[0];
                st_rd_en   = 1'b1;
                wait (st_rd_valid === 1'b1);
                got = st_rd_data;
                @(negedge clk);
                st_rd_en = 1'b0;
                want = (k == 0) ? fq[m] : fv[m];
                if (got !== want) begin
                    n_bad++;
                    if (n_bad <= 6)
                        $display("MISMATCH %s state mode %0d %s: got %0d want %0d",
                                 path, m, (k == 0) ? "q" : "qdot", got, want);
                end
            end
        end
        @(negedge clk);

        $display("  %s: %0d modes x %0d samples done", path, nm, ns);
    endtask

    initial begin
        n_bad        = 0;
        n_frames_run = 0;
        co_we = 1'b0; co_addr = '0; co_data = '0;
        st_we = 1'b0; st_addr = '0; st_q = '0; st_v = '0;
        x_we  = 1'b0; x_addr  = '0; x_data = '0;
        start = 1'b0; n_samples = '0; n_modes = '0;
        rd_en = 1'b0; rd_addr = '0;
        st_rd_en = 1'b0; st_rd_addr = '0; st_rd_sel = 1'b0;

        $display("=== modal_bank_ram: job-level golden check ===");
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        run_file("golden_seq_piano_1.txt");
        run_file("golden_seq_guitar_1.txt");
        run_file("golden_seq_piano.txt");
        run_file("golden_seq_guitar.txt");

        $display("=== %0d jobs, %0d mismatches ===", n_frames_run, n_bad);
        if (n_bad == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

endmodule
