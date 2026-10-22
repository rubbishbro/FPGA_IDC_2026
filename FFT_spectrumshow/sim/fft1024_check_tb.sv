`timescale 1ns/1ps
module fft1024_check_tb;
    logic clk=0, rst_n=0, ce=1, start=0;
    logic signed [15:0] x_re=0;
    logic x_valid=0;
    wire signed [25:0] y_re, y_im;
    wire [9:0] y_idx;
    wire y_valid, ready, busy, done;
    reg [15:0] mem [0:1023];
    integer i, count=0, nonzero=0;
    integer maxmag=0, maxbin=0;

    always #15 clk=~clk;

    fft1024_iter dut(
        .clk(clk), .rst_n(rst_n), .ce(ce), .start(start),
        .x_re(x_re), .x_valid(x_valid), .ready(ready),
        .y_re(y_re), .y_im(y_im), .y_idx(y_idx), .y_valid(y_valid),
        .busy(busy), .done(done)
    );

    initial begin
        $readmemh("fft1024_in.mem", mem);
        repeat(5) @(posedge clk);
        rst_n=1; repeat(2) @(posedge clk);
        start=1; @(posedge clk); start=0;
        for(i=0;i<1024;i=i+1) begin
            x_re=mem[i]; x_valid=1; @(posedge clk);
        end
        x_valid=0;
        while(!done) begin
            @(posedge clk);
            if(y_valid) begin
                count=count+1;
                if(y_re!=0 || y_im!=0) nonzero=nonzero+1;
                if((y_re>maxmag)||(-y_re>maxmag)) begin maxmag = y_re>0?y_re:-y_re; maxbin=y_idx; end
                if(count<=5) $display("y[%0d] = %0d %0d", y_idx, $signed(y_re), $signed(y_im));
            end
        end
        $display("count=%0d nonzero=%0d maxmag=%0d maxbin=%0d", count, nonzero, maxmag, maxbin);
        $finish;
    end
endmodule
