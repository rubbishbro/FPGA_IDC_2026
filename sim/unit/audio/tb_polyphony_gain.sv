`timescale 1ns/1ps
module tb_polyphony_gain;
    parameter bit ENABLE=1;
    logic clk=0,rst_n=0,clear=0,in_valid=0,out_valid;
    always #5 clk=~clk;
    logic signed[63:0] in_data=0,out_data,expected;
    logic[4:0] voices=0;
    logic[12:0] gain_q12;
    integer fd,n,rows=0,c,v,k,ev,eg;
    string filename;
    polyphony_gain #(.ENABLE(ENABLE)) dut(.*);
    initial begin
        if(!$value$plusargs("VECTORS=%s",filename))$fatal(1,"missing vectors");
        repeat(4)@(negedge clk);rst_n=1;
        fd=$fopen(filename,"r");if(!fd)$fatal(1,"missing file");
        while(!$feof(fd))begin
            n=$fscanf(fd,"%d %d %h %d %d %h %d\n",c,v,in_data,k,ev,expected,eg);
            if(n!=7)$fatal(1,"bad row");
            clear=1'(c);in_valid=1'(v);voices=5'(k);
            @(posedge clk);#1;
            if(out_valid!==1'(ev) || (out_valid && out_data!==expected) || gain_q12!==13'(eg))
                $fatal(1,"FAIL gain row=%0d valid=%b/%0d data=%h/%h gain=%0d/%0d",rows,out_valid,ev,out_data,expected,gain_q12,eg);
            rows++;@(negedge clk);
        end
        $display("PASS tb_polyphony_gain enable=%0d rows=%0d fullrange/slew/clear/valid-gaps",ENABLE,rows);$finish;
    end
endmodule
