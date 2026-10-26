`timescale 1ns/1ps
// =============================================================================
// tb_loader_flash -- weight_loader（真 W25Q64 四线 SPI 读）+ 行为级 flash 模型
//
//   1. 按 loader 的布局把一张"系数表"写进模型（大端字段）
//   2. 跑一次加载：检查写口每一笔的地址/数据，检查 done/err
//   3. 把模型全填 FF（没烧过的片子）再跑一次：必须 err=1
//   4. 报一个乐器的加载拍数，好按 flash 时序算时间
//
// 运行（仓根目录）：
//   xvlog -sv rtl/math/pkg/fxp_pkg.sv rtl/router/pkg/modal_step_pkg.sv \
//             rtl/router/pkg/router_pkg.sv rtl/router/loader.sv \
//             rtl/router/tb_loader_flash.sv
//   xelab tb_loader_flash -s tb_ld --debug typical -timescale 1ns/1ps
//   xsim tb_ld -runall
// =============================================================================

// -----------------------------------------------------------------------------
// W25Q64 行为模型：**四线（Quad）SPI 模式 0**，只实现 0x6B（Fast Read Quad Output）
//   8 钟指令（只有 DQ0 有数据）-> 6 钟地址（4 位一拍）-> 8 钟 dummy
//   -> 数据 4 位一拍，地址按字节自增
//   从机在下降沿换数据、主机在上升沿采（模式 0）
// -----------------------------------------------------------------------------
module w25q64_model #(
    parameter int BYTES = 4096
) (
    input  logic       cs_n,
    input  logic       sck,
    input  logic [3:0] dq_o,
    input  logic       dq_oe,
    output logic [3:0] dq_i
);

    logic [7:0]  mem [0:BYTES-1];
    logic [7:0]  cmd;
    logic [23:0] addr;
    int          nb;              // 已过的 SCK 上升沿数
    int          dn;              // 数据阶段已过的 nibble 数
    logic [3:0]  nib;             // 当前驱动的 4 位
    logic        data_ph;

    assign dq_i = data_ph ? nib : 4'b0000;

    always @(negedge cs_n) begin
        nb      <= 0;
        dn      <= 0;
        cmd     <= 8'h00;
        addr    <= 24'd0;
        nib     <= 4'h0;
        data_ph <= 1'b0;
    end

    // 上升沿：收指令 / 收地址 / 数 dummy / 数据阶段推进
    always @(posedge sck) if (!cs_n) begin
        if (nb < 8) begin
            cmd <= {cmd[6:0], dq_o[0]};
            nb  <= nb + 1;
        end else if (nb < 14) begin
            addr <= {addr[19:0], dq_o};
            nb   <= nb + 1;
        end else if (nb < 22) begin
            nb   <= nb + 1;
            if (nb == 21) data_ph <= 1'b1;
        end else begin
            // 数据阶段：每两个 nibble 前进一个字节
            if (dn % 2 == 1) addr <= addr + 24'd1;
            dn <= dn + 1;
        end
    end

    // 下降沿换数据（模式 0）
    always @(negedge sck) if (!cs_n && data_ph) begin
        nib <= (dn % 2 == 0) ? mem[addr][7:4] : mem[addr][3:0];
    end

endmodule


// -----------------------------------------------------------------------------
module tb_loader_flash;

    localparam int SLOTS      = 4;         // 小规模跑得快；布局与 16 声部一致
    localparam int N_MODES    = 4;         // 和 tools/flash_demo.mem 的布局一致
    localparam int MW_        = $clog2(N_MODES);
    localparam int NMP        = 1 << MW_;               // 每声部补齐后的槽数
    localparam int AW         = $clog2(SLOTS) + MW_;    // 低位 {slot, mode}
    localparam int LDW        = AW + 1;                 // 最高位选表
    localparam int TBL_BYTES  = SLOTS * N_MODES * 64;   // 每个声部一张表
    localparam int INST       = 2;         // 用 2 号乐器，验证基地址乘对了
    localparam int FLASH_BYTES = 4096;

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    logic        start, busy, done, err;
    logic [3:0]  inst;
    logic        ld_we;
    logic [LDW-1:0] ld_addr;
    modal_step_pkg::coeff_t   ld_co;
    router_pkg::mod_par_t     ld_pm;
    logic        cs_n, sck, dq_oe;
    logic [3:0]  dq_o, dq_i;

    // ------------------------------------------------------------------
    weight_loader #(
        .SLOTS(SLOTS), .N_MODES(N_MODES), .CLK_HZ(100_000_000),
        .SCK_DIV(8), .BLANK_WAIT(8)          // 顺便验证分频参数真的接进去了（SCK = CLK/8）
    ) dut (
        .clk(clk), .rst_n(rst_n), .inst(inst),
        .start(start), .busy(busy), .done(done), .err(err),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_co(ld_co), .ld_pm(ld_pm),
        .qspi_cs_n(cs_n), .qspi_sck(sck),
        .qspi_dq_o(dq_o), .qspi_dq_oe(dq_oe), .qspi_dq_i(dq_i)
    );

    w25q64_model #(.BYTES(FLASH_BYTES)) u_flash (
        .cs_n(cs_n), .sck(sck), .dq_o(dq_o), .dq_oe(dq_oe), .dq_i(dq_i)
    );

    // ------------------------------------------------------------------
    // 表内容：第 m 个模态的第 w 个字 = 0x1000_0000 | m<<8 | w<<4 | 5
    // ------------------------------------------------------------------
    // 图样带上声部号：flash 里每个 slot 是**独立**的一张表（不同音高）
    function automatic logic [31:0] pat(input int sl, input int m, input int w);
        pat = 32'h1000_0000 | (32'(sl) << 16) | (32'(m) << 8) | (32'(w) << 4) | 32'h5;
    endfunction

    task automatic program_table(input int ins, input bit blank_ff);
        int base;
        logic [31:0] w32;
        base = ins * TBL_BYTES;
        for (int sl = 0; sl < SLOTS; sl++) begin
            for (int m = 0; m < N_MODES; m++) begin
                for (int w = 0; w < 16; w++) begin
                    w32 = pat(sl, m, w);
                    for (int k = 0; k < 4; k++)
                        u_flash.mem[base + (sl*N_MODES + m)*64 + w*4 + k]
                            = blank_ff ? 8'hFF : w32[31-8*k -: 8];
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // 写口检查
    // ------------------------------------------------------------------
    int n_wr = 0, n_bad = 0;
    bit chk_data = 1'b1;        // 好表那一轮比对图样
    bit chk_zero = 1'b0;        // 坏表那一轮要求"写进去的全是 0"（填 0 兜底）

    always @(posedge clk) if (ld_we) begin
        int sel, addr, slot, mode;
        sel  = int'(ld_addr[LDW-1]);
        addr = int'(ld_addr[LDW-2:0]);
        n_wr = n_wr + 1;
        if (sel == 0) begin
            slot = addr / NMP;
            mode = addr % NMP;
            if (chk_data && (ld_co.a11 !== pat(slot, mode, 0) || ld_co.gq !== pat(slot, mode, 4) ||
                ld_co.wo  !== pat(slot, mode, 6))) begin
                n_bad++;
                if (n_bad <= 6)
                    $display("  BAD co  addr=%0d (slot %0d mode %0d) a11=%h gq=%h wo=%h",
                             addr, slot, mode, ld_co.a11, ld_co.gq, ld_co.wo);
            end
            if (chk_zero && (ld_co.a11 !== 32'sd0 || ld_co.gq !== 32'sd0 || ld_co.wo !== 32'sd0)) begin
                n_bad++;
                if (n_bad <= 6)
                    $display("  BAD(fill) co addr=%0d a11=%h gq=%h wo=%h", addr, ld_co.a11, ld_co.gq, ld_co.wo);
            end
        end else begin
            slot = addr / NMP;
            mode = addr % NMP;
            if (chk_data && (ld_pm.c0 !== pat(slot, mode, 8) || ld_pm.k21 !== pat(slot, mode, 14))) begin
                n_bad++;
                if (n_bad <= 6)
                    $display("  BAD pm  addr=%0d (slot %0d mode %0d) c0=%h k21=%h",
                             addr, slot, mode, ld_pm.c0, ld_pm.k21);
            end
            if (chk_zero && (ld_pm.c0 !== 32'sd0 || ld_pm.k21 !== 32'sd0)) begin
                n_bad++;
                if (n_bad <= 6)
                    $display("  BAD(fill) pm addr=%0d c0=%h k21=%h", addr, ld_pm.c0, ld_pm.k21);
            end
        end
    end

    // ------------------------------------------------------------------
    longint t0, cyc = 0;
    always @(posedge clk) cyc = cyc + 1;
    int err_seen = 0;
    int fd;

    task automatic run_load(input string name, input bit expect_err);
        n_wr = 0; n_bad = 0; err_seen = 0;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        repeat (2) @(posedge clk);
        if (err) err_seen = 1;
        $display("[%0s] 写口 %0d 笔（期望 %0d），错 %0d，err=%0b（期望 %0b），耗时 %0d 拍",
                 name, n_wr, 2*SLOTS*N_MODES, n_bad, err, expect_err, cyc - t0);
        if (n_wr != 2*SLOTS*N_MODES || n_bad != 0 || err !== expect_err) begin
            $display("RESULT: FAIL (%0s)", name);
            $finish;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        start = 1'b0;
        inst  = 4'(INST);
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        $display("== weight_loader：W25Q64 标准 SPI 读，SLOTS=%0d N_MODES=%0d inst=%0d ==",
                 SLOTS, N_MODES, INST);

        // 优先用 Python 打包出来的字节文件（这样 flash_image.py 的字节序/布局
        // 也被一起验证了）；没有就退回 tb 内部的图样
        fd = $fopen("rtl/router/tools/flash_demo.mem", "r");
        if (fd != 0) begin
            $fclose(fd);
            $readmemh("rtl/router/tools/flash_demo.mem", u_flash.mem);
            $display("   表来自 rtl/router/tools/flash_demo.mem（flash_image.py 打包）");
        end else begin
            program_table(INST, 1'b0);
            $display("   表来自 tb 内部图样（没找到 flash_demo.mem）");
        end
        t0 = cyc;
        run_load("good", 1'b0);

        // 一个乐器的加载拍数（按 N_MODES 线性）
        $display("   每模态 %0d 拍 -> N_MODES=80 时约 %0d 拍/乐器",
                 (cyc - t0) / N_MODES, ((cyc - t0) / N_MODES) * 80);

        program_table(INST, 1'b1);          // 没烧过的片子：全 FF
        chk_data = 1'b0;
        chk_zero = 1'b1;                    // 坏表要"填 0"：写进去的数据必须全是 0
        t0 = cyc;
        run_load("blank", 1'b1);

        // 全 0 的片子（典型是 QE 位没置、四线读回全 0）：同样判坏 + 填 0
        for (int i = 0; i < FLASH_BYTES; i++) u_flash.mem[i] = 8'h00;
        t0 = cyc;
        run_load("zero", 1'b1);

        $display("RESULT: PASS");
        $finish;
    end

endmodule
