`timescale 1ns/1ps
module tb_frame_arbiter;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic admit=0;
    logic [1:0] eligible=2'b11, sv, sr, sf, sl, pin;
    logic [15:0] sd, st;
    logic [31:0] ss;
    logic [11:0] sn;
    logic mv, mr=0, mf, ml, src, busy;
    logic [7:0] md, mt;
    logic [15:0] ms;
    logic [5:0] mn;
    integer frame_idx[0:1], offset[0:1], received=0, frames=0;
    logic [15:0] lfsr=16'hace1;
    logic was_stalled=0;
    logic [34:0] held;
    integer inside_source=-1;
    frame_arbiter dut (
        .clk(clk),.rst_n(rst_n),.admit_new_frame(admit),.eligible(eligible),
        .s_valid(sv),.s_ready(sr),.s_data(sd),.s_type(st),.s_seq(ss),
        .s_payload_len(sn),.s_first(sf),.s_last(sl),
        .m_valid(mv),.m_ready(mr),.m_data(md),.m_type(mt),.m_seq(ms),
        .m_payload_len(mn),.m_first(mf),.m_last(ml),.m_source_id(src),.pin(pin),.busy(busy)
    );
    always_comb begin
        sv='0;sd='0;st='0;ss='0;sn='0;sf='0;sl='0;
        for(int i=0;i<2;i++) begin
            sv[i]=frame_idx[i]<4;
            sd[i*8+:8]=8'(i*64+frame_idx[i]*8+offset[i]);
            st[i*8+:8]=8'(i+1);
            ss[i*16+:16]=16'(frame_idx[i]);
            sn[i*6+:6]=6'(i+2);
            sf[i]=offset[i]==0;
            sl[i]=offset[i]==i+1;
        end
    end
    always @(negedge clk) if(rst_n) begin
        lfsr={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        mr=lfsr[0]|lfsr[1];
    end
    always @(posedge clk) if(rst_n) begin
        if(was_stalled && (!mv || {src,mf,ml,md,mt,ms}!==held))
            $fatal(1,"arbiter changed stalled byte");
        was_stalled<=mv&&!mr;
        held<={src,mf,ml,md,mt,ms};
        if(mv&&mr) begin
            if(inside_source<0) begin
                if(!mf) $fatal(1,"missing first");
                inside_source=src;
            end
            if(inside_source!=src || mn!=src+2 || mt!=src+1 || ms!=frame_idx[src])
                $fatal(1,"mixed frame metadata");
            if(md!=8'(src*64+frame_idx[src]*8+offset[src])) $fatal(1,"wrong byte");
            received++;
            if(ml) begin frames++;inside_source=-1; end
        end
        for(int i=0;i<2;i++) if(sv[i]&&sr[i]) begin
            if(sl[i]) begin frame_idx[i]<=frame_idx[i]+1;offset[i]<=0;end
            else offset[i]<=offset[i]+1;
        end
    end
    initial begin
        frame_idx[0]=0;frame_idx[1]=0;offset[0]=0;offset[1]=0;
        repeat(3) @(negedge clk);rst_n=1;
        repeat(5) @(negedge clk);
        if(busy || pin!=0 || received!=0) $fatal(1,"grant without admission");
        admit=1;
        wait(busy);@(negedge clk);eligible=0; // must not revoke an existing grant
        repeat(3) @(negedge clk);eligible=3;
        wait(frames==8);repeat(3) @(negedge clk);
        if(received!=20) $fatal(1,"bad byte count");
        $display("PASS tb_frame_arbiter frames=%0d bytes=%0d",frames,received);$finish;
    end
    initial begin #100000;$fatal(1,"arbiter timeout");end
endmodule
