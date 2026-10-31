`timescale 1ns/1ps
// Distinguishable history data must select the same curve/angle when a row is
// scanned in reverse; this exercises the CORDIC lookahead, not only x mapping.
module tb_polar_reverse_scan;
    logic clk=0,rst_n=0,valid=0;
    always #5 clk=~clk;
    logic [9:0] x=0,xr=799,y=240;
    wire [9:0] a,ar;
    logic [39:0] history=0,history_r=0;
    wire [5:0] r,g,b,rr,gr,br;
    lcd_polar_curve f(.clk(clk),.rst_n(rst_n),.frame_pulse(1'b0),.lcd_valid(valid),
        .pix_x(x),.pix_y(y),.curve_rd_addr(a),.curve_rd_data(history),.theme(1'b0),.hit(),.r(r),.g(g),.b(b));
    lcd_polar_curve #(.REVERSE_SCAN(1)) rev(.clk(clk),.rst_n(rst_n),.frame_pulse(1'b0),.lcd_valid(valid),
        .pix_x(xr),.pix_y(y),.curve_rd_addr(ar),.curve_rd_data(history_r),.theme(1'b0),.hit(),.r(rr),.g(gr),.b(br));
    function automatic [39:0] values(input integer col);
        return {10'(90+col/8),10'(140+col/7),10'(210+col/6),10'(280+col/5)};
    endfunction
    always @(posedge clk)begin
        if(a>767 || ar>767)$fatal(1,"polar history address outside 768 columns");
        history<=values(a);history_r<=values(ar);
    end
    logic [17:0] row0[0:799],row1[0:799];
    integer checked=0;
    initial begin
        for(integer row=80;row<=400;row+=40)begin
            rst_n=0;valid=0;
            repeat(4)@(negedge clk);rst_n=1;
            y=10'(row);repeat(24)@(negedge clk);
            for(integer col=0;col<1192;col++)begin
                @(negedge clk);valid=col<800;x=10'(col);xr=col<800 ? 10'(799-col) : 10'd799;
                @(posedge clk);#1;
                if(col<800)begin
                    row0[col]={r,g,b};row1[col]={rr,gr,br};
                    if((^{r,g,b,rr,gr,br})===1'bx)$fatal(1,"unknown polar color");
                end
            end
            // No line-wrap lookahead crosses the central polar figure.
            for(integer col=160;col<640;col++)begin
                if(row1[col]!==row0[799-col])
                    $fatal(1,"polar reverse mismatch row=%0d x=%0d actual=%h expected=%h",row,col,row1[col],row0[799-col]);
                checked++;
            end
        end
        $display("PASS tb_polar_reverse_scan %0d curve/history pixels mirrored, bounded addresses",checked);
        $finish;
    end
endmodule
