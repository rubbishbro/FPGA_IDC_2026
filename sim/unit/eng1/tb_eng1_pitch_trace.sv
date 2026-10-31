`timescale 1ns/1ps
module tb_eng1_pitch_trace;
    logic clk=0,rst_n=0,tick=0,commit_ok=0,cv=0,cancel=0,source=0;
    logic [1:0] cleanup=0;
    logic [15:0] sources=16'haaaa;
    logic [31:0] data=0;
    logic ready,rejected,bank,busy,commit,pr,cw,sources_ready;
    logic [383:0] delta;
    logic [9:0] pa,ca;
    logic signed [31:0] low,base,high,slope,tag,a1;
    integer params[1024][5],fd,vf,rc;
    bit bad_tag=0,ack_before;
    always #5 clk=~clk;
    eng1_pitch dut(.clk(clk),.rst_n(rst_n),.clear(1'b0),.sample_tick(tick),.commit_ok(commit_ok),
        .cleanup(cleanup),.n_modes(7'd48),.slot_source(sources),.control_valid(cv),.control_cancel(cancel),
        .control_source(source),.control_data(data),.control_ready(ready),.control_rejected(rejected),
        .active_bank(bank),.busy(busy),.commit_pulse(commit),.active_delta(delta),.sources_ready(sources_ready),
        .p_re(pr),.p_addr(pa),.p_lower(low),.p_base(base),.p_upper(high),.p_slope(slope),.p_tag(tag),
        .co_we(cw),.co_addr(ca),.co_a1(a1));
    always @(posedge clk)if(pr)begin
        low<=params[pa][0];base<=params[pa][1];high<=params[pa][2];slope<=params[pa][3];tag<=bad_tag?0:params[pa][4];
    end
    initial begin
        vf=$fopen("pitch_params.txt","r");
        for(int i=0;i<1024;i++)rc=$fscanf(vf,"%d %d %d %d %d",params[i][0],params[i][1],params[i][2],params[i][3],params[i][4]);
        $fclose(vf);fd=$fopen("pitch_clock_trace.txt","w");
        repeat(4)@(negedge clk);rst_n=1;
        for(int c=0;c<40000;c++)begin
            @(negedge clk);
            tick=c%100==0;commit_ok=c%100>=60;cleanup=0;cancel=0;
            if(c==20)begin cv=1;source=0;data={4'd4,4'd0,7'd127,7'd127,10'd0};end
            if(c==10000)begin cv=1;source=1;data={4'd2,4'd0,7'd1,7'd127,10'd0};end
            if(c==16000)begin cv=1;source=1;data={4'd4,4'd0,7'd0,7'd0,10'd0};end
            if(c==21000)sources=~sources;
            if(c==23000)cleanup=1;
            if(c==26000)begin cv=1;source=0;data={4'd4,4'd0,7'd0,7'd0,10'd0};end
            if(c==27000)cancel=1;
            if(c==30000)begin bad_tag=1;cv=1;source=0;data={4'd4,4'd0,7'd127,7'd127,10'd0};end
            #1;
            ack_before=ready;
            $fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",c,tick,commit_ok,cv,source,data,cancel,cleanup,sources,bad_tag,ready,rejected,cw,ca,cw?a1:32'sd0);
            @(posedge clk);#1;
            $fwrite(fd," %0d %0d %0d %0d",bank,busy,commit,sources_ready);
            for(int s=0;s<16;s++)$fwrite(fd," %0d",$signed(delta[s*24 +:24]));
            $fwrite(fd,"\n");
            if(ack_before || cancel)cv=0;
        end
        $fclose(fd);$display("PASS tb_eng1_pitch_trace cycles=40000");$finish;
    end
endmodule
