`timescale 1ns/1ps
module tb_eng1_post_trace;
    parameter int HEADROOM=3;
    logic clk=0,rst_n=0,iv=0,ov,sv,clear_req=0;
    logic signed [63:0] x=0,y;
    logic signed [83:0] left,right;
    logic [5:0] pan=16;
    logic itd=1,clear_sample=0;
    router_pkg::reverb_preset preset=router_pkg::REVERB_NONE;
    integer fd;
    logic [63:0] rng=64'h0123456789abcdef;
    always #5 clk=~clk;
    reverb_router rev(.clk(clk),.rst_n(rst_n),.clear_req(clear_req),.preset(preset),.in_valid(iv),.x(x),.out_valid(ov),.y(y));
    stereo_spatializer spatial(.clk(clk),.rst_n(rst_n),.sample_valid(ov),.clear(clear_sample),.in_data(y),
        .pan_position(pan),.itd_enable(itd),.busy(),.out_valid(sv),.out_left(left),.out_right(right),
        .position_q4(),.gain_left_q12(),.gain_right_q12(),.delay_left_q6(),.delay_right_q6());
    i2s_audio_output #(.PCM_HEADROOM_BITS(HEADROOM)) converter(.clk(clk),.audio_clk(clk),.rst_n(rst_n),
        .active(1'b0),.in_valid(1'b0),.in_data(64'sd0),.sample_tick(),.amp_bclk(),.amp_ws(),.amp_din(),
        .dac_bck(),.dac_ws(),.dac_din(),.deadline_miss(),.overflow(),.underflow());
    initial begin
        fd=$fopen($sformatf("post_trace_%0d.txt",HEADROOM),"w");
        repeat(5)@(negedge clk);rst_n=1;
        for(int p=0;p<3;p++)begin
            preset=p==0?router_pkg::REVERB_NONE:p==1?router_pkg::REVERB_HALL:router_pkg::REVERB_BATHROOM;
            clear_req=1;repeat(3)@(negedge clk);clear_req=0;repeat(4)@(negedge clk);
            for(int n=0;n<4200;n++)begin
                rng=rng^(rng<<13);rng=rng^(rng>>7);rng=rng^(rng<<17);
                case(n%11)
                    0:x=64'sd4398046511104;
                    1:x=-64'sd4398046511104;
                    2:x=64'sh7fffffffffffffff;
                    3:x=64'sh8000000000000000;
                    default:x=$signed(rng)>>>35;
                endcase
                pan=(n/60)%40;itd=(n%900)<650;clear_sample=n==0;
                $fwrite(fd,"%0d %0d %0d %0d %0d %0d",p,n,x,pan,itd,clear_sample);
                iv=1;@(negedge clk);iv=0;
                wait(sv);@(negedge clk);
                $fwrite(fd," %0d %0d %0d %0d %0d %0d\n",y,left,right,
                    converter.pcm16(y),converter.spatial_pcm16(left),converter.spatial_pcm16(right));
                repeat(10)@(negedge clk);
            end
        end
        $fclose(fd);$display("PASS tb_eng1_post_trace headroom=%0d samples=12600",HEADROOM);$finish;
    end
endmodule
