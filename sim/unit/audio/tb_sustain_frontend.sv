`timescale 1ns/1ps
module tb_sustain_frontend;
    import router_pkg::*;
    logic clk=0,rst_n=0,tick=0;
    always #5 clk=~clk;
    instrument_e inst=INST_FLUTE;
    logic [3:0] gate=0,trig=0,clr=0,dead;
    logic [31:0] level=32'hff810201;
    logic [63:0] periods;
    logic [127:0] attacks,releases;
    logic signed [3:0][31:0] x,e;
    exc_router #(.SLOTS(4)) ex(.clk(clk),.rst_n(rst_n),.smp_tick(tick),.slot_period(periods),
        .strike_level(level),.retrigger(trig),.slot_clear(clr),.note_on(gate),.inst(inst),.xmap(x),.xmap_valid());
    env_router #(.SLOTS(4)) en(.clk(clk),.rst_n(rst_n),.smp_tick(tick),.slot_a_step(attacks),.slot_r_step(releases),
        .envelope_level(level),.retrigger(trig),.slot_clear(clr),.midi_mode(1'b1),.note_on(gate),.note_gate(gate),.inst(inst),
        .emap(e),.emap_valid(),.dead(dead));
    integer phase[4],env_state[4],env[4],prev_gate[4],count[4];
    integer period[4],ast[4],rst[4],expected_x,checks=0,total_pulses=0;
    integer expected_xs[4],fd,rc,id,note;
    longint temp;
    task automatic sample;
        // Independent specification oracle, with explicit sample-level event inputs.
        for(int i=0;i<4;i++)begin
            expected_x=0;
            if(clr[i] || !gate[i])phase[i]=0;
            else if(trig[i] || !prev_gate[i] || phase[i]==0)begin
                expected_x=int'(level[i*8 +:8])<<16;phase[i]=period[i]-1;count[i]++;total_pulses++;
            end else phase[i]--;
            if(clr[i])begin env[i]=0;env_state[i]=0;end
            else if(trig[i] || (gate[i] && !prev_gate[i]))begin env[i]=0;env_state[i]=1;end
            else if(!gate[i])begin
                if(env[i]<=rst[i])begin env[i]=0;env_state[i]=0;end
                else begin env[i]-=rst[i];env_state[i]=4;end
            end else if(env_state[i]==1)begin
                temp=longint'(env[i])+ast[i];
                if(temp>2147483647)begin env[i]=2147483647;env_state[i]=2;end else env[i]=int'(temp);
            end else if(env_state[i]==2)begin
                if(env[i]<=536870911+1048576)begin env[i]=536870911;env_state[i]=3;end
                else env[i]-=1048576;
            end else if(env_state[i]==0)env_state[i]=1;
            prev_gate[i]=gate[i];
            // Save expected pulse separately while all lanes update together.
            expected_xs[i]=expected_x;
        end
        @(negedge clk);tick=1;@(negedge clk);tick=0;
        for(int i=0;i<4;i++)begin
            checks++;
            if(x[i]!==expected_xs[i] || e[i]!==env[i] || dead[i]!==1'(env_state[i]==0))
                $fatal(1,"FAIL frontend inst=%0d lane=%0d x=%0d/%0d env=%0d/%0d dead=%b",inst,i,x[i],expected_xs[i],e[i],env[i],dead[i]);
        end
        repeat(2)@(negedge clk);
    endtask
    initial begin
        fd=$fopen("frontend_cases.txt","r");if(!fd)$fatal(1,"FAIL no frontend cases");
        repeat(4)@(negedge clk);rst_n=1;
        for(int k=0;k<4;k++)begin
            rc=$fscanf(fd,"%d",id);inst=instrument_e'(id);
            for(int i=0;i<4;i++)begin
                rc=$fscanf(fd,"%d %d %d %d",note,period[i],ast[i],rst[i]);
                if(rc!=4)$fatal(1,"FAIL frontend vector");
                periods[i*16 +:16]=16'(period[i]);attacks[i*32 +:32]=32'(ast[i]);releases[i*32 +:32]=32'(rst[i]);
                phase[i]=0;env_state[i]=0;env[i]=0;prev_gate[i]=0;count[i]=0;
            end
            gate=0;trig=0;clr=15;
            repeat(3)sample();clr=0;gate=15;
            for(int n=0;n<48000;n++)begin
                trig=0;clr=0;
                if(n==5000)level=32'h0281ff01;
                if(n==10000)trig=1;
                if(n==12000)gate[1]=0;
                if(n==15000)begin gate[1]=1;trig[1]=1;end
                if(n==30000)begin clr[2]=1;gate[2]=0;end
                sample();
            end
            if(count[0]<100 || count[3]<100)$fatal(1,"FAIL no sustained drive");
            gate=0;trig=0;clr=0;
            repeat(5000)sample();
            if(dead!=15 || e!='0 || x!='0)$fatal(1,"FAIL release did not finish");
        end
        $display("PASS tb_sustain_frontend checks=%0d pulses=%0d four_instruments_one_second_each",checks,total_pulses);$finish;
    end
    initial begin #20000000;$fatal(1,"FAIL frontend timeout");end
endmodule
