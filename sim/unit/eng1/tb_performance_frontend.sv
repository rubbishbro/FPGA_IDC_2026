`timescale 1ns/1ps
module tb_performance_frontend;
    import router_pkg::*;
    logic clk=0,rst_n=0,tick=0,gate=0,trig=0,clear=0;
    always #5 clk=~clk;
    instrument_e inst=INST_NONE;
    logic[7:0] level=0;
    logic[15:0] period=2;
    logic[31:0] a=1,r=1;
    logic signed[0:0][31:0] x,e;
    logic[0:0] dead;
    exc_router #(.SLOTS(1)) exc(.clk(clk),.rst_n(rst_n),.smp_tick(tick),
        .slot_period(period),.slot_pitch_delta(24'd0),.strike_level(level),
        .retrigger(trig),.slot_clear(clear),.note_on(gate),.inst(inst),.xmap(x),.xmap_valid());
    env_router #(.SLOTS(1)) env(.clk(clk),.rst_n(rst_n),.smp_tick(tick),
        .slot_a_step(a),.slot_r_step(r),.envelope_level(8'hff),.retrigger(trig),
        .slot_clear(clear),.midi_mode(1'b0),.note_on(gate),.note_gate(gate),.inst(inst),
        .emap(e),.emap_valid(),.dead(dead));
    int f,rc,ident,g,l,t,c,p,aa,rr,xx,ee,dd,checks=0,last=-1;
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        f=$fopen("frontend_expected.txt","r");if(!f)$fatal(1,"FAIL missing vectors");
        while(!$feof(f))begin
            rc=$fscanf(f,"%d %d %d %d %d %d %d %d %d %d %d\n",ident,g,l,t,c,p,aa,rr,xx,ee,dd);
            if(rc!=11)$fatal(1,"FAIL malformed vectors");
            if(ident!=last)begin
                inst=instrument_e'(ident);tick=0;gate=0;trig=0;clear=0;
                repeat(8)@(negedge clk);
                clear=1;tick=1;@(negedge clk);clear=0;tick=0;
                repeat(2)@(negedge clk);last=ident;
            end
            gate=1'(g);level=8'(l);trig=1'(t);clear=1'(c);period=16'(p);a=32'(aa);r=32'(rr);tick=1;
            @(negedge clk);tick=0;
            if($signed(x[0])!==xx || $signed(e[0])!==ee || dead[0]!==1'(dd))
                $fatal(1,"FAIL frontend inst=%0d frame=%0d x=%0d/%0d env=%0d/%0d dead=%0d/%0d",ident,checks,x[0],xx,e[0],ee,dead[0],dd);
            checks++;
            repeat(2)@(negedge clk);
        end
        $fclose(f);$display("PASS tb_performance_frontend samples=%0d",checks);$finish;
    end
endmodule
