`timescale 1ns/1ps
module fanout_parts_case #(parameter int SLOTS=16)(input logic clk,rst_n,output logic done=0);
    import router_pkg::*;
    localparam int GROUPS=(SLOTS+3)/4;
    logic [GROUPS+2:0][1:0] leaves;
    wire parent_n=leaves[0][1];
    wire [GROUPS-1:0] group_n;
    for(genvar g=0;g<GROUPS;g++)assign group_n[g]=leaves[g+1][1];
    always @(posedge clk or negedge rst_n)
        if(!rst_n)leaves<='0;
        else for(int i=0;i<GROUPS+3;i++)leaves[i]<={leaves[i][0],1'b1};
    logic raw_tick=0,tick=0,tick_exc=0,tick_env=0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)begin tick<=0;tick_exc<=0;tick_env<=0;end
        else begin tick<=raw_tick;tick_exc<=raw_tick;tick_env<=raw_tick;end
    logic [31:0] random_state=32'h73628419;
    logic [SLOTS-1:0] note_on=0,retrigger=0,slot_clear=0;
    logic [SLOTS*8-1:0] strike_level=0;
    logic [SLOTS*16-1:0] slot_period;
    logic [SLOTS*24-1:0] slot_pitch_delta=0;
    logic [SLOTS*32-1:0] slot_a_step,slot_r_step;
    instrument_e inst=INST_PIANO;
    logic midi_mode=0;
    wire signed [SLOTS-1:0][31:0] old_x,new_x,old_e,new_e;
    wire old_xv,new_xv,old_ev,new_ev;
    wire [SLOTS-1:0] old_dead,new_dead;
    exc_router_legacy #(.SLOTS(SLOTS)) old_exc(.clk(clk),.rst_n(parent_n),.smp_tick(tick),
        .slot_period(slot_period),.slot_pitch_delta(slot_pitch_delta),.strike_level(strike_level),
        .retrigger(retrigger),.slot_clear(slot_clear),.note_on(note_on),.inst(inst),.xmap(old_x),.xmap_valid(old_xv));
    exc_router #(.SLOTS(SLOTS),.SPLIT_RESET(1)) new_exc(.clk(clk),.rst_n(parent_n),.smp_tick(tick_exc),
        .rst_gen_n(leaves[GROUPS+1][1]),.rst_trumpet_n(leaves[GROUPS+2][1]),
        .slot_period(slot_period),.slot_pitch_delta(slot_pitch_delta),.strike_level(strike_level),
        .retrigger(retrigger),.slot_clear(slot_clear),.note_on(note_on),.inst(inst),.xmap(new_x),.xmap_valid(new_xv));
    env_router_legacy #(.SLOTS(SLOTS)) old_env(.clk(clk),.rst_n(parent_n),.smp_tick(tick),
        .slot_a_step(slot_a_step),.slot_r_step(slot_r_step),.envelope_level(strike_level),
        .retrigger(retrigger),.slot_clear(slot_clear),.midi_mode(midi_mode),.note_on(note_on),.note_gate(note_on),
        .inst(inst),.emap(old_e),.emap_valid(old_ev),.dead(old_dead));
    env_router #(.SLOTS(SLOTS)) new_env(.clk(clk),.rst_n(parent_n),.smp_tick(tick_env),
        .slot_a_step(slot_a_step),.slot_r_step(slot_r_step),.envelope_level(strike_level),
        .retrigger(retrigger),.slot_clear(slot_clear),.midi_mode(midi_mode),.note_on(note_on),.note_gate(note_on),
        .inst(inst),.emap(new_e),.emap_valid(new_ev),.dead(new_dead));
    integer checks=0;
    always @(posedge clk)begin
        #1;
        if(tick!==tick_exc || tick!==tick_env)$fatal(1,"FAIL tick phase");
        for(int i=0;i<GROUPS+3;i++)if(leaves[i]!==leaves[0])$fatal(1,"FAIL reset phase");
        if({old_x,old_xv,old_e,old_ev,old_dead}!=={new_x,new_xv,new_e,new_ev,new_dead})
            $fatal(1,"FAIL parts parity slots=%0d cycle=%0d inst=%0d",SLOTS,checks,inst);
        checks++;
    end
    initial begin
        for(int s=0;s<SLOTS;s++)begin
            slot_period[s*16+:16]=146;
            slot_a_step[s*32+:32]=32'd16777216;
            slot_r_step[s*32+:32]=32'd2236962;
        end
        for(int cycle=0;cycle<60000;cycle++)begin
            @(negedge clk);
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            raw_tick=(cycle%512==10);
            if(cycle%512==8)begin
                note_on=random_state[SLOTS-1:0];
                retrigger=(cycle%1024==8)?random_state[SLOTS-1:0]:'0;
                slot_clear=(cycle%2048==8)?~random_state[SLOTS-1:0]:'0;
                for(int s=0;s<SLOTS;s++)begin
                    strike_level[s*8+:8]=8'(random_state>>s);
                    slot_pitch_delta[s*24+:24]=24'(cycle%5*1234);
                end
            end
            case((cycle/5000)%6)
                0:inst=INST_PIANO;1:inst=INST_GUITAR;2:inst=INST_FLUTE;
                3:inst=INST_TRUMPET;4:inst=INST_VIOLIN;5:inst=INST_CELLO;
            endcase
            midi_mode=cycle[10];
        end
        done=1;
        $display("PASS control fanout slots=%0d checked_cycles=%0d",SLOTS,checks);
    end
endmodule
module tb_control_fanout;
    logic clk=0,rst_n=1;
    always #5 clk=~clk;
    wire d4,d7,d16;
    fanout_parts_case #(.SLOTS(4)) a(clk,rst_n,d4);
    fanout_parts_case #(.SLOTS(7)) b(clk,rst_n,d7);
    fanout_parts_case #(.SLOTS(16)) c(clk,rst_n,d16);
    initial begin
        #2;rst_n=0;#21;rst_n=1;
        #170003;rst_n=0;#17;rst_n=1;
        #180007;rst_n=0;#29;rst_n=1;
    end
    initial begin wait(d4&&d7&&d16);$display("PASS tb_control_fanout");$finish;end
    initial begin #700000;$fatal(1,"FAIL control fanout timeout");end
endmodule
