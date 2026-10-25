import clk_rst_pkg::*;
import pad_driver_pkg::*;

/*
top module of this file

eff clk T = 400ns is required

*/
module pad_driver(
    input  clk_rst          cr,
    input  led_param        led_p,
    output logic            dat,
    output input_param      input_p
);

led8x8 led_inst (.cr(cr), .x(led_p.x), .y(led_p.y), .pix(led_p.pix),
            .wr(led_p.wr), .dat(dat));

sense4x4_joystick input_inst (.cr({cr.clk, cr.clk_en, cr.rst_n}),
                .row_s(input_p.row_s), .ch_s(input_p.ch_s), .fmap(input_p.fmap), .pos(input_p.pos));

endmodule



/*
8 by 8 led screen driver

eff clk T = 400ns is required

x,y: position of target pixel
red,green,blue: RGB value of the specific pixel
wr: write gram (high) or refresh screen once (low)
NOTE: refreshing screen take at least 1.9ms. during
      transmission, you can't write gram.

dat: screen din port
*/
module led8x8(
    input  clk_rst     cr,
    input  logic [2:0] x, y,
    input  pixel_t     pix,
    input  logic       wr,
    output logic       dat
);

typedef union packed{pixel_t [7:0][7:0] pixels; logic [1535:0] raw;} gram_t;
typedef enum logic [1:0] {S_PREPARE, S_TX, S_RESET, S_LATCH} led_state_t;
//reset by us
gram_t             gram;
led_state_t        state;

logic   [10:0]     idx;
logic   [2:0]      trig;
logic   [7:0]      cnt;

//reset by timer
logic   [2:0]      t0_v;
shift_timer #(.N(3)) timer0 (.cr({cr.clk, cr.clk_en, state == S_TX}), .val(t0_v));

//write gram
always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        gram.raw <= '0;
    end
    else if(wr && (state != S_TX) && cr.clk_en) begin
        logic [2:0] y_;
        y_ = (x[0] == 0) ? y : ~y;

        gram.pixels[x][y_] <= pix;
    end
end

//refresh screen
always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        dat <= 1'b0;
        state <= S_PREPARE;
        trig <= '0;
        idx <= '0;
        cnt <= '0;
    end
    else if(cr.clk_en) begin
        case(state)
        S_PREPARE:
            if(!wr) begin
                state <= S_TX;
            end
        S_TX: begin
            if(idx >= 1536) begin //idx overflow captured here
                state <= S_RESET;
                idx <= '0;
            end
            else if(t0_v == 3'b100) begin
                dat <= 1'b1;
                trig <= gram.raw[idx] ? 3'b001 : 3'b010;
            end
            else if(t0_v == trig) begin
                dat <= 1'b0;
                idx <= idx + 1'b1;
            end
        end
        S_RESET: begin
            if(cnt >= 143) begin //cnt overflow captured here
                state <= S_LATCH;
                cnt <= '0;
            end
            cnt <= cnt + 1'b1;
        end
        S_LATCH: begin
            if(wr) begin
                state <= S_PREPARE;
            end
        end
        endcase
    end
end

endmodule



/*
4 by 4 force-sensitive sensor and joystick driver

eff clk T = 400ns is recommended

val: ADC value

row_s: select row
ch_s: select col, ADC channel selection
fmap: force disturibution of the pad
pos: position in polar coordinates
*/
module sense4x4_joystick (
    input  clk_rst               cr,
    output logic    [3:0]        row_s,
    output logic    [2:0]        ch_s,
    output mat4x4                fmap,
    output vec2                  pos
);

typedef enum logic {S_READ_SENSEPAD, S_READ_JOYSTICK} sen_state_t;

logic  [3:0]    idx;
logic  [1:0]    chn_s;
sen_state_t     state;
logic  [13:0]   x,y;
logic           conv_start;

//reset by adc ip
logic           adc_rdy;
logic           adc_req;
logic  [13:0]   adc_val;
Gowin_ADC adc_inst(
        .adcrdy(adc_rdy),
        .adcvalue(adc_val),
        .drstn(cr.rst_n),
        .adcreqi(adc_req),
        .fscal_value(10'b10_1000_1101), //fscal = 653
        .offset_value('0) //offset = 0
    );

//pos reset by c2p
cart2polar #(.IN_L(14), .OUT_L(8)) c2p_inst (.cr({cr.clk, cr.clk_en, cr.rst_n}), .start(conv_start),
                                            .x(x), .y(y), .r(pos.x), .w(pos.y));

assign ch_s = {(state == S_READ_JOYSTICK), chn_s[1:0]};

logic [7:0] cnt;//internal clock divsion, eff clk T = 100us

localparam int SETTLE_TICKS = 25;
logic [7:0] settle_cnt;
logic [2:0] ch_s_q;
wire ch_changed = (ch_s != ch_s_q);
wire settle_done = (settle_cnt >= SETTLE_TICKS);

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        ch_s_q     <= 3'd0;
        settle_cnt <= 8'd0;
    end
    else if(cr.clk_en) begin
        ch_s_q <= ch_s;
        if(ch_changed)
            settle_cnt <= 8'd0;
        else if(settle_cnt < SETTLE_TICKS)
            settle_cnt <= settle_cnt + 8'd1;
    end
end

wire adc_step = cr.clk_en & (cnt == '1) & adc_rdy;

logic row_step;
always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n)
        row_step <= 1'b0;
    else
        row_step <= (chn_s == 2'b11) & adc_step;
end

//row_s reset by timer
shift_timer #(.N(4)) row_scan (.cr({cr.clk, row_step, cr.rst_n}), .val(row_s));

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        cnt <= '0;
    end
    else if(cr.clk_en) begin
        cnt <= cnt + 1'b1;//auto rewind
    end
end

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        adc_req <= 1'b0;
    end
    else if(!settle_done) begin
        adc_req <= 1'b0;
    end
    else if(cr.clk_en & (cnt == '1) & adc_rdy) begin
        adc_req <= 1'b0;
    end
    else adc_req <= 1'b1;
end

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        idx <= '0;
        chn_s <= '0;
        state <= S_READ_SENSEPAD;
        {x,y} <= '0;
        fmap <= '0;
        conv_start <= 1'b0;
    end
    else if(cr.clk_en & (cnt == '1) & adc_rdy) begin
        case(state)
        S_READ_SENSEPAD: begin
            conv_start <= 1'b0;
            fmap.flat_d[idx] <= adc_val[13:6];
            idx <= idx + 1'b1; //never out of bound
            chn_s <= chn_s + 1'b1; //never out of bound
            if(idx == '1) begin
                state <= S_READ_JOYSTICK;
            end
        end
        S_READ_JOYSTICK: begin
            if(chn_s[0] == 1'b0) x <= adc_val;
            else y <= adc_val;

            chn_s <= chn_s + 1'b1;
            if(chn_s[0] == 1'b1) begin
                chn_s <= '0;
                conv_start <= 1'b1;
                state <= S_READ_SENSEPAD;
            end
        end
        endcase
    end
end

endmodule



/*
looped right shift counter

parameter N: length of val, 2~8 is recommended

clk: clock that controls counter speed
rst_n: reset on negedge

exti: external trigger, use 1'b1 to ignore
val: initialized with {1'b1, {(N-1){1'b0}} }
*/
module shift_timer #(
    parameter int N = 4
)(
    input clk_rst           cr,
    output logic  [N-1:0]   val
);

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) val <= {1'b1, {(N-1){1'b0}} };
    else if(cr.clk_en) val <= {val[0], val[N-1:1]};
end

endmodule
