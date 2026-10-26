`timescale 1ns/1ps
// =============================================================================
// tb_excitation -- 合并后的激励发生器（excitation_gen）脉冲序列检查
//
//   case A  N=0 PW=2 GAP=0 ：1 个脉冲、2 个采样宽，之后静音
//   case B  N=2 PW=2 GAP=3 ：3 个脉冲（2 高 3 低 循环），之后静音
//   case C  N=7 PW=1 GAP=1 ：按住期间一直 1 高 1 低；松开后停
//   case D  clear            ：burst 中途清状态，立即静音
//   case E  声部独立         ：只按 slot1，slot0 不受影响
//
// 驱动方式：TB 自己造 smp_tick（一拍高、一拍低），每次 tick 后 #1 采样 xmap，
// 不依赖被测模块自己的分频，免得跟其它 always 块抢时序。
//
// 运行（仓根目录）：
//   xvlog -sv rtl/math/pkg/fxp_pkg.sv rtl/drivers/pkg/pad_driver_pkg.sv ^
//             rtl/router/parts/excitation.sv rtl/router/tb_excitation.sv
//   xelab tb_excitation -s tb_ex --debug typical -timescale 1ns/1ps
//   xsim tb_ex --runall
// =============================================================================
module tb_excitation;

    localparam int SLOTS = 2;
    localparam int NS    = 80;          // 最多记录多少采样

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    logic        smp_tick;
    logic [5:0]  SHIFT;
    logic [15:0] PW_LEN, GAP_LEN;
    logic [2:0]  N_PULSE;
    logic        clear;
    pad_driver_pkg::mat4x4 fmap;
    logic [SLOTS-1:0] note_on;
    logic signed [15:0][31:0] xmap;
    logic        xmap_valid;

    excitation_gen #(.SLOTS(SLOTS)) dut (
        .clk(clk), .rst_n(rst_n), .clk_en(smp_tick),   // 内部叫 clk_en，当使能用
        .SHIFT(SHIFT), .PW_LEN(PW_LEN), .GAP_LEN(GAP_LEN), .N_PULSE(N_PULSE),
        .clear(clear), .fmap(fmap), .note_on(note_on),
        .xmap(xmap), .xmap_valid(xmap_valid)
    );

    int errors = 0;
    int seq [0:NS-1];              // 0 = 静音, 1 = 有激励
    int n_cap  = 0;

    // 一个采样节拍：高电平一拍，采样 xmap
    task automatic tick();
        @(negedge clk); smp_tick = 1'b1;
        @(posedge clk); #1;
        if (n_cap < NS) seq[n_cap] = (xmap[0] != 0) ? 1 : 0;
        n_cap = n_cap + 1;
        @(negedge clk); smp_tick = 1'b0;
    endtask

    task automatic ticks(input int n);
        for (int i = 0; i < n; i++) tick();
    endtask

    // 别用 string 拼接：xsim 2017.4 会在 string 累加上崩掉
    task automatic show(input string name, input int n);
        $write("  [%0s] ", name);
        for (int i = 0; i < n; i++) begin
            if (i < NS && seq[i]) $write("#"); else $write(".");
        end
        $write("\n");
    endtask

    // ------------------------------------------------------------------
    initial begin
        for (int i = 0; i < 16; i++) fmap.flat_d[i].val = 8'd200;
        rst_n    = 1'b0;
        smp_tick = 1'b0;
        clear    = 1'b0;
        note_on  = '0;
        SHIFT    = 6'd0;          // 力值直接当 x，便于观察
        PW_LEN   = 16'd2;
        GAP_LEN  = 16'd0;
        N_PULSE  = 3'd0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        $display("== excitation_gen：SLOTS=%0d ==", SLOTS);

        // ---- A：1 个脉冲，2 宽 ----
        PW_LEN = 16'd2; GAP_LEN = 16'd0; N_PULSE = 3'd0;
        note_on[0] = 1'b1;
        n_cap = 0; ticks(12);
        show("A", 12);
        if (!(seq[0] && seq[1] && !seq[2] && !seq[3]))
            begin errors++; $display("   !! A 期望 ##.. 开头（实际 %0d%0d%0d%0d）",
                                     seq[0], seq[1], seq[2], seq[3]); end

        // ---- B：3 个脉冲，2 高 3 低 ----
        note_on[0] = 1'b0; ticks(4);
        PW_LEN = 16'd2; GAP_LEN = 16'd3; N_PULSE = 3'd2;
        note_on[0] = 1'b1;
        n_cap = 0; ticks(20);
        show("B", 20);
        // 期望: ##...##...## 之后全 0
        if (!(seq[0] && seq[1] && !seq[2] && !seq[3] && !seq[4] &&
              seq[5] && seq[6] && !seq[7] && !seq[8] && !seq[9] &&
              seq[10] && seq[11] && !seq[12]))
            begin errors++; $display("   !! B 脉冲位置不对"); end

        // ---- C：N=7 按住一直发；松开停 ----
        note_on[0] = 1'b0; ticks(4);
        PW_LEN = 16'd1; GAP_LEN = 16'd1; N_PULSE = 3'd7;
        note_on[0] = 1'b1;
        n_cap = 0; ticks(12);
        show("C", 12);
        if (!(seq[0] && !seq[1] && seq[2] && !seq[3] && seq[4]))
            begin errors++; $display("   !! C 期望 #.#.# 交替"); end
        note_on[0] = 1'b0;                 // 松开
        ticks(4);
        n_cap = 0; ticks(8);
        for (int i = 0; i < 6; i++)
            if (seq[i] != 0) begin errors++; $display("   !! C 松开后还在发"); end

        // ---- D：burst 中途 clear ----
        note_on[0] = 1'b0; ticks(4);
        PW_LEN = 16'd2; GAP_LEN = 16'd3; N_PULSE = 3'd7;
        note_on[0] = 1'b1;
        ticks(4);                          // 发到一半
        clear = 1'b1; tick(); clear = 1'b0;
        ticks(2);
        n_cap = 0; ticks(10);
        for (int i = 0; i < 6; i++)
            if (seq[i] != 0) begin errors++; $display("   !! D clear 之后还在发"); end
        $display("  [D] clear 之后静音");

        // ---- E：声部独立（只按 slot1，slot0 不该动）----
        note_on = '0; ticks(4);
        PW_LEN = 16'd1; GAP_LEN = 16'd0; N_PULSE = 3'd0;
        note_on[1] = 1'b1;
        n_cap = 0; ticks(8);
        for (int i = 0; i < 8; i++)
            if (seq[i] != 0) begin errors++; $display("   !! E slot0 被 slot1 影响了"); end
        $display("  [E] 声部独立");

        // ---- F：clear 在**非节拍**的一拍上给 ----
        //   状态机只在 clk_en（smp_tick）上跑，所以 clear 必须挂起到下一个节拍才生效
        //   （F11：不挂起会漏掉，表现为"换了乐器还在发"）
        note_on = '0; ticks(4);
        PW_LEN = 16'd2; GAP_LEN = 16'd3; N_PULSE = 3'd7;
        note_on[0] = 1'b1;
        ticks(4);                              // 发到一半
        @(negedge clk); clear = 1'b1;          // 故意不在 tick 里给
        @(negedge clk); clear = 1'b0;
        ticks(2);
        n_cap = 0; ticks(10);
        for (int i = 0; i < 8; i++)
            if (seq[i] != 0) begin errors++; $display("   !! F 非节拍 clear 没生效"); end
        $display("  [F] 非节拍 clear（挂起后生效）");

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end

endmodule
