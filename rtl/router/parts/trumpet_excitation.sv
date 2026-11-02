`timescale 1ns/1ps
// Independent trumpet drive, owned by exc_router. No multiplier/divider/DSP.
// Positive triangular opening + gap + shorter negative closing; closing slope
// is 16x and duration 1/4, so each complete lip pulse has exactly zero area.
// Offline three-term dyadic calibration approximately preserves the impulse
// train's fundamental. This is a hardware approximation of LipExcitation,
// not the experiment's sine lobes / Gaussian random process bit for bit.
// Onset jitter: triangular random rate (~0.6% std) and amplitude (~7.6% std),
// decaying in ~28ms. Air: permanent floor + decaying ~40ms onset component,
// filtered with alpha=1/2 LP and alpha=1/16 DC removal (~0.5..5kHz band).
// clk_en captures one frame. A shared pipeline visits every slot and publishes
// the whole xmap atomically with a one-cycle xmap_valid completion pulse.
module trumpet_excitation #(
    parameter int SLOTS=16,
    parameter int SR_HZ=48000
)(
    input logic clk,rst_n,clk_en,enable,clear,
    input logic [SLOTS*16-1:0] slot_period,
    input logic [SLOTS*24-1:0] slot_pitch_delta,
    input logic [SLOTS*8-1:0] strike_level,
    input logic [SLOTS-1:0] note_on,retrigger,slot_clear,
    output logic signed [SLOTS-1:0][31:0] xmap,
    output logic xmap_valid
);
    import trumpet_excitation_pkg::*;
    // synthesis translate_off
    initial if(SR_HZ!=48000)$error("trumpet lip ROM requires 48000Hz");
    // synthesis translate_on
    typedef enum logic[2:0] {REST,OPEN_UP,OPEN_DOWN,GAP,CLOSE_DOWN,CLOSE_UP} stage_t;
    typedef struct packed {
        logic [39:0] phase;
        logic signed [23:0] rate;
        logic signed [31:0] wave,slope,lp,dc;
        logic [15:0] onset,air;
        logic [22:0] rng;
        logic [5:0] remaining,half_len,close_len,gap_len;
        stage_t stage;
        logic note;
    } voice_t;
    localparam int VW=(SLOTS<2)?1:$clog2(SLOTS);
    // One synchronous read/write state store. Clear invalidates slots, rather
    // than broadcasting reset to every data bit or clearing block RAM contents.
    (* syn_ramstyle="block_ram" *) logic [$bits(voice_t)-1:0] state_mem[0:SLOTS-1];
    logic [$bits(voice_t)-1:0] state_read;
    logic [SLOTS-1:0] live;
    logic [VW-1:0] slot;
    typedef enum logic[3:0] {IDLE,READ_SLOT,LOAD_SLOT,PREP,SCALE,PERTURB,
        TERM0,TERM1,TERM2,ADVANCE,WRITE_SLOT,NEXT_SLOT,PUBLISH} work_t;
    work_t work;
    logic [SLOTS*16-1:0] periods;
    logic [SLOTS*24-1:0] pitch;
    logic [SLOTS*8-1:0] levels;
    logic [SLOTS-1:0] gates,triggers,clears;
    logic signed [SLOTS-1:0][31:0] pending_x,published_x;
    voice_t q,next_voice,updated;
    lip_cfg_t cfg;
    logic [15:0] period;
    logic [23:0] delta;
    logic [7:0] level;
    logic start,hit,voice_active;
    logic [40:0] phase_sum,phase_limit;
    logic [3:0] onset_shift,air_shift;
    logic signed [4:0] rate_draw;
    logic signed [3:0] amp_draw,air_draw;
    logic signed [31:0] force_q24,amp_unit,air_unit,perturbed,white,coefficient,new_step;
    logic signed [23:0] new_rate;
    logic signed [32:0] increment;
    logic signed [31:0] wave_delta;
    logic signed [33:0] mixed;
    function automatic logic[22:0] seed(input int slot);
        return 23'h5a34d1 ^ 23'(slot+1);
    endfunction
    function automatic logic[3:0] fade_shift(input logic[15:0] value);
        if(value>=32768)return 0;
        if(value>=16384)return 1;
        if(value>=8192)return 2;
        if(value>=4096)return 3;
        if(value>=2048)return 4;
        if(value>=1024)return 5;
        if(value>=512)return 6;
        return 15;
    endfunction
    function automatic logic[15:0] decay_onset(input logic[15:0] value);
        logic [16:0] decrement;
        decrement=((17'(value)+2047)>>11)+((17'(value)+4095)>>12);
        return value<=decrement ? 16'd0 : 16'(17'(value)-decrement);
    endfunction
    function automatic logic[15:0] decay_air(input logic[15:0] value);
        logic [16:0] decrement;
        decrement=((17'(value)+2047)>>11)+((17'(value)+32767)>>15);
        return value<=decrement ? 16'd0 : 16'(17'(value)-decrement);
    endfunction
    // Tiny signed 3-bit magnitude scale: two adders and fixed wiring shifts.
    function automatic logic signed[31:0] scale_small(
        input logic signed[31:0] unit_value,input logic signed[3:0] draw
    );
        logic [2:0] magnitude;
        logic signed[31:0] value;
        magnitude=draw[3] ? 3'(-draw) : draw[2:0];
        value=(magnitude[0]?unit_value:32'sd0)+
              (magnitude[1]?(unit_value<<<1):32'sd0)+
              (magnitude[2]?(unit_value<<<2):32'sd0);
        return draw[3] ? -value : value;
    endfunction

    function automatic voice_t empty_voice(input int index);
        voice_t v;
        v='0;v.rng=seed(index);v.stage=REST;
        return v;
    endfunction

    // Only this selected slot feeds the arithmetic and the 32-entry table.
    // Calibration reuses a single shifted term per cycle (TERM0/1/2).
    logic [4:0] coefficient_shift;
    logic coefficient_negative;
    logic signed [31:0] shifted_term,signed_term;
    always_comb begin
        case(work)
            TERM1:begin coefficient_shift=cfg.shift1;coefficient_negative=cfg.negative[1];end
            TERM2:begin coefficient_shift=cfg.shift2;coefficient_negative=cfg.negative[2];end
            default:begin coefficient_shift=cfg.shift0;coefficient_negative=cfg.negative[0];end
        endcase
        shifted_term=perturbed>>>coefficient_shift;
        signed_term=coefficient_negative ? -shifted_term : shifted_term;
        increment=33'sd16777216+33'($signed(delta))+33'(q.rate);
        wave_delta=0;
        case(q.stage)
            OPEN_UP:wave_delta=q.slope;
            OPEN_DOWN:wave_delta=-q.slope;
            CLOSE_DOWN:wave_delta=-(q.slope<<<4);
            CLOSE_UP:wave_delta=q.slope<<<4;
            default:wave_delta=0;
        endcase
        next_voice=q;
        if(!voice_active)begin
            next_voice=empty_voice(int'(slot));next_voice.note=gates[slot];
        end else begin
            next_voice.note=gates[slot];
            next_voice.rng={q.rng[21:0],q.rng[22]^q.rng[17]};
            next_voice.onset=start?16'hffff:decay_onset(q.onset);
            next_voice.air=start?16'hffff:decay_air(q.air);
            next_voice.lp=start ? white>>>1 : 32'(33'(q.lp)+((33'(white)-33'(q.lp))>>>1));
            next_voice.dc=start ? 32'd0 : 32'(33'(q.dc)+((33'(q.lp)-33'(q.dc))>>>4));
            if(hit)begin
                next_voice.phase=start?40'd0:40'(phase_sum-phase_limit);
                next_voice.rate=new_rate;next_voice.slope=new_step;next_voice.wave=new_step;
                next_voice.half_len=6'd1<<cfg.half_shift;
                next_voice.close_len=6'd1<<(cfg.half_shift-3'd2);
                next_voice.gap_len={1'b0,cfg.gap};
                next_voice.stage=OPEN_UP;next_voice.remaining=(6'd1<<cfg.half_shift)-1'b1;
            end else begin
                next_voice.phase=phase_sum[39:0];
                next_voice.wave=q.wave+wave_delta;
                next_voice.remaining=q.remaining-1'b1;
                case(q.stage)
                    OPEN_UP:if(q.remaining==1)begin next_voice.stage=OPEN_DOWN;next_voice.remaining=q.half_len;end
                    OPEN_DOWN:if(q.remaining==1)begin next_voice.stage=GAP;next_voice.remaining=q.gap_len;end
                    GAP:begin
                        next_voice.wave=0;
                        if(q.remaining==1)begin next_voice.stage=CLOSE_DOWN;next_voice.remaining=q.close_len;end
                    end
                    CLOSE_DOWN:if(q.remaining==1)begin next_voice.stage=CLOSE_UP;next_voice.remaining=q.close_len;end
                    CLOSE_UP:if(q.remaining==1)begin next_voice.stage=REST;next_voice.remaining=0;end
                    default:begin next_voice.wave=0;next_voice.remaining=q.remaining;end
                endcase
            end
        end
        mixed=34'(updated.wave)+34'(updated.lp)-34'(updated.dc);
    end
    // RAM data has no reset/clear path. The live mask is the validity fence.
    always_ff @(posedge clk)begin
        if(work==READ_SLOT)state_read<=state_mem[slot];
        if(work==WRITE_SLOT && enable && !clear)state_mem[slot]<=updated;
    end
    // Frame data is sampled once; external changes during a job cannot mix slots.
    always_ff @(posedge clk)begin
        if(work==IDLE && clk_en && enable && !clear)begin
            periods<=slot_period;pitch<=slot_pitch_delta;levels<=strike_level;
            gates<=note_on;triggers<=retrigger;clears<=slot_clear;
        end
        if(work==LOAD_SLOT)begin
            q<=live[slot]?voice_t'(state_read):empty_voice(int'(slot));
            period<=periods[slot*16 +:16];delta<=pitch[slot*24 +:24];level<=levels[slot*8 +:8];
            cfg<=lip_config(periods[slot*16 +:16]);
        end
        if(work==PREP)begin
            start<=triggers[slot] || !q.note;
            voice_active<=gates[slot] && !clears[slot] && cfg.valid;
            phase_sum<={1'b0,q.phase}+41'(increment);
            phase_limit<={1'b0,period,24'd0};
            hit<=triggers[slot] || !q.note || ({1'b0,q.phase}+41'(increment)>={1'b0,period,24'd0});
            force_q24<=$signed({1'b0,level,16'd0});
            onset_shift<=(triggers[slot] || !q.note)?4'd0:fade_shift(q.onset);
            air_shift<=(triggers[slot] || !q.note)?4'd0:fade_shift(q.air);
            rate_draw<=$signed({1'b0,q.rng[3:0]})-$signed({1'b0,q.rng[7:4]});
            amp_draw<=$signed({1'b0,q.rng[10:8]})-$signed({1'b0,q.rng[13:11]});
            air_draw<=$signed({1'b0,q.rng[16:14]})-$signed({1'b0,q.rng[19:17]});
        end
        if(work==SCALE)begin
            new_rate<=onset_shift==15?24'sd0:((24'(rate_draw)<<<14)>>>onset_shift);
            amp_unit<=onset_shift==15?32'sd0:(((force_q24>>>6)+(force_q24>>>7))>>>onset_shift);
            air_unit<=(force_q24>>>cfg.air_shift)+
                (air_shift==15?32'sd0:((force_q24>>>(cfg.air_shift-4'd3))>>>air_shift));
        end
        if(work==PERTURB)begin
            perturbed<=force_q24+scale_small(amp_unit,amp_draw);
            white<=scale_small(air_unit,air_draw);
        end
        if(work==TERM0)coefficient<=signed_term;
        if(work==TERM1)coefficient<=coefficient+signed_term;
        if(work==TERM2)new_step<=coefficient+signed_term;
        if(work==ADVANCE)updated<=next_voice;
        if(work==WRITE_SLOT)begin
            if(mixed>34'sd2147483647)pending_x[slot]<=32'sh7fffffff;
            else if(mixed< -34'sd2147483648)pending_x[slot]<=32'sh80000000;
            else pending_x[slot]<=32'(mixed);
        end
    end
    for(genvar v=0;v<SLOTS;v++)begin:g_output
        assign xmap[v]=enable && !clear && note_on[v] && !slot_clear[v] ? published_x[v] : 32'sd0;
    end
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin work<=IDLE;slot<=0;live<='0;published_x<='0;xmap_valid<=0;end
        else begin
            xmap_valid<=0;
            if(clear || !enable)begin
                work<=IDLE;slot<=0;live<='0;published_x<='0;xmap_valid<=clk_en && enable;
            end else case(work)
                IDLE:if(clk_en)begin slot<=0;work<=READ_SLOT;end
                READ_SLOT:work<=LOAD_SLOT;
                LOAD_SLOT:work<=PREP;
                PREP:work<=SCALE;
                SCALE:work<=PERTURB;
                PERTURB:work<=TERM0;
                TERM0:work<=TERM1;
                TERM1:work<=TERM2;
                TERM2:work<=ADVANCE;
                ADVANCE:work<=WRITE_SLOT;
                WRITE_SLOT:begin live[slot]<=1;work<=NEXT_SLOT;end
                NEXT_SLOT:if(slot==VW'(SLOTS-1))work<=PUBLISH;
                          else begin slot<=slot+1'b1;work<=READ_SLOT;end
                PUBLISH:begin published_x<=pending_x;xmap_valid<=1;work<=IDLE;end
                default:work<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    always @(posedge clk)if(rst_n && enable && !clear && clk_en && work!=IDLE)
        $fatal(1,"trumpet_excitation: frame overrun");
    // synthesis translate_on
endmodule
