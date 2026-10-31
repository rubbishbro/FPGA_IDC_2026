// =============================================================================
// tb_loader_ref -- 第 2 步：把**真的 weight_loader** 接到 W25Q128 基准模型上，
//                  检查它从 flash 里搬出来的数据对不对。
//
// 做法：
//   * 模型 + 4 位适配层（w25q_dut）当 flash，MEM.TXT 是我们的镜像（identity 映射）
//   * loader 按 SLOTS=16 / N_MODES=20 / inst=1（吉他）跑一次
//   * 每次 ld_we 就把 ld_addr / ld_co / ld_pm 记下来，和镜像里对应记录逐字段比
//   * 再跑一个"全 FF 空片"用例，验 err=1 且数据被填 0
//
// 期望：本次 ROM 里 0x5000 起就是吉他表（16 slot x 20 mode x 64 B）。
// =============================================================================
`timescale 1ns/1ps

module tb_loader_ref;
    localparam int SLOTS   = 16;
    parameter int N_MODES = 64;
    parameter int INST = 0;
    parameter MEM_FILE=(INST==1 ? "rtl/router/tools/guitar_flash.mem" : "rtl/router/tools/piano_flash.mem");
    localparam int REC_B   = 64;
    localparam int NBYTES  = SLOTS * N_MODES * REC_B;      // 65536 at 64 storage modes
    localparam int BASE    = INST * NBYTES;                // 0x10000 for INST=1, N_MODES=64
    parameter bit BLANK = 1'b0;                          // 1 = 空片用例
    localparam int MW2     = $clog2(N_MODES);              // mode 字段位宽（20 -> 5）
    localparam int VW2     = $clog2(SLOTS);                // slot 字段位宽（16 -> 4）

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                                   // 100 MHz

    logic        start = 1'b0;
    logic        busy, done, err;
    logic        ld_we;
    logic [$clog2(SLOTS*N_MODES):0] ld_addr;   // {sel, slot, mode}
    modal_step_pkg::coeff_t ld_co;
    router_pkg::mod_par_t   ld_pm;

    logic        cs_n, sck, dq_oe;
    logic [3:0]  dq_o, dq_i;
    wire  [3:0]  dq;                       // 必须声明成 net（模型和 TB 都往上驱动）

    assign dq    = dq_oe ? dq_o : 4'bzzzz;
    assign dq_i  = dq;

    w25q_dut u_flash (.cs_n(cs_n), .sck(sck), .dq(dq));

    weight_loader #(.SLOTS(SLOTS), .N_MODES(N_MODES), .CLK_HZ(100_000_000), .SCK_DIV(16))
    u_ld (
        .clk(clk), .rst_n(rst_n), .inst(4'(INST)), .start(start),
        .busy(busy), .done(done), .err(err),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_co(ld_co), .ld_pm(ld_pm),
        .qspi_cs_n(cs_n), .qspi_sck(sck),
        .qspi_dq_o(dq_o), .qspi_dq_oe(dq_oe), .qspi_dq_i(dq_i)
    );

    // ---- 期望镜像（直接读 .mem，byte-per-line）----
    logic [7:0] img [0:NBYTES-1];

    // ---- 抓到的写数据 ----
    int n_wr = 0, n_bad = 0, n_co = 0, n_pm = 0;
    logic [31:0] got_field [0:15];

    function automatic logic [31:0] rec_word(input int rec, input int fld);
        return {img[rec + fld*4], img[rec + fld*4 + 1], img[rec + fld*4 + 2], img[rec + fld*4 + 3]};
    endfunction

    // 每笔写都和镜像比：ld_addr = {sel, slot, mode}
    always @(posedge clk) begin
        if (rst_n && ld_we) begin
            int sel, sl, md, rec;
            logic [31:0] got [0:15];
            sel = ld_addr[MW2+VW2];
            sl  = ld_addr[MW2 +: VW2];
            md  = ld_addr[0  +: MW2];
            // 注意：N_MODES=20 -> 每 slot 20 条；ld_addr 里 mode 是 3 位（20<32）
            rec = (sl * N_MODES + md) * REC_B;      // 相对本表的偏移
            n_wr++;
            if (md < N_MODES && rec + REC_B <= NBYTES) begin
                got[0] = ld_co.a11; got[1] = ld_co.a12; got[2] = ld_co.a21; got[3] = ld_co.a22;
                got[4] = ld_co.gq;  got[5] = ld_co.gv;  got[6] = ld_co.wo;
                got[7] = 32'b0;
                got[8] = ld_pm.a11; got[9] = ld_pm.a12; got[10] = ld_pm.a22; got[11] = ld_pm.wo;
                got[12] = ld_pm.s11; got[13] = ld_pm.s12; got[14] = ld_pm.s22; got[15] = ld_pm.swo;
                // ld_co / ld_pm 是装配寄存器：写系数时 pm 那半是脏的，反之亦然。
                // 所以只比本次 sel 对应的那半区。
                for (int f = 0; f < 16; f++) begin
                    if (sel == 0 && f >= 7) continue;
                    if (sel == 1 && f < 8)  continue;
                    if (BLANK) begin
                        // 空片：loader 会把两张表全填 0
                        if (got[f] !== 32'h0) begin
                            n_bad++;
                            if (n_bad <= 6)
                                $display("    空片但数据非 0: sel=%0d slot=%0d mode=%0d fld=%0d got=%08h",
                                         sel, sl, md, f, got[f]);
                        end
                        continue;
                    end
                    if (got[f] !== rec_word(rec, f)) begin
                        n_bad++;
                        if (n_bad <= 12)
                            $display("    差异 sel=%0d slot=%0d mode=%0d fld=%0d: got=%08h exp=%08h",
                                     sel, sl, md, f, got[f], rec_word(rec, f));
                    end
                end
                if (sel == 0) n_co++;
                else          n_pm++;
            end else begin
                n_bad++;
                $display("    越界写: sel=%0d slot=%0d mode=%0d", sel, sl, md);
            end
        end
    end

    int n_done_beats = 0;
    always @(posedge clk) if (rst_n && done) n_done_beats++;

    task automatic run_load();
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        // 等 done（单拍）
        begin
            int guard;
            guard = 0;
            while (!done && guard < 12_000_000) begin
                @(posedge clk);
                guard++;
            end
            if (!done) $display("    !! 等 done 超时（guard=%0d）", guard);
            else       $display("    loader done，用时 %0d 拍（%0d us）", guard, guard / 100);
        end
    endtask

    initial begin
        // 期望镜像
        begin
            int fd, v, i;
            fd = $fopen(MEM_FILE, "r");
            if (fd == 0) begin $display("RESULT: FAIL（打不开 .mem）"); $finish; end
            i = 0;
            while ($fscanf(fd, "%h", v) == 1) begin
                // .mem 是"整个镜像"（含 inst 0 的 FF 区），本表从 BASE 开始
                if (i >= BASE && i < BASE + NBYTES) img[i - BASE] = 8'(v);
                i++;
            end
            $fclose(fd);
            $display("    镜像 %0d 字节；flash 基地址 0x%05X，slot0 mode0 的 a11 期望 = %08h",
                     NBYTES, BASE, rec_word(0, 0));
        end

        #5_000;                                    // 等模型上电
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("---- 用例 A：正常镜像 ----");
        run_load();
        repeat (10) @(posedge clk);
        $display("    写入笔数 %0d（系数 %0d + 参数 %0d），字段差异 %0d，err=%0d",
                 n_wr, n_co, n_pm, n_bad, err);

        if (n_bad == 0 && n_co == SLOTS * N_MODES && n_pm == SLOTS * N_MODES && err == BLANK)
            $display("RESULT: PASS（系数 %0d 条 + 参数 %0d 条，全部字段一致）", n_co, n_pm);
        else
            $display("RESULT: FAIL（系数 %0d 条 / 参数 %0d 条（应各 %0d），差异 %0d，err=%0d）",
                     n_co, n_pm, SLOTS * N_MODES, n_bad, err);
        $finish;
    end

    initial begin
        #80_000_000;
        $display("RESULT: FAIL（超时）");
        $finish;
    end
endmodule
