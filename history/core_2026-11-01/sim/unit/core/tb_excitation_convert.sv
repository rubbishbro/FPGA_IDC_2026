`timescale 1ns/1ps
module tb_excitation_convert;
    logic [7:0] p; logic v; logic [15:0] vel; logic signed [31:0] x; logic ov;
    int errors=0;
    excitation_convert u(.pressure(p),.valid(v),.velocity(vel),.x(x),.out_valid(ov));
    initial begin
        p=8'd0; v=0; #1; if (vel!=0 || x!=0) begin $display("FAIL zero"); errors++; end
        p=8'd128; v=1; #1; if (vel!=16'd16384 || x!=32'sd536870912) begin $display("FAIL half vel=%0d x=%0d",vel,x); errors++; end
        p=8'd255; #1; if (x <= 0) begin $display("FAIL full"); errors++; end
        if (!ov) begin $display("FAIL valid"); errors++; end
        if (errors==0) $display("PASS tb_excitation_convert"); else $display("FAIL tb_excitation_convert errors=%0d",errors);
        $finish;
    end
endmodule
