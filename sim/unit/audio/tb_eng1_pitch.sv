`timescale 1ns/1ps
module tb_eng1_pitch;
    localparam int S=16,N=64,M=48;
    logic clk=0,rst_n=0,clear=0,tick=0,allow_commit=0,cv=0,cancel=0,src=0;
    always #5 clk=~clk;
    logic [1:0] cleanup=0;
    logic [15:0] sources=16'haaaa;
    logic [31:0] data=0;
    logic ready,rejected,bank,busy,commit,pr,cw;
    logic [383:0] delta;
    logic [9:0] pa,ca;
    logic signed [31:0] low,base,high,slope,tag,cdata;
    integer params[1024][5],expected[1024],memory[2][1024];
    integer writes=0,checks=0,jobs=0;
    integer cycles=0,job_cycle=0,max_prepare=0;
    bit bad_tag=0,writing_bank,saw_ack=0,saw_reject=0;
    logic table_we=0;
    logic [9:0] table_addr=0;
    logic [31:0] table_data=0,table_words[0:1023];
    task automatic load_tables;
        $readmemh("pitch_tables.mem",table_words);
        for(int k=0;k<1024;k++)begin
            @(negedge clk);table_we=1;table_addr=10'(k);table_data=table_words[k];
        end
        @(negedge clk);table_we=0;
    endtask
    modulation1 #(.SLOTS(S),.N_MODES(N),.INTERVAL(1)) dut(
        .table_we(table_we),.table_addr(table_addr),.table_data(table_data),
        .clk(clk),.rst_n(rst_n),.clear(clear),.sample_tick(tick),.commit_ok(allow_commit),
        .cleanup(cleanup),.n_modes(7'd48),.slot_source(sources),.control_valid(cv),.control_cancel(cancel),
        .control_source(src),.control_data(data),.control_ready(ready),.control_rejected(rejected),
        .active_bank(bank),.busy(busy),.commit_pulse(commit),.active_delta(delta),
        .p_re(pr),.p_addr(pa),.p_lower(low),.p_base(base),.p_upper(high),.p_slope(slope),.p_tag(tag),
        .co_we(cw),.co_addr(ca),.co_a1(cdata));
    always @(posedge clk)if(rst_n)begin
        cycles++;
        if(ready)begin saw_ack=1;saw_reject=rejected;end
        if(pr)begin
            low<=params[pa][0];base<=params[pa][1];high<=params[pa][2];slope<=params[pa][3];
            tag<=bad_tag?0:params[pa][4];
        end
        if(cw)begin
            if(ca!={4'(writes/M),6'(writes%M)})$fatal(1,"FAIL pitch write order %d %d",ca,writes);
            if(bank!=writing_bank)$fatal(1,"FAIL active bank changed during preparation");
            memory[!bank][ca]<=cdata;writes++;
        end
    end
    task automatic begin_job;
        wait(!busy);@(negedge clk);allow_commit=0;writes=0;writing_bank=bank;saw_ack=0;saw_reject=0;job_cycle=cycles;
    endtask
    integer fd,rc,kind,ss,value,ed0,ed1,ec0,ec1,oldbank;
    task automatic finish_job;
        wait(dut.st==dut.COMMIT);
        if(kind!=3 && kind!=6)begin
            if(cycles-job_cycle>6*S*M+24)$fatal(1,"FAIL pitch preparation budget");
            if(cycles-job_cycle>max_prepare)max_prepare=cycles-job_cycle;
        end
        if(writes!=S*M)$fatal(1,"FAIL incomplete coefficient batch %d",writes);
        repeat(8)begin @(negedge clk);if(ready || commit || bank!=writing_bank)$fatal(1,"FAIL early pitch commit");end
        allow_commit=1;@(negedge clk);
        if(!commit || bank==writing_bank)$fatal(1,"FAIL missing atomic bank commit");
        if(kind==1 || kind==2)begin
            if(!saw_ack || saw_reject)$fatal(1,"FAIL pitch control retirement");cv=0;
        end else if(saw_ack)$fatal(1,"FAIL background update acknowledged a control");
        for(int s=0;s<S;s++)begin
            if($signed(delta[s*24 +:24])!==(sources[s]?ed1:ed0))
                $fatal(1,"FAIL pitch ratio job=%d kind=%d slot=%d got=%d expected=%d cents=%d,%d phase=%h",jobs,kind,s,$signed(delta[s*24 +:24]),sources[s]?ed1:ed0,dut.cents[0],dut.cents[1],dut.phase_job);
            for(int m=0;m<M;m++)begin
                checks++;
                if(memory[bank][s*64+m]!==expected[s*64+m])
                    $fatal(1,"FAIL a1 slot=%d mode=%d got=%d expected=%d",s,m,memory[bank][s*64+m],expected[s*64+m]);
            end
        end
        // Cents are checked independently too, catching a wrong trajectory
        // even when low-frequency coefficient quantisation masks it.
        if(dut.cents[0]!=ec0 || dut.cents[1]!=ec1)$fatal(1,"FAIL cents trajectory");
        jobs++;wait(!busy);@(negedge clk);
    endtask
    initial begin
        fd=$fopen("pitch_params.txt","r");if(!fd)$fatal(1,"FAIL pitch params absent");
        for(int i=0;i<1024;i++)begin
            rc=$fscanf(fd,"%d %d %d %d %d",params[i][0],params[i][1],params[i][2],params[i][3],params[i][4]);
            memory[0][i]=params[i][1];memory[1][i]=params[i][1];
        end
        $fclose(fd);fd=$fopen("pitch_jobs.txt","r");
        load_tables();repeat(4)@(negedge clk);rst_n=1;
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d",kind,ss,value,ec0,ec1,ed0,ed1);
            if(rc!=7)break;
            for(int i=0;i<1024;i++)rc=$fscanf(fd,"%d",expected[i]);
            begin_job();src=1'(ss);
            case(kind)
                0:begin tick=1;@(negedge clk);tick=0;end
                1:begin data={4'd4,4'd0,7'(value),7'(value>>7),10'd0};cv=1;end
                2:begin data={4'd2,4'd0,7'd1,7'(value),10'd0};cv=1;end
                3:begin
                    // Cancel after writes started. No buffer switch or ack may leak.
                    oldbank=bank;data={4'd4,4'd0,7'd0,7'd0,10'd0};cv=1;
                    wait(writes==100);@(negedge clk);cancel=1;
                    repeat(3)@(negedge clk);
                    if(bank!=oldbank || saw_ack)$fatal(1,"FAIL cancelled control committed");
                    cv=0;cancel=0;writes=0;
                end
                6:begin
                    // Veto at the very last edge, after the shadow is complete.
                    oldbank=bank;data={4'd4,4'd0,7'd0,7'd0,10'd0};cv=1;
                    wait(dut.st==dut.COMMIT);@(negedge clk);cancel=1;allow_commit=1;
                    repeat(3)@(negedge clk);
                    if(bank!=oldbank || saw_ack)$fatal(1,"FAIL final-edge cancellation committed");
                    cv=0;cancel=0;allow_commit=0;writes=0;
                end
                4:begin cleanup=2'b01;@(negedge clk);cleanup=0;end
                5:begin sources=~sources;tick=1;@(negedge clk);tick=0;end
            endcase
            finish_job();
        end
        if(jobs<300)$fatal(1,"FAIL insufficient pitch trajectories");
        // Missing first-order metadata must reject and preserve active audio.
        begin_job();oldbank=bank;bad_tag=1;cv=1;data={4'd4,4'd0,7'd0,7'd127,10'd0};
        wait(saw_ack);@(negedge clk);
        if(!saw_reject || bank!=oldbank || writes!=0)$fatal(1,"FAIL metadata rejection");
        cv=0;bad_tag=0;wait(!busy);
        // A table reload clears controls, active ratio and buffer epoch.
        @(negedge clk);clear=1;@(negedge clk);clear=0;
        if(bank || delta!=0 || busy)$fatal(1,"FAIL reload retained pitch state");
        $display("PASS tb_eng1_pitch jobs=%0d coefficient_checks=%0d max_prepare_cycles=%0d shared_multiply atomic_cancel cleanup metadata",jobs,checks,max_prepare);$finish;
    end
    initial begin #30000000;$fatal(1,"FAIL pitch unit timeout");end
endmodule
