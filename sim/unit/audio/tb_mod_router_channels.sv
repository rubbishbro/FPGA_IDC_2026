`timescale 1ns/1ps
module tb_mod_router_channels;
    import router_pkg::*;
    import modal_step_pkg::*;
    logic clk=0,rst_n=0,start=0,busy,done;
    always #5 clk=~clk;
    instrument_e inst=INST_PIANO;
    logic [1:0] job_slot=0,cleanup=0;
    logic [7:0] pressure=202;
    logic p_re;
    logic [2:0] p_mode,co_mode;
    logic signed [31:0] a11,a12,a22,wo,s11,s12,s22,swo;
    logic [4:0] co_we;
    coeff_t co;
    logic table_we=0,clear=0,bad_tag=0;
    logic [9:0] table_addr=0;
    logic [31:0] table_data=0;
    logic commit,sready,ready,rejected;
    logic [95:0] delta;
    integer reads=0,writes=0,jobs=0;
    mod_router #(.SLOTS(4),.N_MODES(8),.MOD1_MODES_PER_JOB(6)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.job_slot(job_slot),.fmap_i(pressure),
        .n_modes(16'd8),.inst(inst),.busy(busy),.done(done),
        .p_re(p_re),.p_mode(p_mode),.p_a11(a11),.p_a12(a12),.p_a22(a22),.p_wo(wo),
        .p_s11(s11),.p_s12(s12),.p_s22(s22),.p_swo(swo),
        .co_we(co_we),.co_mode(co_mode),.co_wdata(co),
        .pitch_clear(clear),.pressure_enable(1'b1),.pressure_gate(4'hf),.pressure_level({4{pressure}}),
        .table_we(table_we),.table_addr(table_addr),.table_data(table_data),
        .pitch_cleanup(cleanup),.pitch_slot_source(4'd0),
        .pitch_control_valid(1'b0),.pitch_control_cancel(1'b0),.pitch_control_source(1'b0),
        .pitch_control_data(32'd0),.pitch_control_ready(ready),.pitch_control_rejected(rejected),
        .pitch_bank(),.pitch_commit(commit),.pitch_delta(delta),.pitch_sources_ready(sready));
    function automatic integer adjust(input integer base,slope,shift);
        longint signed lam,prod;
        lam=((46976199+64)/128)*(int'(pressure)-102);prod=lam*64'(slope);
        return base+32'(prod>>>shift);
    endfunction
    always @(posedge clk)if(rst_n)begin
        if(p_re)begin
            reads++;
            if(inst==INST_GUITAR)begin
                a11<=10000+100*int'(p_mode);a12<=20000+100*int'(p_mode);
                a22<=30000+100*int'(p_mode);wo<=40000+100*int'(p_mode);
                s11<=1048576;s12<=1048576;s22<=-1048576;swo<=1048576;
            end else if(uses_mod1(inst))begin
                a11<=-26000000;a12<=-25000000+100*int'(p_mode);a22<=-24000000;wo<=0;
                s11<=0;s12<=p_mode[0] ? -4194304 : 4194304;s22<=0;swo<=bad_tag ? 0 : 32'h50315431;
            end else $fatal(1,"FAIL inactive kernel issued parameter read");
        end
        if(|co_we)begin
            if(co_mode!=writes)$fatal(1,"FAIL shared channel mode order");
            if(inst==INST_GUITAR)begin
                if(co_we!=5'b11111 ||
                   co.a11!==adjust(10000+100*int'(co_mode),1048576,31) ||
                   co.a12!==adjust(20000+100*int'(co_mode),1048576,29) ||
                   co.a21!==-32'($signed(co.a12)>>>7) ||
                   co.a22!==adjust(30000+100*int'(co_mode),-1048576,31) ||
                   co.wo!==adjust(40000+100*int'(co_mode),1048576,30))
                    $fatal(1,"FAIL ENG0 payload/mask");
            end else if(uses_mod1(inst))begin
                if(co_we!=5'b00010 || co.a12!==(-25000000+100*int'(co_mode)+(co_mode[0] ? -75000 : 75000)) ||
                   co.a11!=0 || co.a21!=0 || co.a22!=0 || co.wo!=0 || co.gq!=0 || co.gv!=0)
                    $fatal(1,"FAIL ENG1 payload/mask");
            end else $fatal(1,"FAIL inactive kernel wrote coefficients");
            writes++;
        end
    end
    task automatic job(input instrument_e kind,input integer slot,expected_reads,expected_writes);
        @(negedge clk);inst=kind;job_slot=2'(slot);reads=0;writes=0;start=1;
        @(negedge clk);start=0;wait(done);@(posedge clk);#1;
        if(reads!=expected_reads || writes!=expected_writes || busy)
            $fatal(1,"FAIL shared handshake inst=%d reads=%d writes=%d",kind,reads,writes);
        if(uses_mod1(kind) && !bad_tag && $signed(delta[slot*24 +:24])!=75000)
            $fatal(1,"FAIL pitch commit payload");
        jobs++;@(negedge clk);
    endtask
    initial begin
        a11=0;a12=0;a22=0;wo=0;s11=0;s12=0;s22=0;swo=0;
        repeat(4)@(negedge clk);rst_n=1;
        for(int i=0;i<512;i++)begin
            table_we=1;table_addr=10'(i);table_data=16777216+(i-220)*1000;@(negedge clk);
        end
        table_we=0;
        job(INST_GUITAR,1,8,4);
        job(INST_TRUMPET,2,6,6);
        job(INST_TRUMPET,0,6,6);
        job(INST_PIANO,3,0,0);
        job(INST_PIANO_ABC,3,0,0);
        job(INST_FLUTE,2,6,6);job(INST_CELLO,2,6,6);
        job(INST_VIOLIN,2,6,6);job(INST_OBOE,2,6,6);
        job(INST_BANJO,2,6,6);job(INST_MANDOLIN,2,6,6);
        job(INST_GUITAR_ABC,2,6,6);
        job(INST_GUITAR,0,8,4);
        bad_tag=1;job(INST_TRUMPET,1,1,0);bad_tag=0;
        // Abort completion must stay distinct from successful pitch_commit.
        @(negedge clk);reads=0;writes=0;start=1;
        @(negedge clk);start=0;wait(co_we[1]);@(negedge clk);cleanup=1;
        @(posedge clk);#1;if(!done || commit || busy || sready || co_we!=0)
            $fatal(1,"FAIL cleanup semantics changed");
        @(negedge clk);cleanup=0;
        job(INST_TRUMPET,1,6,6);
        @(negedge clk);clear=1;@(posedge clk);#1;
        if(delta!=0 || busy || !sready || |co_we)$fatal(1,"FAIL clear semantics changed");
        @(negedge clk);clear=0;
        $display("PASS tb_mod_router_channels jobs=%0d ENG0/ENG1 masks arithmetic switching no-op tag cleanup clear",jobs);$finish;
    end
    initial begin #200000;$fatal(1,"FAIL shared-channel watchdog");end
endmodule
