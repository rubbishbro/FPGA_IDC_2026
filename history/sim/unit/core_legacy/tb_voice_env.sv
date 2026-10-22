// -----------------------------------------------------------------------------
// tb_voice_env.sv -- A/B/C 包络单测（iverilog）
//   A：start 后立即 1.0
//   B：gate=1 上升，gate=0 下降
//   C：start=1，choke 后下降且 choke 撤销后不回升
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_voice_env;

    logic clk = 0;
    logic rst_n = 0;

    logic start_a, start_b, start_c;
    logic gate_b, choke_c, done_c;
    logic [23:0] atk = 24'h01_0000;   // UQ0.24 ~1/256
    logic [23:0] rel = 24'h01_0000;

    logic [15:0] gain_a, gain_b, gain_c;
    logic [15:0] b_prev, c_prev;

    int errors = 0;

    voice_env u_a (
        .clk(clk), .rst_n(rst_n), .start(start_a), .gate(1'b1),
        .choke(1'b0), .done(1'b0), .cls(2'd0),
        .attack_step(atk), .release_step(rel), .gain(gain_a)
    );
    voice_env u_b (
        .clk(clk), .rst_n(rst_n), .start(start_b), .gate(gate_b),
        .choke(1'b0), .done(1'b0), .cls(2'd1),
        .attack_step(atk), .release_step(rel), .gain(gain_b)
    );
    voice_env u_c (
        .clk(clk), .rst_n(rst_n), .start(start_c), .gate(1'b1),
        .choke(choke_c), .done(done_c), .cls(2'd2),
        .attack_step(atk), .release_step(rel), .gain(gain_c)
    );

    always #5 clk = ~clk;

    task automatic check16(input string name, input logic [15:0] got,
                           input logic [15:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %-12s got=%04x exp=%04x", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_lt(input string name, input logic [15:0] got,
                            input logic [15:0] lim);
        begin
            if (!(got < lim)) begin
                $display("FAIL %-12s got=%04x not < %04x", name, got, lim);
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_gt(input string name, input logic [15:0] got,
                            input logic [15:0] lim);
        begin
            if (!(got > lim)) begin
                $display("FAIL %-12s got=%04x not > %04x", name, got, lim);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        start_a = 0; start_b = 0; start_c = 0;
        gate_b = 0; choke_c = 0; done_c = 0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // A: start -> 1.0
        @(negedge clk); start_a = 1;
        @(posedge clk); @(negedge clk); start_a = 0; #1;
        check16("A.gain", gain_a, 16'h8000);

        // B: start + gate -> attack
        @(negedge clk); start_b = 1; gate_b = 1;
        @(posedge clk); @(negedge clk); start_b = 0; #1;
        repeat (50) @(posedge clk);
        b_prev = gain_b;
        check_gt("B.attack", gain_b, 16'h0000);

        repeat (600) @(posedge clk);
        check_gt("B.near1", gain_b, 16'h7000);

        b_prev = gain_b;
        @(negedge clk); gate_b = 0;
        repeat (100) @(posedge clk); #1;
        check_lt("B.release", gain_b, b_prev);

        // C: start -> 1.0; choke -> fade; deassert choke -> no rise
        @(negedge clk); start_c = 1;
        @(posedge clk); @(negedge clk); start_c = 0; #1;
        check16("C.gain", gain_c, 16'h8000);

        @(negedge clk); choke_c = 1;
        repeat (80) @(posedge clk); #1;
        c_prev = gain_c;
        check_lt("C.fade", gain_c, 16'h8000);

        @(negedge clk); choke_c = 0;
        repeat (80) @(posedge clk); #1;
        check_lt("C.hold", gain_c, c_prev);

        if (errors == 0)
            $display("PASS tb_voice_env");
        else
            $display("FAIL tb_voice_env errors=%0d", errors);

        $finish;
    end

endmodule
