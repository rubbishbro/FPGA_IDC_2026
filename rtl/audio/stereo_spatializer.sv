`timescale 1ns/1ps
// Mono post-mix -> ILD -> auxiliary fractional ITD. All arithmetic is shift/add.
// One sample_valid per AUDIO FRAME, including silence. No independent sample timer.
// Output retains 18 extra fractional bits (12 gain + 6 delay); round only at PCM.
module stereo_spatializer #(
    parameter int DATA_BITS=64,
    parameter int ITD_MAX_SAMPLES=4 // supported: 0, 1, 2, 4, 8
)(
    input logic clk,rst_n,sample_valid,clear,
    input logic signed [DATA_BITS-1:0] in_data,
    input logic [5:0] pan_position, // 0=left, 16=center, 32=right; >32 clamps
    input logic itd_enable,
    output logic busy,out_valid,
    output logic signed [DATA_BITS+19:0] out_left,out_right,
    output logic [9:0] position_q4,
    output logic [12:0] gain_left_q12,gain_right_q12,
    output logic [9:0] delay_left_q6,delay_right_q6
);
    localparam int GW=DATA_BITS+13, OW=DATA_BITS+20;
    localparam int DS=(ITD_MAX_SAMPLES==8)?2:1;
    initial if (!(ITD_MAX_SAMPLES==0 || ITD_MAX_SAMPLES==1 ||
                   ITD_MAX_SAMPLES==2 || ITD_MAX_SAMPLES==4 || ITD_MAX_SAMPLES==8))
        $error("stereo_spatializer ITD_MAX_SAMPLES must be 0/1/2/4/8");

    // round(256*(1-p)/sqrt(2*(1+p*p))), p=(index-16)/16.
    // The right coefficient is the exact mirror of this table.
    function automatic logic [8:0] gain_lut(input logic [5:0] index);
        case(index)
             0,1:gain_lut=256; 2,3:gain_lut=255; 4:gain_lut=253;
             5:gain_lut=252; 6:gain_lut=249; 7:gain_lut=247; 8:gain_lut=243;
             9:gain_lut=238;10:gain_lut=233;11:gain_lut=227;12:gain_lut=220;
            13:gain_lut=211;14:gain_lut=202;15:gain_lut=192;16:gain_lut=181;
            17:gain_lut=169;18:gain_lut=157;19:gain_lut=145;20:gain_lut=132;
            21:gain_lut=119;22:gain_lut=106;23:gain_lut=93;24:gain_lut=81;
            25:gain_lut=69;26:gain_lut=58;27:gain_lut=47;28:gain_lut=36;
            29:gain_lut=26;30:gain_lut=17;31:gain_lut=8;
            default:gain_lut=0;
        endcase
    endfunction
    function automatic logic [9:0] delay_target(input logic [9:0] distance);
        case(ITD_MAX_SAMPLES)
            1:return distance>>2;
            2:return distance>>1;
            4:return distance;
            8:return distance<<1;
            default:return 0;
        endcase
    endfunction
    function automatic logic [9:0] slew_delay(input logic [9:0] value,target);
        if(target>value)return (target-value>10'(DS))?value+10'(DS):target;
        else return (value-target>10'(DS))?value-10'(DS):target;
    endfunction

    logic [9:0] target_pos,next_pos,target_dl,target_dr,mirror_pos;
    always_comb begin
        target_pos=(pan_position>32)?10'd512:{pan_position,4'b0};
        next_pos=position_q4;
        if(position_q4<target_pos)next_pos=position_q4+10'd1;
        else if(position_q4>target_pos)next_pos=position_q4-10'd1;
    end

    typedef enum logic [2:0] {IDLE,MAP,INTERP,GAIN,TAPS,BLEND,DELAY} state_t;
    state_t state;
    assign busy=state!=IDLE;
    logic clear_q,itd_q;
    logic [3:0] bit_count;
    logic [3:0] interp_frac_l,interp_frac_r;
    logic signed [13:0] interp_l,interp_r,delta_l,delta_r,interp_sum_l,interp_sum_r;
    assign interp_sum_l=interp_l+(interp_frac_l[0]?delta_l:14'sd0);
    assign interp_sum_r=interp_r+(interp_frac_r[0]?delta_r:14'sd0);
    logic [12:0] coeff_l,coeff_r;
    logic signed [GW-1:0] multiplicand,acc_l,acc_r,sum_l,sum_r;
    assign sum_l=acc_l+(coeff_l[0]?multiplicand:GW'(0));
    assign sum_r=acc_r+(coeff_r[0]?multiplicand:GW'(0));
    // Small fractional delay lines hold ILD outputs, so ITD is always after ILD.
    // Memories need no reset: valid_count masks unwritten and pre-clear history.
    logic signed [GW-1:0] hist_l[0:ITD_MAX_SAMPLES],hist_r[0:ITD_MAX_SAMPLES];
    logic [3:0] valid_count;
    logic signed [GW-1:0] tap_l,next_l,tap_r,next_r;
    logic signed [GW-1:0] held_l,held_next_l,held_r,held_next_r;
    always_comb begin
        tap_l='0;next_l='0;tap_r='0;next_r='0;
        if(delay_left_q6[9:6]<valid_count)tap_l=hist_l[delay_left_q6[9:6]];
        if(({1'b0,delay_left_q6[9:6]}+5'd1)<valid_count)
            next_l=hist_l[delay_left_q6[9:6]+1];
        if(delay_right_q6[9:6]<valid_count)tap_r=hist_r[delay_right_q6[9:6]];
        if(({1'b0,delay_right_q6[9:6]}+5'd1)<valid_count)
            next_r=hist_r[delay_right_q6[9:6]+1];
    end
    logic [5:0] frac_l,frac_r;
    logic signed [OW-1:0] delay_acc_l,delay_acc_r,diff_l,diff_r,delay_sum_l,delay_sum_r;
    assign delay_sum_l=delay_acc_l+(frac_l[0]?diff_l:OW'(0));
    assign delay_sum_r=delay_acc_r+(frac_r[0]?diff_r:OW'(0));

    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;out_valid<=0;out_left<=0;out_right<=0;
            position_q4<=256;gain_left_q12<=13'd2896;gain_right_q12<=13'd2896;
            delay_left_q6<=0;delay_right_q6<=0;valid_count<=0;clear_q<=0;
            itd_q<=0;mirror_pos<=256;target_dl<=0;target_dr<=0;
            interp_l<=0;interp_r<=0;delta_l<=0;delta_r<=0;interp_frac_l<=0;interp_frac_r<=0;
            bit_count<=0;coeff_l<=0;coeff_r<=0;multiplicand<=0;acc_l<=0;acc_r<=0;
            frac_l<=0;frac_r<=0;delay_acc_l<=0;delay_acc_r<=0;diff_l<=0;diff_r<=0;
            held_l<=0;held_next_l<=0;held_r<=0;held_next_r<=0;
        end else begin
            out_valid<=0;
            case(state)
                IDLE:if(sample_valid)begin
                    position_q4<=next_pos;mirror_pos<=10'd512-next_pos;itd_q<=itd_enable;
                    multiplicand<=clear?GW'(0):GW'($signed(in_data));
                    acc_l<=0;acc_r<=0;clear_q<=clear;bit_count<=0;state<=MAP;
                end
                MAP:begin
                    // Separate position slew, LUT read and serial interpolation.
                    // Avoid a position compare + four cascaded adders in one cycle.
                    interp_l<=$signed({1'b0,gain_lut(position_q4[9:4]),4'b0});
                    interp_r<=$signed({1'b0,gain_lut(mirror_pos[9:4]),4'b0});
                    delta_l<=$signed({1'b0,gain_lut(position_q4[9:4]+6'd1)})-
                              $signed({1'b0,gain_lut(position_q4[9:4])});
                    delta_r<=$signed({1'b0,gain_lut(mirror_pos[9:4]+6'd1)})-
                              $signed({1'b0,gain_lut(mirror_pos[9:4])});
                    interp_frac_l<=position_q4[3:0];interp_frac_r<=mirror_pos[3:0];
                    target_dl<=(itd_q && position_q4>256)?delay_target(position_q4-10'd256):10'd0;
                    target_dr<=(itd_q && position_q4<256)?delay_target(10'd256-position_q4):10'd0;
                    state<=INTERP;
                end
                INTERP:begin
                    if(bit_count==0)begin
                        delay_left_q6<=slew_delay(delay_left_q6,target_dl);
                        delay_right_q6<=slew_delay(delay_right_q6,target_dr);
                    end
                    interp_l<=interp_sum_l;interp_r<=interp_sum_r;
                    delta_l<=delta_l<<<1;delta_r<=delta_r<<<1;
                    interp_frac_l<=interp_frac_l>>1;interp_frac_r<=interp_frac_r>>1;
                    if(bit_count==3)begin
                        coeff_l<=interp_sum_l[12:0];coeff_r<=interp_sum_r[12:0];
                        gain_left_q12<=interp_sum_l[12:0];gain_right_q12<=interp_sum_r[12:0];
                        bit_count<=0;state<=GAIN;
                    end else bit_count<=bit_count+1'b1;
                end
                GAIN:begin
                    acc_l<=sum_l;acc_r<=sum_r;
                    multiplicand<=multiplicand<<<1;coeff_l<=coeff_l>>1;coeff_r<=coeff_r>>1;
                    if(bit_count==12)begin
                        for(integer i=ITD_MAX_SAMPLES;i>0;i=i-1)begin
                            hist_l[i]<=hist_l[i-1];hist_r[i]<=hist_r[i-1];
                        end
                        hist_l[0]<=sum_l;hist_r[0]<=sum_r;
                        if(clear_q)valid_count<=1;
                        else if(valid_count<ITD_MAX_SAMPLES+1)valid_count<=valid_count+1'b1;
                        state<=TAPS;
                    end else bit_count<=bit_count+1'b1;
                end
                TAPS:begin
                    held_l<=tap_l;held_next_l<=next_l;held_r<=tap_r;held_next_r<=next_r;
                    frac_l<=delay_left_q6[5:0];frac_r<=delay_right_q6[5:0];
                    state<=BLEND;
                end
                BLEND:begin
                    delay_acc_l<=OW'($signed(held_l))<<<6;
                    delay_acc_r<=OW'($signed(held_r))<<<6;
                    diff_l<=OW'($signed(held_next_l))-OW'($signed(held_l));
                    diff_r<=OW'($signed(held_next_r))-OW'($signed(held_r));
                    bit_count<=0;state<=DELAY;
                end
                DELAY:begin
                    delay_acc_l<=delay_sum_l;delay_acc_r<=delay_sum_r;
                    diff_l<=diff_l<<<1;diff_r<=diff_r<<<1;
                    frac_l<=frac_l>>1;frac_r<=frac_r>>1;
                    if(bit_count==5)begin
                        out_left<=delay_sum_l;out_right<=delay_sum_r;
                        out_valid<=1;state<=IDLE;
                    end else bit_count<=bit_count+1'b1;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
