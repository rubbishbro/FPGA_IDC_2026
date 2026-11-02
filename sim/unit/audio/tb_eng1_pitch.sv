`timescale 1ns/1ps
module tb_eng1_pitch #(parameter int N=8,M=6);
    localparam int S=4;
    logic clk=0,rst_n=0,clear=0,start=0,done,busy,commit,sready;
    always #5 clk=~clk;
    logic [1:0] slot=0,cleanup=0;
    logic enable=0;
    logic [S-1:0] gate='1,sources=0;
    logic [S*8-1:0] level=0;
    logic cv=0,cancel=0,ready,rejected,bank;
    logic [95:0] delta;
    logic [$clog2(N):0] nm=N;
    logic table_we=0;
    logic [9:0] table_addr=0;
    logic [31:0] table_data=0,table_words[1024];
    logic pr,cw,bad_tag=0;
    logic [1+$clog2(N):0] pa,ca;
    logic signed[31:0] low=0,base=0,high=0,slope=0,tag=0,cdata;
    logic signed[31:0] memory[S*N],gold_delta[256],gold_cents[256];
    integer writes=0,checks=0,jobs=0;
    modulation1 #(.SLOTS(S),.N_MODES(N),.MODES_PER_JOB(M)) dut(
        .clk(clk),.rst_n(rst_n),.clear(clear),.start(start),.job_slot(slot),.done(done),
        .table_we(table_we),.table_addr(table_addr),.table_data(table_data),
        .pressure_enable(enable),.pressure_gate(gate),.pressure_level(level),
        .cleanup(cleanup),.n_modes(nm),.slot_source(sources),
        .control_valid(cv),.control_cancel(cancel),.control_source(1'b0),.control_data(32'd0),
        .control_ready(ready),.control_rejected(rejected),.active_bank(bank),.busy(busy),
        .commit_pulse(commit),.sources_ready(sready),.active_delta(delta),
        .p_re(pr),.p_addr(pa),.p_lower(low),.p_base(base),.p_upper(high),.p_slope(slope),.p_tag(tag),
        .co_we(cw),.co_addr(ca),.co_a1(cdata));
    function automatic integer nominal(input integer addr);return -25000000+addr*1000;endfunction
    function automatic integer coefficient(input integer addr,d);
        longint signed v;
        v=nominal(addr)+((64'((addr%2==0)?4194304+addr*100:-4194304-addr*100)*64'(d)+2097152)>>>22);
        return v> -24500000 ? -24500000 : (v< -25500000 ? -25500000 : 32'(v));
    endfunction
    always @(posedge clk)if(rst_n)begin
        if(pr)begin
            low<=-25500000;base<=nominal(pa);high<=-24500000;
            slope<=pa[0] ? -4194304-int'(pa)*100 : 4194304+int'(pa)*100;
            tag<=bad_tag?0:32'h50315431;
        end
        if(cw)begin
            if(ca!={slot,($clog2(N))'(writes)})$fatal(1,"write order/slot mismatch");
            memory[ca]<=cdata;writes++;
        end
    end
    task automatic job(input integer s,p,expected);
        @(negedge clk);while(busy)@(negedge clk);
        writes=0;slot=2'(s);level[s*8 +:8]=8'(p);start=1;
        @(negedge clk);start=0;wait(done);#1;
        if(writes!=(int'(nm)<M?int'(nm):M))$fatal(1,"mode cap count %d",writes);
        if($signed(delta[s*24 +:24])!=$signed(gold_delta[expected]))$fatal(1,"ratio mismatch");
        for(int m=0;m<(int'(nm)<M?int'(nm):M);m++)begin
            if(memory[s*N+m]!==coefficient(s*N+m,gold_delta[expected]))$fatal(1,"a1 mismatch");
            checks++;
        end
        jobs++;@(negedge clk);
    endtask
    initial begin
        $readmemh("pitch_tables.mem",table_words);$readmemh("aftertouch_delta.mem",gold_delta);$readmemh("aftertouch_cents.mem",gold_cents);
        for(int k=0;k<1024;k++)begin @(negedge clk);table_we=1;table_addr=10'(k);table_data=table_words[k];end
        @(negedge clk);table_we=0;rst_n=1;#1;
        if(!sready || busy || delta!=0)$fatal(1,"cold nominal MIDI admission");
        enable=1;
        for(int a=0;a<S*N;a++)memory[a]=32'h5a5a5a5a;
        for(int p=0;p<256;p++)for(int s=0;s<S;s++)job(s,p,p);
        for(int s=0;s<S;s++)for(int m=M;m<N;m++)
            if(memory[s*N+m]!==32'h5a5a5a5a)$fatal(1,"write past cap");
        fork
            job(0,202,202);
            begin wait(cw);@(negedge clk);level[7:0]=255;end
        join
        gate=0;job(0,0,202);for(int s=1;s<S;s++)job(s,0,255);
        gate='1;enable=0;for(int s=0;s<S;s++)job(s,255,0);
        if(!sready)$fatal(1,"disabled ownership barrier");
        enable=1;for(int s=0;s<S;s++)job(s,202,202);
        sources=1;job(0,202,0);job(0,202,202);
        nm=0;job(1,202,202);nm=N;
        cv=1;#1;if(!ready || !rejected)$fatal(1,"wheel reject");cancel=1;#1;if(ready)$fatal(1,"cancelled wheel ack");cv=0;cancel=0;
        @(negedge clk);start=1;@(negedge clk);start=0;wait(cw);
        @(negedge clk);cleanup=1;@(negedge clk);cleanup=0;
        if(busy || sready)$fatal(1,"cleanup did not abort/invalidate");
        job(0,202,202);
        bad_tag=1;@(negedge clk);writes=0;start=1;@(negedge clk);start=0;wait(done);#1;
        if(writes!=0)$fatal(1,"bad tag writes");bad_tag=0;
        @(negedge clk);clear=1;@(negedge clk);clear=0;#1;
        if(delta!=0 || busy || bank)$fatal(1,"clear state");
        $display("PASS tb_eng1_pitch jobs=%0d checks=%0d per_slot cap=%0d pressure256 release ownership disable zero_modes tag clear",jobs,checks,M);$finish;
    end
    initial begin #2000000;$fatal(1,"pitch watchdog");end
endmodule
