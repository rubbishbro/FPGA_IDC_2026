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

    input  byte_t           val,
    output sensor_param     sensor_p
);

led8x8 led_inst (.cr(cr), .x(led_p.x), .y(led_p.y), .pix(led_p.pix), 
            .wr(led_p.wr), .dat(dat));

logic [7:0] cnt;

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        cnt <= '0;
    end
    else if(cr.clk_en) begin
        cnt <= cnt + 1'b1;//auto rewind
    end
end

sense4x4 sen_inst (.cr({cr.clk, (cnt == 8'hff) & cr.clk_en, cr.rst_n}), .val(val),
                .row_s(sensor_p.row_s), .col_s(sensor_p.col_s), .fmap(sensor_p.fmap));

endmodule



/*
8 by 8 led screen driver

eff clk T = 400ns is required

x,y: position of target pixel
red,green,blue: RGB value of the specific pixel
wr: write gram (high) or refresh screen (low)
NOTE: refreshing screen take at least 1.9ms, and once
      you start it, it's no longer controled by wr.
      (refresh will start as you set wr low, and
      it will stop when it's done. it won't start  
      until you set wr high, and then low again.)
      so DO NOT write gram during refresh, otherwise
      unexpected behaviour may occur.

dat: screen din port
*/
module led8x8(
    input  clk_rst     cr,
    input  logic [2:0] x, y,
    input  pixel_t     pix,
    input  logic       wr,
    output logic       dat
);

//reset by us
gram_t             gram;
state_t            state;

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
    else if(wr && cr.clk_en) begin
        logic [2:0] y_;
        y_ = (x[0] == 0) ? y : ~y;

        gram.pixels[x][y_] <= pix;
    end
end

//refresh screen
always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n || wr) begin
        dat <= 1'b0;
        state <= S_PREPARE;
        trig <= '0;
        idx <= '0;
        cnt <= '0;
    end
    else if(cr.clk_en) begin
        case(state)
        S_PREPARE: state <= S_TX;
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
            state <= S_LATCH;
        end
        endcase
    end
end

endmodule



/*
4 by 4 force-sensitive sensor driver

eff clk T = 100us is recommended

val: ADC value

row_s: select row
col_s: select col, ADC channel selection
fmap: force disturibution of the pad
*/
module sense4x4 (
    input  clk_rst               cr,
    input  byte_t                val,
    output logic    [3:0]        row_s,
    output logic    [3:0]        col_s,
    output force_map_t           fmap
);

logic          s_rst_n;
logic  [3:0]   idx;

shift_timer #(.N(4)) col_scan (.cr({cr.clk, cr.clk_en, s_rst_n}), .val(col_s));
shift_timer #(.N(4)) row_scan (.cr({cr.clk, (col_s == 4'b0001) & cr.clk_en, s_rst_n}), .val(row_s));

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        fmap <= '0;
        idx <= '0;
    end
    else if(s_rst_n & cr.clk_en) begin
        fmap.flat_d[idx] <= val;
        idx <= idx + 1'b1;//never out of bound
    end
end

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        s_rst_n <= 1'b0;
    end
    else if(cr.clk_en) begin
        s_rst_n <= 1'b1;//enable scanner
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


