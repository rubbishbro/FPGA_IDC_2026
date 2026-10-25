`timescale 1ns/1ps
// =============================================================================
// tb_envelope -- 包络发生器的定点边界检查
//
//   A) ADSR 起音不许"溢出成负数"
//      A_STEP 取默认的 0x0100_0000：从 0 一路加上去正好命中 0x8000_0000。
//      原来靠 (lvl + A_STEP < lvl) 判溢出，只能抓住"绕回"（>= 2^32），
//      0x8000_0000 这种落在 [2^31, 2^32) 的和判不出来 —— 按有符号 Q1.31 读就是
//      -1.0，每次起音都会打一个满幅负峰。这里逐拍检查 emap >= 0。
//   B) ADSR 的 dead 只在 release 走完、电平归零之后才给
//   C) dyn0 的 fmap << SHIFT 越界时要钳在 0x7FFF_FFFF（有符号语义不翻负）
//   D) dyn0 的 dead = 没按住
//
// 运行（仓根目录）：
//   xvlog -sv rtl/drivers/pkg/pad_driver_pkg.sv rtl/router/parts/envelope.sv ^
//             rtl/router/tb_envelope.sv
//   xelab tb_envelope -s tb_env --debug typical -timescale 1ns/1ps
//   xsim tb_env --runall
// =============================================================================
module tb_envelope;

    localparam int SLOTS = 4;

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    // ---- ADSR ----
    logic        clk_en;
    logic [31:0] A_STEP, D_STEP, S_LEVEL, R_STEP;
    pad_driver_pkg::mat4x4 fmap;
    logic [SLOTS-1:0] note_on, note_gate;
    logic signed [15:0][31:0] emap;
    logic        emap_valid;
    logic [SLOTS-1:0] dead_a;

    envelope_ADSR #(.SLOTS(SLOTS)) u_adsr (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .A_STEP(A_STEP), .D_STEP(D_STEP), .S_LEVEL(S_LEVEL), .R_STEP(R_STEP),
        .fmap(fmap), .note_on(note_on), .note_gate(note_gate),
        .emap(emap), .emap_valid(emap_valid), .dead(dead_a)
    );

    // ---- dyn0（SHIFT 故意给 30，让 255<<30 越界）----
    logic signed [15:0][31:0] emap_d;
    logic        emap_d_valid;
    logic [SLOTS-1:0] dead_d;

    envelope_dyn0 #(.SLOTS(SLOTS), .SHIFT(30)) u_dyn (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .fmap(fmap), .note_on(note_on), .note_gate(note_gate),
        .emap(emap_d), .emap_valid(emap_d_valid), .dead(dead_d)
    );

    int errors = 0;
    int neg_cnt = 0, dead_early = 0, dead_late = 0;

    // 每拍检查：ADSR 的 emap 不许是负数
    always @(posedge clk) if (rst_n && clk_en) begin
        // 输出兜底钳位会把负数挡住，所以这里连**内部电平**一起检查：
        // 电平自己不许翻负（那才是根因），否则就是把问题藏在输出那一道钳位后面。
        if ($signed(emap[0]) < 0 || $signed(u_adsr.lvl[0]) < 0) begin
            neg_cnt++;
            if (neg_cnt <= 3)
                $display("   !! 包络翻负：emap=%0d lvl=0x%08h", emap[0], u_adsr.lvl[0]);
        end
    end

    task automatic tick();
        @(negedge clk); clk_en = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); clk_en = 1'b0;
    endtask

    task automatic ticks(input int n);
        for (int i = 0; i < n; i++) tick();
    endtask

    // ------------------------------------------------------------------
    initial begin
        for (int i = 0; i < 16; i++) fmap.flat_d[i].val = 8'd255;
        rst_n    = 1'b0;
        clk_en   = 1'b0;
        note_on  = '0;
        note_gate= '0;
        A_STEP   = 32'h0100_0000;      // 默认：正好命中 0x8000_0000
        D_STEP   = 32'h0010_0000;
        S_LEVEL  = 32'h2000_0000;
        R_STEP   = 32'h0100_0000;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        $display("== tb_envelope：SLOTS=%0d ==", SLOTS);

        // ---- 复位后应该是"空" ----
        if (dead_a[0] !== 1'b1) begin errors++; $display("   !! 复位后 ADSR dead 应为 1"); end
        if (dead_d[0] !== 1'b1) begin errors++; $display("   !! 复位后 dyn0 dead 应为 1"); end

        // ---- A) 起音：一路加到顶，检查不翻负 ----
        note_on[0] = 1'b1; note_gate[0] = 1'b1;
        ticks(200);                     // 0x0100_0000 x 128 = 0x8000_0000，够到顶
        $display("  A) 起音 200 拍后 emap=%0d (0x%08h)  负值拍数=%0d dead=%0b",
                 emap[0], emap[0], neg_cnt, dead_a[0]);
        if (neg_cnt != 0) begin errors++; $display("   !! 起音过程中出现了负包络"); end
        if ($signed(emap[0]) < 0)  begin errors++; $display("   !! 起音后 emap 仍是负数"); end
        if (dead_a[0] !== 1'b0) begin errors++; $display("   !! 按着的时候 dead 不该给"); end

        // ---- B) 松开：release 走完才给 dead ----
        note_gate[0] = 1'b0;
        dead_early = 0;
        for (int i = 0; i < 40; i++) begin
            tick();
            if (emap[0] != 0 && dead_a[0]) dead_early++;   // 还没归零就报空 = 错
        end
        if (dead_early != 0) begin errors++; $display("   !! release 没走完就报 dead（%0d 拍）", dead_early); end
        ticks(300);                     // R_STEP=0x0100_0000，满量程约 128 拍，够了
        $display("  B) 松开 340 拍后 emap=%0d dead=%0b", emap[0], dead_a[0]);
        if (emap[0] != 0)  begin errors++; $display("   !! release 之后 emap 没归零"); end
        if (dead_a[0] !== 1'b1) begin errors++; $display("   !! release 走完 dead 没给"); end

        // ---- C) dyn0：255 << 30 越界，必须钳在 0x7FFF_FFFF ----
        note_on[0] = 1'b0; note_gate[0] = 1'b1;   // 按住
        ticks(3);
        $display("  C) dyn0 按住：emap=0x%08h dead=%0b", emap_d[0], dead_d[0]);
        if ($signed(emap_d[0]) < 0) begin errors++; $display("   !! dyn0 钳位失效（翻负）"); end
        if (emap_d[0] !== 32'sh7FFF_FFFF) begin errors++; $display("   !! dyn0 没有钳到 0x7FFF_FFFF"); end
        if (dead_d[0] !== 1'b0) begin errors++; $display("   !! dyn0 按住时 dead 不该给"); end

        // ---- D) dyn0 松开 = 空 ----
        note_gate[0] = 1'b0;
        ticks(2);
        $display("  D) dyn0 松开：emap=%0d dead=%0b", emap_d[0], dead_d[0]);
        if (emap_d[0] != 0)  begin errors++; $display("   !! dyn0 松开后 emap 不为 0"); end
        if (dead_d[0] !== 1'b1) begin errors++; $display("   !! dyn0 松开后 dead 没给"); end

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end

endmodule
