`timescale 1ns/1ps
module tb_stereo_spatializer;
    parameter int MAX_ITD=4;
    logic clk=0,rst_n=0,sv=0,clear=0,itd=0;
    always #5 clk=~clk;
    logic [5:0] pan=16;
    logic signed [63:0] x=0;
    logic busy,ov;
    logic signed [83:0] yl,yr,el,er;
    logic [9:0] pos,dl,dr,ep,edl,edr;
    logic [12:0] gl,gr,egl,egr;
    integer fd,n,idx=0,cycles=0,received=0,start_cycle,latency;
    string filename;
    stereo_spatializer #(.ITD_MAX_SAMPLES(MAX_ITD)) dut(
        .clk(clk),.rst_n(rst_n),.sample_valid(sv),.clear(clear),.in_data(x),.pan_position(pan),.itd_enable(itd),
        .busy(busy),.out_valid(ov),.out_left(yl),.out_right(yr),.position_q4(pos),
        .gain_left_q12(gl),.gain_right_q12(gr),.delay_left_q6(dl),.delay_right_q6(dr));
    always @(posedge clk)cycles<=cycles+1;
    always @(negedge clk)if(rst_n && ov)begin
        received++;
        if(yl!==el || yr!==er || pos!==ep || gl!==egl || gr!==egr || dl!==edl || dr!==edr)
            $fatal(1,"FAIL stereo oracle max=%d row=%d L=%h/%h R=%h/%h pos=%d/%d gain=%d,%d/%d,%d delay=%d,%d/%d,%d",
                MAX_ITD,idx,yl,el,yr,er,pos,ep,gl,gr,egl,egr,dl,dr,edl,edr);
        latency=cycles-start_cycle;
        if(latency!=26)$fatal(1,"FAIL stereo latency %d",latency);
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",filename))$fatal(1,"FAIL missing VECTORS");
        // Run twice with a dirty reset between runs; RAM is intentionally not reset.
        repeat(2)begin
            rst_n=0;sv=0;repeat(4)@(negedge clk);rst_n=1;
            if(pos!==256 || dl!==0 || dr!==0 || ov!==0)$fatal(1,"FAIL reset state");
            fd=$fopen(filename,"r");if(!fd)$fatal(1,"FAIL vector file");
            while(!$feof(fd))begin
                @(negedge clk);
                n=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h\n",x,pan,itd,clear,el,er,ep,egl,egr,edl,edr);
                if(n!=11)$fatal(1,"FAIL vector row fields %d",n);
                if(busy)$fatal(1,"FAIL did not retire previous frame");
                idx++;sv=1;start_cycle=cycles+1;
                @(negedge clk);sv=0;x=~x;pan=~pan;itd=~itd;clear=~clear;
                repeat(30+(idx%7))@(negedge clk);
            end
            $fclose(fd);
        end
        if(received!=idx || received<2000)$fatal(1,"FAIL lost results %d/%d",received,idx);
        $display("PASS tb_stereo_spatializer max_itd=%0d vectors=%0d latency=26 gain/delay/slew/clear/extremes/reset",MAX_ITD,received);
        $finish;
    end
    initial begin #20000000;$fatal(1,"FAIL stereo timeout");end
endmodule
