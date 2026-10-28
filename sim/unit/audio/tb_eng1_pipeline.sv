`timescale 1ns/1ps
// Independent Python integer oracle; different coefficients/state at every address.
module tb_eng1_pipeline;
    localparam int N=64;
    logic clk=0,rst_n=0,start=0,zero=0;
    always #5 clk=~clk;
    logic [6:0] nm=0;
    logic cr,sr,sw,xr,yv;
    logic [5:0] ca,sa,wa;
    logic signed [31:0] q, v, qw, vw, x, job_x;
    logic signed [63:0] y;
    modal_step_pkg::coeff_t cd;
    logic signed [31:0] g[64],a1[64],a2[64],qm[64],vm[64],eq[64],ev[64];
    integer reads=0,writes=0,cycles=0,lastread=-1,lastwrite=-1;
    eng1 dut(.clk(clk),.rst_n(rst_n),.start(start),.st_zero(zero),.n_modes(nm),
        .co_re(cr),.co_addr(ca),.co_data(cd),.st_re(sr),.st_addr(sa),.st_q(q),.st_qdot(v),
        .st_we(sw),.st_waddr(wa),.st_q_wdata(qw),.st_qdot_wdata(vw),.x_re(xr),.x_data(x),.y_valid(yv),.y_data(y));
    always @(posedge clk) if(rst_n) begin
        cycles++;
        if(xr) x<=job_x;
        if(cr) begin
            if(ca!=reads || !sr || sa!=ca) $fatal(1,"FAIL read address %d/%d",ca,reads);
            if(reads>0 && cycles-lastread!=1) $fatal(1,"FAIL read initiation interval");
            lastread=cycles;reads++;
            cd<='0;cd.a11<=g[ca];cd.a12<=a1[ca];cd.a21<=a2[ca];
            q<=qm[sa];v<=vm[sa];
            // These job inputs must already have been latched; change while busy.
            nm<=0;zero<=!zero;job_x<=32'h55aa33cc;
        end
        if(sw) begin
            if(wa!=writes || qw!==eq[wa] || vw!==ev[wa])
                $fatal(1,"FAIL state mode=%d got=%d,%d expected=%d,%d",wa,qw,vw,eq[wa],ev[wa]);
            if(writes>0 && cycles-lastwrite!=1) $fatal(1,"FAIL write initiation interval");
            lastwrite=cycles;writes++;qm[wa]<=qw;vm[wa]<=vw;
        end
    end
    integer fd,rc,n,z,xi,count=0,begin_cycle,active_n;
    longint expected;
    initial begin
        fd=$fopen("eng1_cases.txt","r");if(!fd)$fatal(1,"FAIL no vectors");
        repeat(4)@(negedge clk);rst_n=1;
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %d",n,z,xi,expected);
            if(rc!=4)break;
            for(integer i=0;i<N;i++) begin
                rc=$fscanf(fd,"%d %d %d %d %d %d %d",g[i],a1[i],a2[i],qm[i],vm[i],eq[i],ev[i]);
                if(rc!=7)$fatal(1,"FAIL vector row");
            end
            @(negedge clk);nm=7'(n);zero=1'(z);job_x=xi;start=1;
            reads=0;writes=0;begin_cycle=cycles;active_n=n>N?N:n;
            @(negedge clk);start=0;
            wait(yv);@(negedge clk);
            if(y!==expected || reads!=active_n || writes!=active_n)
                $fatal(1,"FAIL job %d n=%d sum=%d expected=%d reads=%d writes=%d",count,n,y,expected,reads,writes);
            if(cycles-begin_cycle>active_n+8)$fatal(1,"FAIL throughput cycles=%d n=%d",cycles-begin_cycle,active_n);
            repeat(2)@(negedge clk);count++;
        end
        if(count<200)$fatal(1,"FAIL too few jobs");
        // Reset in the middle of a full pipeline must cancel every pending write.
        nm=64;zero=1;start=1;reads=0;writes=0;
        @(negedge clk);start=0;repeat(5)@(negedge clk);rst_n=0;
        repeat(3)@(negedge clk);rst_n=1;
        repeat(10)begin @(negedge clk);if(sw || cr || yv)$fatal(1,"FAIL reset leaked pipeline");end
        $display("PASS tb_eng1_pipeline jobs=%0d II=1 max_latency=N+8",count);$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL pipeline timeout");end
endmodule
