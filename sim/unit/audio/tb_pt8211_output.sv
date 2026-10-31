`timescale 1ns/1ps
// Independent receiver: WS=0 right, WS=1 left, exactly 16 rising BCKs/slot.
module pt8211_scoreboard(
    input logic clk,rst_n,bck,ws,din,expected_valid,
    input logic [31:0] expected_pair,
    output integer frames,nonzero_frames,different_frames
);
    logic [31:0] expected[$];
    logic [31:0] current;
    logic [15:0] left,right;
    logic previous_ws,armed;
    integer bitno;
    always @(posedge clk)begin
        if(!rst_n)expected.delete();
        else if(expected_valid)expected.push_back(expected_pair);
    end
    always @(negedge ws or negedge rst_n)begin
        if(!rst_n)begin current=0;armed=0;end
        else begin
            if(expected.size()==0)$fatal(1,"FAIL PT8211 frame without paired FIFO token");
            current=expected.pop_front();armed=1;
        end
    end
    always @(posedge bck or negedge rst_n)begin
        if(!rst_n)begin previous_ws=0;bitno=0;left=0;right=0;frames=0;nonzero_frames=0;different_frames=0;end
        else begin
            if(ws!=previous_ws)bitno=0;else bitno++;
            if(armed)begin
                if(bitno>15)$fatal(1,"FAIL PT8211 slot length");
                if(ws)left={left[14:0],din};else right={right[14:0],din};
                if(ws && bitno==15)begin
                    if({left,right}!==current)$fatal(1,"FAIL PT8211 L/R bit order frame=%d got=%h/%h expected=%h",frames,left,right,current);
                    frames++;
                    if(current!=0)nonzero_frames++;
                    if(left!=right)different_frames++;
                end
            end
            previous_ws=ws;
        end
    end
endmodule

module tb_pt8211_output;
    logic clk=0,aclk=0,rst_n=0,active=0,yv=0;
    always #10 clk=~clk;
    initial begin #13;forever #40 aclk=~aclk;end
    logic signed [63:0] x=0;
    logic [5:0] pan=16;
    wire tick,bclk,ws,din,pb,pw,pd,late,overflow,underflow;
    i2s_audio_output #(.PT8211_ENABLE(1)) dut(
        .clk(clk),.audio_clk(aclk),.rst_n(rst_n),.active(active),.in_valid(yv),.in_data(x),
        .pan_position(pan),.itd_enable(1'b1),.sample_tick(tick),
        .amp_bclk(bclk),.amp_ws(ws),.amp_din(din),.dac_bck(pb),.dac_ws(pw),.dac_din(pd),
        .deadline_miss(late),.overflow(overflow),.underflow(underflow));
    wire [31:0] consumed=dut.rvalid?dut.rdata:32'd0;
    integer pf,pn,pdiffer,ifrm,inz,idiffer;
    pt8211_scoreboard pc(aclk,dut.arst_n,pb,pw,pd,dut.rready,consumed,pf,pn,pdiffer);
    i2s_stereo_scoreboard ic(aclk,dut.arst_n,bclk,ws,din,dut.rready,consumed,ifrm,inz,idiffer);
    realtime previous_boundary=0;
    always @(negedge pw)if(dut.arst_n)begin
        if(previous_boundary!=0 && $realtime-previous_boundary!=20480.0)$fatal(1,"FAIL PT8211 sample period");
        previous_boundary=$realtime;
    end
    always @(negedge rst_n)previous_boundary=0;
    always @(negedge clk)if(rst_n && (late||overflow||underflow))$fatal(1,"FAIL PT8211 bridge diagnostics");
    initial begin
        for(int epoch=0;epoch<2;epoch++)begin
            repeat(6)@(negedge clk);rst_n=1;
            for(int i=0;i<240;i++)begin
                @(posedge tick);@(negedge clk);
                active=i%60<50;pan=6'(i%33);
                x=(i[0]?-64'sd16000:64'sd12000)<<<12;yv=active;
                @(negedge clk);yv=0;
            end
            active=0;
            repeat(8)@(posedge tick);
            if(pf<240 || pn<100 || pdiffer<100 || ifrm<240 || inz<100 || idiffer<100)
                $fatal(1,"FAIL PT8211 simultaneous stereo coverage");
            $display("PT8211 epoch=%d frames=%d nonzero=%d distinct_LR=%d I2S=%d",epoch,pf,pn,pdiffer,ifrm);
            #137;rst_n=0;
        end
        $display("PASS tb_pt8211_output paired-stereo both-formats 48.828125kHz stop/reset");$finish;
    end
    initial begin #20000000;$fatal(1,"FAIL PT8211 test timeout");end
endmodule
