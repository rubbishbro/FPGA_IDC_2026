`timescale 1ns/1ps
// One shared 24x25 multiplier: vibrato depth, ratio interpolation, then K*lambda.
// Nominal coefficients are immutable. All writes target the inactive a1 buffer;
// commit is permitted only before a fresh audio snapshot, never during a frame.
module eng1_pitch #(
    parameter int SLOTS=16,N_MODES=64,INTERVAL=96
)(
    input logic clk,rst_n,clear,sample_tick,commit_ok,
    input logic [1:0] cleanup,
    input logic [$clog2(N_MODES+1)-1:0] n_modes,
    input logic [SLOTS-1:0] slot_source,
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
    import pitch_tables_pkg::*;
    localparam int IW=$clog2(N_MODES),SW=$clog2(SLOTS),TW=$clog2(INTERVAL+1);
    typedef enum logic [4:0] {IDLE,SETUP,VIB_MUL,VIB_APPLY,RATIO_LD,RATIO_MUL,RATIO_APPLY,
        RD,WAIT_RD,CO_LD,CO_MUL,CO_APPLY,CO_OUT,COMMIT,ACK,VIB_ROUND} state_t;
    state_t st;
    logic [13:0] bend[2],candidate_bend[2];
    logic [6:0] wheel[2],candidate_wheel[2];
    logic signed [17:0] cents[2],next_cents[2];
    logic signed [23:0] next_delta[2];
    logic signed [23:0] current_delta[2];
    logic [23:0] lfo_phase,phase_job;
    logic [TW-1:0] tick_count;
    logic due,enabled,control_job,source,cleanup_wait;
    logic [SLOTS-1:0] sources_job;
    logic [SLOTS-1:0] active_sources;
    logic [IW:0] nm;
    logic [SW-1:0] slot;
    logic [IW-1:0] mode;
    logic [24:0] ratio_base;
    logic [8:0] ratio_index;
    logic [7:0] ratio_fraction;
    logic signed [31:0] lower_q,base_q,upper_q;
    logic signed [23:0] mul_a;
    logic signed [24:0] mul_b;
    logic signed [48:0] product;
    logic signed [31:0] vibration_q;
    logic signed [31:0] vibration,target,slewed,offset,bend_center;
    logic signed [63:0] adjusted;
    wire cancelled=control_job && control_cancel;
    assign busy=st!=IDLE;
    // Ready is asserted BEFORE the committing edge. Cancellation can still
    // veto that same edge; there is no unacknowledged irreversible cycle.
    assign control_rejected=st==CO_LD && p_tag!=PITCH_TAG && control_job && control_valid &&
                            !clear && !control_cancel && !(|cleanup);
    assign control_ready=control_rejected ||
        (st==COMMIT && commit_ok && control_job && control_valid && !control_cancel &&
         slot_source==sources_job && !clear && !(|cleanup));
    assign sources_ready=!enabled || (slot_source==active_sources && !cleanup_wait);
    assign p_re=st==RD;
    assign p_addr={slot,mode};
    assign co_addr={slot,mode};
    assign co_we=st==CO_OUT && !clear && !cancelled && !(|cleanup);
    always_comb begin
        vibration=vibration_q;
        bend_center=32'($signed({1'b0,candidate_bend[source]}))-8192;
        target=(((bend_center<<<4)+(bend_center<<<3)+bend_center)>>>2)+vibration;
        if(target>56320)target=56320;
        if(target< -56320)target=-56320;
        slewed=target;
        if(target>32'(cents[source])+512)slewed=32'(cents[source])+512;
        if(target<32'(cents[source])-512)slewed=32'(cents[source])-512;
        offset=slewed+56320;
        adjusted=64'(base_q)+((64'(product)+64'sd2097152)>>>22);
        if(adjusted>64'(upper_q))co_a1=upper_q;
        else if(adjusted<64'(lower_q))co_a1=lower_q;
        else co_a1=32'(adjusted);
    end
    // The only multiplication operator in this module.
    always_ff @(posedge clk) if(st==VIB_MUL || st==RATIO_MUL || st==CO_MUL)
        product<=mul_a*mul_b;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            st<=IDLE;active_bank<=0;active_delta<='0;commit_pulse<=0;
            tick_count<=0;due<=0;enabled<=0;lfo_phase<=0;phase_job<=0;control_job<=0;cleanup_wait<=0;
            source<=0;sources_job<=0;active_sources<=0;nm<=0;slot<=0;mode<=0;
            ratio_base<=0;ratio_index<=0;ratio_fraction<=0;lower_q<=0;base_q<=0;upper_q<=0;
            mul_a<=0;mul_b<=0;
            vibration_q<=0;
            for(int s=0;s<2;s++)begin
                bend[s]<=8192;candidate_bend[s]<=8192;wheel[s]<=0;candidate_wheel[s]<=0;
                cents[s]<=0;next_cents[s]<=0;next_delta[s]<=0;current_delta[s]<=0;
            end
        end else begin
            commit_pulse<=0;
            if(sample_tick)begin
                if(tick_count==TW'(INTERVAL-1))begin tick_count<=0;due<=1;lfo_phase<=lfo_phase+LFO_STEP;end
                else tick_count<=tick_count+1'b1;
            end
            if(clear)begin
                st<=IDLE;active_bank<=0;active_delta<='0;enabled<=0;due<=0;cleanup_wait<=0;
                tick_count<=0;lfo_phase<=0;control_job<=0;
                for(int s=0;s<2;s++)begin bend[s]<=8192;wheel[s]<=0;cents[s]<=0;current_delta[s]<=0;end
            end else if(|cleanup)begin
                // Discard partial work; another source keeps its active pitch
                // until a complete replacement batch is ready.
                st<=IDLE;due<=1;control_job<=0;cleanup_wait<=1;
                for(int s=0;s<2;s++)if(cleanup[s])begin bend[s]<=8192;wheel[s]<=0;cents[s]<=0;end
            end else if(cancelled)begin st<=IDLE;control_job<=0;due<=1;end
            else case(st)
                IDLE: if((control_valid && !control_cancel) || (due && enabled) || !sources_ready)begin
                    for(int s=0;s<2;s++)begin candidate_bend[s]<=bend[s];candidate_wheel[s]<=wheel[s];end
                    control_job<=control_valid && !control_cancel;
                    if(control_valid && !control_cancel)begin
                        if(control_data[31:28]==4)candidate_bend[control_source]<={control_data[16:10],control_data[23:17]};
                        else candidate_wheel[control_source]<=control_data[16:10];
                    end
                    sources_job<=slot_source;nm<=n_modes;phase_job<=lfo_phase;
                    source<=0;due<=0;st<=SETUP;
                    if(!(control_valid && !control_cancel) && !due)begin
                        // An ownership change needs the already active ratios,
                        // without advancing a trajectory an extra control tick.
                        for(int s=0;s<2;s++)begin next_cents[s]<=cents[s];next_delta[s]<=current_delta[s];end
                        slot<=0;mode<=0;st<=n_modes==0?COMMIT:RD;
                    end
                end
                SETUP:begin
                    mul_a<=24'(pitch_sine({1'b0,phase_job[23:16]}));
                    mul_b<=25'({1'b0,pitch_depth({2'b0,candidate_wheel[source]})});
                    st<=VIB_MUL;
                end
                VIB_MUL:st<=VIB_ROUND;
                // Isolate rounding from target clamp/slew and ratio indexing.
                // One extra preparation clock per source; commit stays atomic.
                VIB_ROUND:begin
                    vibration_q<=32'((product+49'sd16384)>>>15);st<=VIB_APPLY;
                end
                VIB_APPLY:begin
                    next_cents[source]<=18'(slewed);ratio_index<=9'(offset>>>8);ratio_fraction<=offset[7:0];st<=RATIO_LD;
                end
                RATIO_LD:begin
                    ratio_base<=pitch_ratio(ratio_index);
                    mul_a<=24'(pitch_ratio(ratio_index+1'b1)-pitch_ratio(ratio_index));
                    mul_b<=25'({1'b0,ratio_fraction});st<=RATIO_MUL;
                end
                RATIO_MUL:st<=RATIO_APPLY;
                RATIO_APPLY:begin
                    next_delta[source]<=24'($signed({1'b0,ratio_base})+32'((product+49'sd128)>>>8)-32'sd16777216);
                    if(!source)begin source<=1;st<=SETUP;end
                    else begin slot<=0;mode<=0;st<=nm==0?COMMIT:RD;end
                end
                RD:st<=WAIT_RD;
                WAIT_RD:st<=CO_LD;
                CO_LD:begin
                    if(p_tag!=PITCH_TAG)begin
                        st<=ACK;control_job<=0;due<=0;
                    end else begin
                        lower_q<=p_lower;base_q<=p_base;upper_q<=p_upper;
                        mul_a<=next_delta[sources_job[slot]];mul_b<=25'(p_slope);st<=CO_MUL;
                    end
                end
                CO_MUL:st<=CO_APPLY;
                CO_APPLY:st<=CO_OUT;
                CO_OUT:begin
                    if({1'b0,mode}+1'b1>=nm)begin
                        mode<=0;
                        if(slot==SW'(SLOTS-1))st<=COMMIT;
                        else begin slot<=slot+1'b1;st<=RD;end
                    end else begin mode<=mode+1'b1;st<=RD;end
                end
                COMMIT:if(slot_source!=sources_job)begin st<=IDLE;due<=1;end
                else if(commit_ok && (!control_job || (control_valid && !control_cancel)))begin
                    active_bank<=!active_bank;commit_pulse<=1;enabled<=1;cleanup_wait<=0;
                    active_sources<=sources_job;
                    for(int s=0;s<2;s++)begin
                        bend[s]<=candidate_bend[s];wheel[s]<=candidate_wheel[s];cents[s]<=next_cents[s];current_delta[s]<=next_delta[s];
                    end
                    for(int i=0;i<SLOTS;i++)active_delta[i*24 +:24]<=next_delta[sources_job[i]];
                    control_job<=0;st<=ACK;
                end
                ACK:st<=IDLE;
                default:st<=IDLE;
            endcase
        end
    end
endmodule
