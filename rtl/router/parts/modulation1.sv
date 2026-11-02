`timescale 1ns/1ps
// Per-slot PAD aftertouch. 100 pressure counts = 60 cents, referenced to
// PAD_NOTE_ON_TH. Released voices retain their last committed pitch.
// One start/busy/done job updates one slot's first MODES_PER_JOB modes.
// Immutable P1T1 metadata stays in pm_*; results write the existing ca_a12 RAM.
// voice_router guarantees no engine read of this slot until the job and ratio finish.
module modulation1 #(
    parameter int SLOTS=16,N_MODES=64,MODES_PER_JOB=6, // TODO: 听感还需要验证
    parameter logic [7:0] PAD_NOTE_ON_TH=8'd102
)(
    input logic clk,rst_n,clear,
    input logic start,
    input logic [$clog2(SLOTS)-1:0] job_slot,
    output logic done,
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
    initial if(MODES_PER_JOB<1)$fatal(1,"invalid aftertouch MODES_PER_JOB");
    // synthesis translate_on
    localparam int JOB_LIMIT=(MODES_PER_JOB<N_MODES)?MODES_PER_JOB:N_MODES;
    localparam logic [31:0] PITCH_TAG=32'h50315431;
    localparam int IW=$clog2(N_MODES),SW=$clog2(SLOTS);
    // Existing Flash ratio page: index 220 is 0 cents, Q24 ratios.
    // Sine/depth words are no longer used by aftertouch.
    (* syn_ramstyle="block_ram" *) logic [24:0] ratio0[0:511],ratio1[0:511];
    logic [24:0] ratio_q0,ratio_q1,ratio_base;
    logic [8:0] ratio_index;
    logic [7:0] ratio_fraction;
    typedef enum logic [3:0] {IDLE,MAP,RATIO_LD,RATIO_DATA,RATIO_MUL,RATIO_APPLY,
        RD,WAIT_RD,CO_LD,CO_MUL,CO_APPLY,CO_OUT,COMMIT,ACK} state_t;
    state_t st;
    logic [7:0] level_job;
    logic gate_job,source_job;
    logic [SLOTS-1:0] active_sources,active_enabled,valid_slots;
    logic enabled_job;
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
        if(level_job>PAD_NOTE_ON_TH)
            pressure_diff=32'(level_job)-32'(PAD_NOTE_ON_TH);
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
    assign sources_ready=clear || ((&valid_slots) && slot_source==active_sources &&
                                  active_enabled=={SLOTS{pressure_enable}});
    assign active_bank=1'b0; // compatibility observer; coefficients are updated in place.
    assign p_re=st==RD;
    assign p_addr={slot,mode};
    assign co_addr={slot,mode};
    assign co_we=st==CO_OUT && !clear && !(|cleanup);
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            st<=IDLE;active_delta<='0;commit_pulse<=0;done<=0;
            level_job<=0;gate_job<=0;enabled_job<=0;source_job<=0;
            active_enabled<=0;active_sources<=0;valid_slots<='1;
            nm<=0;slot<=0;mode<=0;ratio_base<=0;ratio_index<=0;ratio_fraction<=0;
            mul_a<=0;mul_b<=0;lower_q<=0;base_q<=0;upper_q<=0;
            for(int s=0;s<SLOTS;s++)begin cents[s]<=0;next_cents[s]<=0;next_delta[s]<=0;end
        end else begin
            commit_pulse<=0;done<=0;
            if(clear)begin
                st<=IDLE;active_delta<='0;commit_pulse<=0;done<=0;
                active_enabled<=0;active_sources<=0;valid_slots<='1;
                for(int s=0;s<SLOTS;s++)cents[s]<=0;
            end else if(|cleanup)begin
                // Abort a partial batch. Source ownership/disabled MIDI mode
                // rebuilds nominal ratios before a newly owned voice can start.
                st<=IDLE;done<=1;valid_slots<='0;
            end else case(st)
                IDLE:if(start)begin
                    level_job<=pressure_level[job_slot*8 +:8];gate_job<=pressure_gate[job_slot];
                    enabled_job<=pressure_enable;source_job<=slot_source[job_slot];
                    nm<=n_modes>JOB_LIMIT ? (IW+1)'(JOB_LIMIT) : n_modes;
                    slot<=job_slot;mode<=0;st<=MAP;
                end
                MAP:begin
                    if(!enabled_job || source_job!=active_sources[slot])begin
                        next_cents[slot]<=0;next_delta[slot]<=0;
                        if(nm==0)st<=COMMIT;else st<=RD;
                    end else if(!gate_job)begin
                        next_cents[slot]<=cents[slot];next_delta[slot]<=active_delta[slot*24 +:24];
                        if(nm==0)st<=COMMIT;else st<=RD;
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
                    if(nm==0)st<=COMMIT;else st<=RD;
                end
                RD:st<=WAIT_RD;
                WAIT_RD:st<=CO_LD;
                CO_LD:if(p_tag!=PITCH_TAG)begin valid_slots[slot]<=0;st<=ACK;end
                else begin
                    lower_q<=p_lower;base_q<=p_base;upper_q<=p_upper;
                    mul_a<=next_delta[slot];mul_b<=25'(p_slope);st<=CO_MUL;
                end
                CO_MUL:st<=CO_APPLY;
                CO_APPLY:st<=CO_OUT;
                CO_OUT:if({1'b0,mode}+1'b1>=nm)st<=COMMIT;
                else begin mode<=mode+1'b1;st<=RD;end
                COMMIT:begin
                    // Router grants a whole slot job only after its engine read,
                    // with enough clocks left before the next excitation snapshot.
                    active_sources[slot]<=source_job;active_enabled[slot]<=enabled_job;
                    valid_slots[slot]<=1;commit_pulse<=1;
                    cents[slot]<=next_cents[slot];active_delta[slot*24 +:24]<=next_delta[slot];
                    st<=ACK;
                end
                ACK:begin done<=1;st<=IDLE;end
                default:st<=IDLE;
            endcase
        end
    end
endmodule
