`timescale 1ns/1ps
module tb_eng1_pitch;
    localparam int S=4,N=4,M=3;
    logic clk=0,rst_n=0,clear=0,tick=0,allow_commit=0,enable=1;
    always #5 clk=~clk;
    logic [S-1:0] gate=0,sources=0;
    logic [S*8-1:0] level=0;
    logic [1:0] cleanup=0;
    logic cv=0,cancel=0,ready,rejected,bank,busy,commit,pr,cw,sready;
    logic [31:0] control=0;
    logic [S*24-1:0] delta;
    logic [3:0] pa,ca;
    logic signed [31:0] low,base,high,slope,tag,cdata;
    logic table_we=0,bad_tag=0;
    logic [9:0] table_addr=0;
    logic [31:0] table_data=0,table_words[0:1023],gold_delta[0:255],gold_cents[0:255];
    logic [2:0] nm=M;
    integer memory[2][16],writes=0,jobs=0,checks=0;
    modulation1 #(.SLOTS(S),.N_MODES(N),.INTERVAL(1)) dut(
        .clk(clk),.rst_n(rst_n),.clear(clear),.sample_tick(tick),.commit_ok(allow_commit),
        .table_we(table_we),.table_addr(table_addr),.table_data(table_data),
        .pressure_enable(enable),.pressure_gate(gate),.pressure_level(level),
        .cleanup(cleanup),.n_modes(nm),.slot_source(sources),
        .control_valid(cv),.control_cancel(cancel),.control_source(1'b0),.control_data(control),
        .control_ready(ready),.control_rejected(rejected),.active_bank(bank),.busy(busy),
        .commit_pulse(commit),.sources_ready(sready),.active_delta(delta),
        .p_re(pr),.p_addr(pa),.p_lower(low),.p_base(base),.p_upper(high),.p_slope(slope),.p_tag(tag),
        .co_we(cw),.co_addr(ca),.co_a1(cdata));
    function automatic integer nominal(input integer addr);nominal=-25000000+addr*1000;endfunction
    function automatic integer coefficient(input integer addr,d);
        longint signed x;
        begin
            x=nominal(addr)+((64'((addr%2==0)?4194304+addr*100:-4194304-addr*100)*64'(d)+2097152)>>>22);
            if(x> -24500000)x=-24500000;
            if(x< -25500000)x=-25500000;
            coefficient=32'(x);
        end
    endfunction
    always @(posedge clk)if(rst_n)begin
        if(pr)begin
            low<=-25500000;base<=nominal(pa);high<=-24500000;
            slope<=pa[0] ? -4194304-int'(pa)*100 : 4194304+int'(pa)*100;
            tag<=bad_tag?0:32'h50315431;
        end
        if(cw)begin
            if(ca!={2'(writes/M),2'(writes%M)})$fatal(1,"FAIL write order %d %d",ca,writes);
            memory[!bank][ca]<=cdata;writes++;
        end
    end
    task automatic snapshot;
        @(negedge clk);tick=1;@(negedge clk);tick=0;
    endtask
    task automatic finish_job(input integer p0,p1,p2,p3);
        integer expected[4],oldbank;
        begin
            expected[0]=p0;expected[1]=p1;expected[2]=p2;expected[3]=p3;
            wait(dut.st==dut.COMMIT);@(negedge clk);oldbank=bank;
            if(writes!=S*int'(nm))$fatal(1,"FAIL incomplete batch %d",writes);
            repeat(3)begin @(negedge clk);if(commit || bank!=oldbank)$fatal(1,"FAIL early commit");end
            allow_commit=1;@(negedge clk);allow_commit=0;
            if(!commit || bank==oldbank)$fatal(1,"FAIL atomic commit");
            for(int s=0;s<S;s++)begin
                if($signed(delta[s*24 +:24])!=$signed(gold_delta[expected[s]]))$fatal(1,"FAIL ratio slot %d pressure %d",s,expected[s]);
                if(dut.cents[s]!=gold_cents[expected[s]])$fatal(1,"FAIL cents slot %d",s);
                for(int m=0;m<int'(nm);m++)begin
                    if(memory[bank][s*N+m]!=coefficient(s*N+m,gold_delta[expected[s]]))$fatal(1,"FAIL a1 slot %d mode %d",s,m);
                    checks++;
                end
            end
            jobs++;wait(!busy);@(negedge clk);writes=0;
        end
    endtask
    integer oldbank,olddelta;
    initial begin
        $readmemh("pitch_tables.mem",table_words);$readmemh("aftertouch_delta.mem",gold_delta);$readmemh("aftertouch_cents.mem",gold_cents);
        for(int k=0;k<1024;k++)begin
            @(negedge clk);table_we=1;table_addr=10'(k);table_data=table_words[k];
        end
        @(negedge clk);table_we=0;rst_n=1;
        // All byte values, four independent slots, monotonic up and down.
        gate='1;
        for(int p=0;p<256;p++)begin
            level={8'(255-p),8'd102,8'd202,8'(p)};snapshot();finish_job(p,202,102,255-p);
        end
        if(gold_cents[202]!=15360 || gold_cents[255]!=23501)$fatal(1,"FAIL calibration");
        // Freeze the complete pressure batch even if inputs change mid-job.
        level={4{8'd202}};snapshot();wait(writes==1);
        level={4{8'd255}};finish_job(202,202,202,202);
        // Released tails hold; a new gated note uses the current pressure.
        gate=0;level=0;snapshot();finish_job(202,202,202,202);
        gate=1;level=103;snapshot();finish_job(103,202,202,202);
        // Wheel and bend are acknowledged as rejected and cannot change pitch.
        cv=1;control=32'h40000000;#1;
        if(!ready || !rejected)$fatal(1,"FAIL wheel rejection");
        cancel=1;#1;if(ready)$fatal(1,"FAIL cancelled control ack");
        @(negedge clk);cv=0;cancel=0;
        snapshot();finish_job(103,202,202,202);
        // Corrupt metadata after partial writes must never publish a partial bank.
        oldbank=bank;olddelta=delta[23:0];level={4{8'd255}};gate='1;snapshot();
        wait(writes==2);@(negedge clk);bad_tag=1;wait(!busy);@(negedge clk);
        if(bank!=oldbank || delta[23:0]!=olddelta)$fatal(1,"FAIL bad tag committed");
        bad_tag=0;writes=0;snapshot();finish_job(255,255,255,255);
        // Cleanup at the final edge also vetoes publication.
        snapshot();wait(dut.st==dut.COMMIT);@(negedge clk);oldbank=bank;cleanup=1;allow_commit=1;
        @(negedge clk);if(bank!=oldbank || commit)$fatal(1,"FAIL cleanup committed");
        cleanup=0;allow_commit=0;writes=0;finish_job(255,255,255,255);
        // MIDI mode restores nominal coefficients instead of using velocity.
        enable=0;#1;
        if(sready)$fatal(1,"FAIL mode switch admitted MIDI with old PAD ratios");
        snapshot();finish_job(0,0,0,0);
        // Ownership changes invalidate held tails and source barrier retires.
        sources='1;snapshot();finish_job(0,0,0,0);
        if(!sready)$fatal(1,"FAIL source barrier");
        // Zero modes must never read or write coefficient mode zero.
        nm=0;snapshot();finish_job(0,0,0,0);
        clear=1;#1;if(!sready)$fatal(1,"FAIL disabled instrument blocked MIDI source");
        @(negedge clk);clear=0;
        if(bank || delta!=0 || busy)$fatal(1,"FAIL clear");
        $display("PASS tb_eng1_pitch aftertouch jobs=%0d coefficient_checks=%0d exhaustive_pressure atomic_commit tail_hold metadata cleanup",jobs,checks);$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL aftertouch timeout state=%d writes=%d",dut.st,writes);end
endmodule
