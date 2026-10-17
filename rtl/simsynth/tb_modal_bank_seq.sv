// -----------------------------------------------------------------------------
// tb_modal_bank_seq.sv -- TDM bank 的逐位比对（xsim）
//
// 复用 string_mode_step 的黄金向量：gen_golden.py 每个模态输出 4 行（4 个测试点），
// 每个音 4 个模态 ⇒ 每音 16 行；一行里的 (q, v, x) 就是该测试点的输入，q_exp/v_exp/y_exp
// 是并行一步模块的结果。bank 必须与它逐位一致，因此：
//
//   对每个音、每一类测试点：把 4 个模态装进 bank（初值取该行的 q/v），跑一帧，然后
//     * 逐模态读回状态，必须等于该行的 q_exp / v_exp
//     * y_sum 必须等于 4 个模态 y_exp 之和
//
// 同一个 DUT 依次跑钢琴与吉他的向量 —— 这同时验证了两种乐器复用同一模块。
//
// 运行：pwsh -File _analysis/rtl_modal/run_xsim_bank.ps1
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_modal_bank_seq;

    import modal_step_pkg::*;

    localparam int N_MODES       = 16;       // bank 容量
    localparam int MODES_PER_NOTE = 4;       // gen_golden.py 每音取 4 个模态
    localparam int ROWS_PER_MODE  = 4;       // gen_golden.py 每模态 4 个测试点
    localparam int ROWS_PER_NOTE  = MODES_PER_NOTE * ROWS_PER_MODE;
    localparam int MAX_ROWS      = 64;

    logic                        clk = 1'b0;
    logic                        rst_n = 1'b0;

    logic                        start;
    logic [$clog2(N_MODES+1)-1:0] n_modes;
    logic signed [XW-1:0]        x_in;

    logic                        st_we;
    logic [$clog2(N_MODES)-1:0]  st_addr;
    logic signed [QW-1:0]        st_q;
    logic signed [VW-1:0]        st_v;
    logic                        rd_en;
    logic signed [QW-1:0]        rd_q;
    logic signed [VW-1:0]        rd_v;
    logic                        rd_valid;

    logic [$clog2(N_MODES)-1:0]  c_addr;
    coeff_t                      c_data;
    coeff_t                      rom [0:N_MODES-1];      // 仿真用系数 ROM（同步读）

    logic signed [YW-1:0]        y_sum;
    logic                        frame_done;
    logic                        busy;

    always #5 clk = ~clk;                                 // 100 MHz

    always_ff @(posedge clk) c_data <= rom[c_addr];       // 1 拍延迟，与 DUT 的假设一致

    modal_bank_seq #(.N_MODES(N_MODES)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .n_modes(n_modes), .x_in(x_in),
        .st_we(st_we), .st_addr(st_addr), .st_q(st_q), .st_v(st_v),
        .rd_en(rd_en), .rd_q(rd_q), .rd_v(rd_v), .rd_valid(rd_valid),
        .c_addr(c_addr), .c_data(c_data),
        .y_sum(y_sum), .frame_done(frame_done), .busy(busy)
    );

    longint signed rows [0:MAX_ROWS-1][0:19];
    int            n_rows;
    int            n_bad;
    int            n_frames;
    int            n_checks;

    `define SCAN_FIELDS "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d"

    task automatic load_file(input string path);
        int            fd, nread;
        string         line;
        longint signed f[20];
        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("FAIL: cannot open %s", path);
            n_bad++;
            return;
        end
        while (!$feof(fd)) begin
            nread = $fgets(line, fd);
            if (nread == 0) break;
            nread = $sscanf(line, `SCAN_FIELDS,
                             f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8],
                             f[9], f[10], f[11], f[12], f[13], f[14], f[15],
                             f[16], f[17], f[18], f[19]);
            if (nread != 20) continue;
            if (n_rows < MAX_ROWS) begin
                for (int i = 0; i < 20; i++) rows[n_rows][i] = f[i];
                n_rows++;
            end
        end
        $fclose(fd);
    endtask

    // base 行的模态 m 的向量行号：base + m*ROWS_PER_MODE
    task automatic run_frame(input int base, input string src);
        longint signed y_want, y_got;
        longint signed want_q, want_v;
        longint signed got_q, got_v;
        logic signed [XW-1:0] xg;
        xg = rows[base][16];
        for (int m = 0; m < MODES_PER_NOTE; m++) begin
            if (rows[base + m * ROWS_PER_MODE][16] !== xg)
                $display("WARNING: %s base %0d: modes do not share x", src, base);
        end

        // 系数进 ROM
        for (int m = 0; m < MODES_PER_NOTE; m++) begin
            rom[m].a11 = rows[base + m * ROWS_PER_MODE][0];
            rom[m].s11 = rows[base + m * ROWS_PER_MODE][1][SW-1:0];
            rom[m].a12 = rows[base + m * ROWS_PER_MODE][2];
            rom[m].s12 = rows[base + m * ROWS_PER_MODE][3][SW-1:0];
            rom[m].a21 = rows[base + m * ROWS_PER_MODE][4];
            rom[m].s21 = rows[base + m * ROWS_PER_MODE][5][SW-1:0];
            rom[m].a22 = rows[base + m * ROWS_PER_MODE][6];
            rom[m].s22 = rows[base + m * ROWS_PER_MODE][7][SW-1:0];
            rom[m].gq  = rows[base + m * ROWS_PER_MODE][8];
            rom[m].sgq = rows[base + m * ROWS_PER_MODE][9][SW-1:0];
            rom[m].gv  = rows[base + m * ROWS_PER_MODE][10];
            rom[m].sgv = rows[base + m * ROWS_PER_MODE][11][SW-1:0];
            rom[m].wo  = rows[base + m * ROWS_PER_MODE][12];
            rom[m].swo = rows[base + m * ROWS_PER_MODE][13][SW-1:0];
        end

        // 状态初值来自向量行本身
        st_we = 1'b1;
        for (int m = 0; m < MODES_PER_NOTE; m++) begin
            @(negedge clk);
            st_addr = m[($clog2(N_MODES)-1):0];
            st_q    = rows[base + m * ROWS_PER_MODE][14][QW-1:0];
            st_v    = rows[base + m * ROWS_PER_MODE][15][VW-1:0];
        end
        @(negedge clk);
        st_we = 1'b0;

        // 跑一帧
        start   = 1'b1;
        n_modes = MODES_PER_NOTE[($clog2(N_MODES+1)-1):0];
        x_in    = xg;
        @(negedge clk);
        start = 1'b0;
        wait (frame_done == 1'b1);
        @(negedge clk);

        // y_sum = 各模态 y_exp 之和
        y_want = 0;
        for (int m = 0; m < MODES_PER_NOTE; m++)
            y_want += rows[base + m * ROWS_PER_MODE][19];
        y_got = y_sum;
        n_frames++;
        n_checks++;
        if (y_got !== y_want) begin
            n_bad++;
            $display("MISMATCH %s base %0d: y_sum=%0d want=%0d", src, base, y_got, y_want);
        end

        // 逐模态读回状态（rd_en 全程保持，地址在 negedge 给出）
        rd_en = 1'b1;
        for (int m = 0; m < MODES_PER_NOTE; m++) begin
            @(negedge clk);
            st_addr = m[($clog2(N_MODES)-1):0];
            @(negedge clk);
            got_q = rd_q;
            got_v = rd_v;
            want_q = rows[base + m * ROWS_PER_MODE][17];
            want_v = rows[base + m * ROWS_PER_MODE][18];
            n_checks++;
            if (got_q !== want_q || got_v !== want_v) begin
                n_bad++;
                $display("MISMATCH %s base %0d mode %0d: got q=%0d v=%0d want q=%0d v=%0d",
                         src, base, m, got_q, got_v, want_q, want_v);
            end
        end
        rd_en = 1'b0;
    endtask

    task automatic run_file(input string path);
        n_rows = 0;
        load_file(path);
        $display("  %s: %0d rows", path, n_rows);
        for (int g = 0; g + ROWS_PER_NOTE <= n_rows; g += ROWS_PER_NOTE)
            for (int c = 0; c < ROWS_PER_MODE; c++)
                run_frame(g + c, path);
    endtask

    initial begin
        n_rows   = 0;
        n_bad    = 0;
        n_frames = 0;
        n_checks = 0;
        start    = 1'b0;
        n_modes  = '0;
        x_in     = '0;
        st_we    = 1'b0;
        st_addr  = '0;
        st_q     = '0;
        st_v     = '0;
        rd_en    = 1'b0;

        $display("=== modal_bank_seq: TDM bank golden check ===");
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        run_file("golden_piano.txt");
        run_file("golden_guitar.txt");

        $display("=== %0d frames, %0d checks, %0d mismatches ===", n_frames, n_checks, n_bad);
        if (n_bad == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

endmodule
