`timescale 1ns/1ps
// Per-slot PAD aftertouch. 100 pressure counts = 60 cents, referenced to
// PAD_NOTE_ON_TH. Released voices retain their last committed pitch.
// Immutable P1T1 nominal coefficients; prepare the inactive a1 bank, then
// atomically publish both coefficients and excitation ratios at a frame boundary.
module modulation1 #(
    parameter int SLOTS=16,N_MODES=64,INTERVAL=96,
    parameter logic [7:0] PAD_NOTE_ON_TH=8'd102
)(
    input logic clk,rst_n,clear,sample_tick,commit_ok,
    input logic table_we,
    input logic [9:0] table_addr,
    input logic [31:0] table_data,
    input logic pressure_enable,
    input logic [SLOTS-1:0] pressure_gate,
    input logic [SLOTS*8-1:0] pressure_level,
    input logic [1:0] cleanup,
    input logic [$clog2(N_MODES+1)-1:0] n_modes,
    input logic [SLOTS-1:0] slot_source,
    // Compatibility handshake: wheel/bend controls are explicitly rejected.
    input logic control_valid,control_cancel,control_source,
    input logic [31:0] control_data,
    output logic control_ready,control_rejected,
    output logic active_bank,busy,commit_pulse,sources_ready,
    output logic [SLOTS*24-1:0] active_delta,
    output logic p_re,
    output logic [$clog2(SLOTS)+$clog2(N_MODES)-1:0] p_addr,
    input logic signed [31:0] p_lower,p_base,p_upper,p_slope,p_tag,
    output logic co_we,
    output logic [$clog2(SLOTS)+$clog2(N_MODES)-1:0] co_addr,
    output logic signed [31:0] co_a1
);
    // synthesis translate_off
    initial if(INTERVAL<1)$fatal(1,"aftertouch INTERVAL must be positive");
    // synthesis translate_on
    localparam logic [31:0] PITCH_TAG=32'h50315431;
    localparam int IW=$clog2(N_MODES),SW=$clog2(SLOTS),TW=(INTERVAL<2)?1:$clog2(INTERVAL);
    // Existing Flash ratio page: index 220 is 0 cents, Q24 ratios.
    // Sine/depth words are no longer used by aftertouch.
    (* syn_ramstyle="block_ram" *) logic [24:0] ratio0[0:511],ratio1[0:511];
    logic [24:0] ratio_q0,ratio_q1,ratio_base;
    logic [8:0] ratio_index;
    logic [7:0] ratio_fraction;
    typedef enum logic [3:0] {IDLE,MAP,RATIO_LD,RATIO_DATA,RATIO_MUL,RATIO_APPLY,
        RD,WAIT_RD,CO_LD,CO_MUL,CO_APPLY,CO_OUT,COMMIT,ACK} state_t;
    state_t st;
    logic [TW-1:0] tick_count;
    logic due;
    logic [SLOTS*8-1:0] levels_q,levels_job;
    logic [SLOTS-1:0] gates_q,gates_job,sources_job,active_sources;
    logic enabled_q,enabled_job,active_enabled;
    logic [IW:0] nm;
    logic [SW-1:0] slot;
    logic [IW-1:0] mode;
    logic [15:0] cents[SLOTS],next_cents[SLOTS]; // unsigned cents Q8
    logic signed [23:0] next_delta[SLOTS];
    logic signed [23:0] mul_a;
    logic signed [24:0] mul_b;
    logic signed [48:0] product;
    logic signed [31:0] lower_q,base_q,upper_q;
    logic signed [63:0] adjusted;
    logic [31:0] pressure_diff,target_cents,offset;
    always_comb begin
        pressure_diff=0;
        if(levels_job[slot*8 +:8]>PAD_NOTE_ON_TH)
            pressure_diff=32'(levels_job[slot*8 +:8])-32'(PAD_NOTE_ON_TH);
        // 60/100 = 3/5; rounded once into cents Q8 (100 -> exactly 15360).
        target_cents=(pressure_diff*768+2)/5;
        offset=target_cents+56320;
        adjusted=64'(base_q)+((64'(product)+64'sd2097152)>>>22);
        if(adjusted>64'(upper_q))co_a1=upper_q;
        else if(adjusted<64'(lower_q))co_a1=lower_q;
        else co_a1=32'(adjusted);
    end
    always_ff @(posedge clk)begin
        if(table_we && table_addr<512)begin
            ratio0[table_addr[8:0]]<=table_data[24:0];
            ratio1[table_addr[8:0]]<=table_data[24:0];
        end
        if(st==RATIO_LD)begin
            ratio_q0<=ratio0[ratio_index];ratio_q1<=ratio1[ratio_index+9'd1];
        end
        if(st==RATIO_MUL || st==CO_MUL)product<=mul_a*mul_b;
    end
    assign busy=st!=IDLE;
    assign control_rejected=control_valid && !control_cancel && !clear;
    assign control_ready=control_rejected;
    // Bypass the ownership barrier while this instrument/path is disabled.
    // Non-sustain instruments hold clear high and must still admit MIDI source 1.
    assign sources_ready=clear || (slot_source==active_sources && pressure_enable==enabled_q && enabled_q==active_enabled);
    assign p_re=st==RD;
    assign p_addr={slot,mode};
    assign co_addr={slot,mode};
    assign co_we=st==CO_OUT && !clear && !(|cleanup);
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            st<=IDLE;active_bank<=0;active_delta<='0;commit_pulse<=0;
            tick_count<=0;due<=0;levels_q<=0;levels_job<=0;gates_q<=0;gates_job<=0;
            enabled_q<=0;enabled_job<=0;active_enabled<=0;sources_job<=0;active_sources<=0;
            nm<=0;slot<=0;mode<=0;ratio_base<=0;ratio_index<=0;ratio_fraction<=0;
            mul_a<=0;mul_b<=0;lower_q<=0;base_q<=0;upper_q<=0;
            for(int s=0;s<SLOTS;s++)begin cents[s]<=0;next_cents[s]<=0;next_delta[s]<=0;end
        end else begin
            commit_pulse<=0;
            if(sample_tick)begin
                levels_q<=pressure_level;gates_q<=pressure_gate;enabled_q<=pressure_enable;
                if(tick_count==TW'(INTERVAL-1))begin tick_count<=0;due<=1;end
                else tick_count<=tick_count+1'b1;
            end
            if(clear)begin
                st<=IDLE;active_bank<=0;active_delta<='0;commit_pulse<=0;
                tick_count<=0;due<=0;gates_q<=0;enabled_q<=0;active_enabled<=0;active_sources<=0;
                for(int s=0;s<SLOTS;s++)cents[s]<=0;
            end else if(|cleanup)begin
                // Abort a partial batch. Source ownership/disabled MIDI mode
                // rebuilds nominal ratios before a newly owned voice can start.
                st<=IDLE;due<=1;
            end else case(st)
                IDLE:if(due || slot_source!=active_sources || enabled_q!=active_enabled)begin
                    levels_job<=levels_q;gates_job<=gates_q;enabled_job<=enabled_q;
                    sources_job<=slot_source;nm<=n_modes;slot<=0;mode<=0;due<=0;st<=MAP;
                end
                MAP:begin
                    if(!enabled_job || sources_job[slot]!=active_sources[slot])begin
                        next_cents[slot]<=0;next_delta[slot]<=0;
                        if(slot==SW'(SLOTS-1))begin slot<=0;if(nm==0)st<=COMMIT;else st<=RD;end
                        else slot<=slot+1'b1;
                    end else if(!gates_job[slot])begin
                        next_cents[slot]<=cents[slot];next_delta[slot]<=active_delta[slot*24 +:24];
                        if(slot==SW'(SLOTS-1))begin slot<=0;if(nm==0)st<=COMMIT;else st<=RD;end
                        else slot<=slot+1'b1;
                    end else begin
                        next_cents[slot]<=16'(target_cents);
                        ratio_index<=9'(offset>>8);ratio_fraction<=offset[7:0];st<=RATIO_LD;
                    end
                end
                RATIO_LD:st<=RATIO_DATA;
                RATIO_DATA:begin
                    ratio_base<=ratio_q0;mul_a<=24'(ratio_q1-ratio_q0);
                    mul_b<=25'({1'b0,ratio_fraction});st<=RATIO_MUL;
                end
                RATIO_MUL:st<=RATIO_APPLY;
                RATIO_APPLY:begin
                    next_delta[slot]<=24'($signed({1'b0,ratio_base})+32'((product+49'sd128)>>>8)-32'sd16777216);
                    if(slot==SW'(SLOTS-1))begin slot<=0;if(nm==0)st<=COMMIT;else st<=RD;end
                    else begin slot<=slot+1'b1;st<=MAP;end
                end
                RD:st<=WAIT_RD;
                WAIT_RD:st<=CO_LD;
                CO_LD:if(p_tag!=PITCH_TAG)st<=ACK;
                else begin
                    lower_q<=p_lower;base_q<=p_base;upper_q<=p_upper;
                    mul_a<=next_delta[slot];mul_b<=25'(p_slope);st<=CO_MUL;
                end
                CO_MUL:st<=CO_APPLY;
                CO_APPLY:st<=CO_OUT;
                CO_OUT:if({1'b0,mode}+1'b1>=nm)begin
                    mode<=0;
                    if(slot==SW'(SLOTS-1))st<=COMMIT;
                    else begin slot<=slot+1'b1;st<=RD;end
                end else begin mode<=mode+1'b1;st<=RD;end
                COMMIT:if(slot_source!=sources_job || enabled_q!=enabled_job || pressure_enable!=enabled_job)begin st<=IDLE;due<=1;end
                else if(commit_ok)begin
                    active_bank<=!active_bank;commit_pulse<=1;active_sources<=sources_job;active_enabled<=enabled_job;
                    for(int s=0;s<SLOTS;s++)begin
                        cents[s]<=next_cents[s];active_delta[s*24 +:24]<=next_delta[s];
                    end
                    st<=ACK;
                end
                ACK:st<=IDLE;
                default:st<=IDLE;
            endcase
        end
    end
endmodule
