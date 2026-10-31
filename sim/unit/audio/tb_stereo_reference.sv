`timescale 1ns/1ps
// Behavioral oracle for real-synthesis integration. Computes the LUT from the
// mathematical law and uses wide multiplication; shares no production functions.
module stereo_reference #(
    parameter int HEADROOM=3,MAX_ITD=4
)(
    input logic clk,rst_n,sample_valid,clear,
    input logic signed [63:0] x,
    input logic [5:0] pan,
    input logic itd,
    output logic expected_valid,
    output logic [31:0] expected_pair
);
    integer pos=256,dl=0,dr=0;
    logic signed [127:0] hist_l[0:MAX_ITD],hist_r[0:MAX_ITD];
    function automatic integer knot(input integer i);
        real a,b;
        a=32-i;b=i;
        return $rtoi(256.0*a/$sqrt(a*a+b*b)+0.5);
    endfunction
    function automatic integer coefficient(input integer p);
        integer i,f;
        i=p/16;f=p%16;
        return i==32?knot(32)*16:knot(i)*(16-f)+knot(i+1)*f;
    endfunction
    function automatic integer approach(input integer v,target,step);
        return target>v ? v+((target-v>step)?step:target-v) : v-((v-target>step)?step:v-target);
    endfunction
    function automatic logic [15:0] pcm(input logic signed [127:0] y);
        logic signed [127:0] v;
        v=(y+(128'sd1<<(26+HEADROOM)))>>>(27+HEADROOM);
        return v>32767?16'h7fff:v< -32768?16'h8000:16'(v);
    endfunction
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            pos=256;dl=0;dr=0;expected_valid<=0;expected_pair<=0;
            for(integer i=0;i<=MAX_ITD;i++)begin hist_l[i]=0;hist_r[i]=0;end
        end else begin
            expected_valid<=sample_valid;
            if(sample_valid)begin
                integer target,step,tdl,tdr,il,ir,fl,fr;
                logic signed [127:0] a,b,yl,yr;
                target=(pan>32)?512:16*int'(pan);
                pos=approach(pos,target,1);
                tdl=(itd && pos>256)?((pos-256)*MAX_ITD)/4:0;
                tdr=(itd && pos<256)?((256-pos)*MAX_ITD)/4:0;
                step=MAX_ITD==8?2:1;dl=approach(dl,tdl,step);dr=approach(dr,tdr,step);
                for(integer i=MAX_ITD;i>0;i--)begin
                    hist_l[i]=clear?128'sd0:hist_l[i-1];hist_r[i]=clear?128'sd0:hist_r[i-1];
                end
                hist_l[0]=clear?128'sd0:128'($signed(x))*128'(coefficient(pos));
                hist_r[0]=clear?128'sd0:128'($signed(x))*128'(coefficient(512-pos));
                il=dl/64;fl=dl%64;ir=dr/64;fr=dr%64;
                a=hist_l[il];b=il<MAX_ITD?hist_l[il+1]:128'sd0;
                yl=a*(64-fl)+b*fl;
                a=hist_r[ir];b=ir<MAX_ITD?hist_r[ir+1]:128'sd0;
                yr=a*(64-fr)+b*fr;
                expected_pair<={pcm(yl),pcm(yr)};
            end
        end
    end
endmodule
