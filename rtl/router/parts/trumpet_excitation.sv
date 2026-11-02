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
// All voices update on clk_en, matching the generic excitation snapshot timing.
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
    stage_t stage[SLOTS];
    logic [39:0] phase[SLOTS];
    logic signed [23:0] rate[SLOTS];
    logic signed [31:0] wave[SLOTS],step[SLOTS],air_lp[SLOTS],air_dc[SLOTS];
    logic [15:0] onset_env[SLOTS],air_env[SLOTS];
    logic [22:0] rng[SLOTS];
    logic [5:0] remaining[SLOTS],half_q[SLOTS],close_q[SLOTS],gap_q[SLOTS];
    logic [SLOTS-1:0] note_q;
    lip_cfg_t cfg[SLOTS];
    logic [40:0] phase_sum[SLOTS],limit[SLOTS];
    logic [SLOTS-1:0] starts,hit;
    logic signed [31:0] next_step[SLOTS],white[SLOTS];
    logic signed [23:0] next_rate[SLOTS];

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
    function automatic logic signed[31:0] calibrated_step(
        input logic signed[31:0] force_q24,input lip_cfg_t c
    );
        logic signed[31:0] a,b,d;
        a=force_q24>>>c.shift0;b=force_q24>>>c.shift1;d=force_q24>>>c.shift2;
        return (c.negative[0]?-a:a)+(c.negative[1]?-b:b)+(c.negative[2]?-d:d);
    endfunction

    for(genvar v=0;v<SLOTS;v++)begin:g_voice
        logic signed [31:0] force_q24,amp_unit,perturbed_force,air_unit;
        logic signed [32:0] increment;
        logic signed [33:0] mixed;
        logic signed [4:0] rate_draw;
        logic signed [3:0] amp_draw,air_draw;
        logic [3:0] onset_shift,air_shift;
        always_comb begin
            cfg[v]=lip_config(slot_period[v*16 +:16]);
            starts[v]=retrigger[v] || !note_q[v];
            increment=33'sd16777216+33'($signed(slot_pitch_delta[v*24 +:24]))+
                      33'($signed(rate[v]));
            phase_sum[v]={1'b0,phase[v]}+41'(increment);
            limit[v]={1'b0,slot_period[v*16 +:16],24'd0};
            hit[v]=starts[v] || phase_sum[v]>=limit[v];
            force_q24=$signed({1'b0,strike_level[v*8 +:8],16'd0});
            onset_shift=starts[v]?4'd0:fade_shift(onset_env[v]);
            air_shift=starts[v]?4'd0:fade_shift(air_env[v]);
            rate_draw=$signed({1'b0,rng[v][3:0]})-$signed({1'b0,rng[v][7:4]});
            amp_draw=$signed({1'b0,rng[v][10:8]})-$signed({1'b0,rng[v][13:11]});
            air_draw=$signed({1'b0,rng[v][16:14]})-$signed({1'b0,rng[v][19:17]});
            next_rate[v]=onset_shift==15 ? 24'sd0 :
                         ((24'(rate_draw)<<<14)>>>onset_shift);
            amp_unit=onset_shift==15 ? 32'sd0 :
                     (((force_q24>>>6)+(force_q24>>>7))>>>onset_shift);
            perturbed_force=force_q24+scale_small(amp_unit,amp_draw);
            next_step[v]=calibrated_step(perturbed_force,cfg[v]);
            air_unit=(force_q24>>>cfg[v].air_shift)+
                     (air_shift==15?32'sd0:((force_q24>>>(cfg[v].air_shift-4'd3))>>>air_shift));
            white[v]=scale_small(air_unit,air_draw);
            mixed=34'(wave[v])+34'(air_lp[v])-34'(air_dc[v]);
            if(!enable || clear || !note_on[v] || slot_clear[v] || !cfg[v].valid)
                xmap[v]=0;
            else if(mixed>34'sd2147483647)xmap[v]=32'sh7fffffff;
            else if(mixed< -34'sd2147483648)xmap[v]=32'sh80000000;
            else xmap[v]=32'(mixed);
        end
    end
    assign xmap_valid=clk_en && enable;

    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            note_q<='0;
            for(int v=0;v<SLOTS;v++)begin
                phase[v]<=0;rate[v]<=0;wave[v]<=0;step[v]<=0;stage[v]<=REST;
                remaining[v]<=0;half_q[v]<=0;close_q[v]<=0;gap_q[v]<=0;
                onset_env[v]<=0;air_env[v]<=0;air_lp[v]<=0;air_dc[v]<=0;rng[v]<=seed(v);
            end
        end else if(clear || !enable)begin
            // Immediate core-clock clear: no one-cycle instrument clear is lost
            // while waiting for the next sample tick.
            note_q<='0;
            for(int v=0;v<SLOTS;v++)begin
                phase[v]<=0;rate[v]<=0;wave[v]<=0;step[v]<=0;stage[v]<=REST;
                remaining[v]<=0;half_q[v]<=0;close_q[v]<=0;gap_q[v]<=0;
                onset_env[v]<=0;air_env[v]<=0;air_lp[v]<=0;air_dc[v]<=0;rng[v]<=seed(v);
            end
        end else if(clk_en)begin
            note_q<=note_on;
            for(int v=0;v<SLOTS;v++)begin
                if(slot_clear[v] || !note_on[v] || !cfg[v].valid)begin
                    phase[v]<=0;rate[v]<=0;wave[v]<=0;step[v]<=0;stage[v]<=REST;
                    remaining[v]<=0;half_q[v]<=0;close_q[v]<=0;gap_q[v]<=0;
                    onset_env[v]<=0;air_env[v]<=0;air_lp[v]<=0;air_dc[v]<=0;rng[v]<=seed(v);
                end else begin
                    rng[v]<={rng[v][21:0],rng[v][22]^rng[v][17]};
                    onset_env[v]<=starts[v]?16'hffff:decay_onset(onset_env[v]);
                    air_env[v]<=starts[v]?16'hffff:decay_air(air_env[v]);
                    if(starts[v])begin
                        air_lp[v]<=white[v]>>>1;air_dc[v]<=0;
                    end else begin
                        air_lp[v]<=32'(33'(air_lp[v])+((33'(white[v])-33'(air_lp[v]))>>>1));
                        air_dc[v]<=32'(33'(air_dc[v])+((33'(air_lp[v])-33'(air_dc[v]))>>>4));
                    end
                    if(hit[v])begin
                        phase[v]<=starts[v]?40'd0:40'(phase_sum[v]-limit[v]);
                        rate[v]<=next_rate[v];step[v]<=next_step[v];wave[v]<=next_step[v];
                        half_q[v]<=6'd1<<cfg[v].half_shift;
                        close_q[v]<=6'd1<<(cfg[v].half_shift-3'd2);
                        gap_q[v]<={1'b0,cfg[v].gap};
                        stage[v]<=OPEN_UP;remaining[v]<=(6'd1<<cfg[v].half_shift)-1'b1;
                    end else begin
                        phase[v]<=phase_sum[v][39:0];
                        case(stage[v])
                            OPEN_UP:begin
                                wave[v]<=wave[v]+step[v];remaining[v]<=remaining[v]-1'b1;
                                if(remaining[v]==1)begin stage[v]<=OPEN_DOWN;remaining[v]<=half_q[v];end
                            end
                            OPEN_DOWN:begin
                                wave[v]<=wave[v]-step[v];remaining[v]<=remaining[v]-1'b1;
                                if(remaining[v]==1)begin stage[v]<=GAP;remaining[v]<=gap_q[v];end
                            end
                            GAP:begin
                                wave[v]<=0;remaining[v]<=remaining[v]-1'b1;
                                if(remaining[v]==1)begin stage[v]<=CLOSE_DOWN;remaining[v]<=close_q[v];end
                            end
                            CLOSE_DOWN:begin
                                wave[v]<=wave[v]-(step[v]<<<4);remaining[v]<=remaining[v]-1'b1;
                                if(remaining[v]==1)begin stage[v]<=CLOSE_UP;remaining[v]<=close_q[v];end
                            end
                            CLOSE_UP:begin
                                wave[v]<=wave[v]+(step[v]<<<4);remaining[v]<=remaining[v]-1'b1;
                                if(remaining[v]==1)begin stage[v]<=REST;remaining[v]<=0;end
                            end
                            default:wave[v]<=0;
                        endcase
                    end
                end
            end
        end
    end
endmodule
