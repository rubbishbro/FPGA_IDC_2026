`timescale 1ns/1ps
module tb_seed_rom;
    logic clk=0;
    logic [1:0] addr;
    logic [63:0] data;
    int errors=0;
    seed_rom #(.DEPTH(4), .AW(2), .FILE("sim/unit/core/tb_seed.mem")) dut (
        .clk(clk), .addr(addr), .data(data)
    );
    always #5 clk=~clk;
    initial begin
        addr=0;
        @(posedge clk); #1; if (data !== 64'd1) begin $display("FAIL 0 %h",data); errors++; end
        addr=2; @(posedge clk); #1; if (data !== 64'd3) begin $display("FAIL 2 %h",data); errors++; end
        addr=3; @(posedge clk); #1; if (data !== 64'd4) begin $display("FAIL 3 %h",data); errors++; end
        if (errors==0) $display("PASS tb_seed_rom");
        else $display("FAIL tb_seed_rom errors=%0d", errors);
        $finish;
    end
endmodule
