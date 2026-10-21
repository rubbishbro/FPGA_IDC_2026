// -----------------------------------------------------------------------------
// tb_voice_router.sv -- 全局 16 voice class/active 路由
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_voice_router;
    localparam int N=16;
    parameter int VW=4;

    logic clk=0, rst_n=0;
    logic note_on, note_off;
    logic [VW-1:0] voice;
    logic [1:0] cls;
    logic [N-1:0] aa,ba,ca,ea;
    logic [N-1:0] as,bs,cs,es;
    logic [N-1:0] ag,bg,cc;
    logic [N-1:0] va;
    logic [N*2-1:0] vc;

    int errors=0;

    voice_router #(.NUM_VOICES(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .note_on(note_on), .note_off(note_off), .voice(voice), .cls(cls),
        .a_active(aa), .b_active(ba), .c_active(ca), .e2_active(ea),
        .a_note_start(as), .b_note_start(bs), .c_note_start(cs), .e2_note_start(es),
        .a_gate(ag), .b_gate(bg), .c_choke(cc),
        .voice_active(va), .voice_class(vc)
    );

    always #5 clk = ~clk;

    task automatic on(input int v, input int c);
        begin
            @(negedge clk); note_on=1; voice=v[VW-1:0]; cls=c[1:0];
            @(posedge clk); @(negedge clk); note_on=0; #1;
        end
    endtask

    task automatic off(input int v);
        begin
            @(negedge clk); note_off=1; voice=v[VW-1:0];
            @(posedge clk); @(negedge clk); note_off=0; #1;
        end
    endtask

    initial begin
        note_on=0; note_off=0; voice='0; cls='0;
        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        on(0, 0);
        if (!aa[0] || !as[0] || !ag[0]) begin $display("FAIL A v0"); errors++; end
        if (bs[0] || cs[0] || es[0]) begin $display("FAIL v0 class"); errors++; end

        on(1, 1);
        if (!ba[1] || !bs[1] || !bg[1]) begin $display("FAIL B v1"); errors++; end
        on(2, 2);
        if (!ca[2] || !cs[2]) begin $display("FAIL C v2"); errors++; end
        on(3, 3);
        if (!ea[3] || !es[3]) begin $display("FAIL E2 v3"); errors++; end

        off(1);
        if (ba[1] || bg[1]) begin $display("FAIL B off"); errors++; end

        on(1, 2);
        if (!ca[1] || !cs[1]) begin $display("FAIL reuse v1 C"); errors++; end
        if (ba[1]) begin $display("FAIL old B still active"); errors++; end

        if (errors==0) $display("PASS tb_voice_router");
        else           $display("FAIL tb_voice_router errors=%0d", errors);
        $finish;
    end
endmodule
