//led
typedef struct packed{
    logic [7:0] g;
    logic [7:0] r;
    logic [7:0] b;
} pixel_t;

typedef union packed{
    pixel_t [7:0][7:0] pixels;
    logic [1535:0] raw;
}gram_t;

typedef enum logic [1:0] {
    S_PREPARE,
    S_TX,
    S_RESET,
    S_LATCH
} state_t;

//pad
typedef struct packed{
    logic [7:0] val;
} byte_t;

typedef union packed{
    byte_t   [3:0][3:0]   strc_d;
    byte_t   [15:0]       flat_d;
} force_map_t;

//top
typedef struct packed{
    logic    [2:0]   x, y;
    pixel_t          pix;
    logic            wr;
} led_param;

typedef struct packed{
    logic    [3:0]   row_s, col_s;
    force_map_t      fmap;
} sensor_param;



/*
top module of this file

clk: T = 400ns is required
rst_n: reset on negedge

*/
module pad_driver(
    input  logic            clk,
    input  logic            rst_n,

    input  led_param        led_p,
    output logic            dat,

    input  byte_t           val,
    output sensor_param     sensor_p
);

led8x8 led_inst (.clk(clk), .rst_n(rst_n),
            .x(led_p.x), .y(led_p.y), .pix(led_p.pix), 
            .wr(led_p.wr), .dat(dat));

logic [7:0] cnt;
logic div_clk;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        div_clk <= 1'b0;
        cnt <= '0;
    end
    else begin
        if(cnt == 8'hff) div_clk <= 1'b1;
        else div_clk <= 1'b0;

        cnt <= cnt + 1'b1;//auto rewind
    end
end

sense4x4 pad_inst (.clk(div_clk), .rst_n(rst_n), .val(val),
                .row_s(sensor_p.row_s), .col_s(sensor_p.col_s), .fmap(sensor_p.fmap));

endmodule



/*
8 by 8 led screen driver

clk: clock that drives data transmitting. T = 400ns is required
rst_n: reset on negedge

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
    input  logic       clk,
    input  logic       rst_n,
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
shift_timer #(.N(3)) timer0 (.clk(clk), .rst_n(state == S_TX), .exti(1'b1), .val(t0_v));

//write gram
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        gram.raw <= '0;
    end
    else if(wr) begin
        logic [2:0] y_;
        y_ = (x[0] == 0) ? y : ~y;

        gram.pixels[x][y_] <= pix;
    end
end

//refresh screen
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n || wr) begin
        dat <= 1'b0;
        state <= S_PREPARE;
        trig <= '0;
        idx <= '0;
        cnt <= '0;
    end
    else begin
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

clk: clock that controls scan speed, T = 100us is recommended
rst_n: reset on negedge
val: ADC value

row_s: select row
col_s: select col, ADC channel selection
fmap: force disturibution of the pad
*/
module sense4x4 (
    input  logic                 clk,
    input  logic                 rst_n,
    input  byte_t                val,
    output logic    [3:0]        row_s,
    output logic    [3:0]        col_s,
    output force_map_t           fmap
);

logic          s_rst_n;
logic  [3:0]   idx;

shift_timer #(.N(4)) col_scan (.clk(clk), .rst_n(s_rst_n), .exti(1'b1), .val(col_s));
shift_timer #(.N(4)) row_scan (.clk(clk), .rst_n(s_rst_n), .exti(col_s == 4'b0001), .val(row_s));

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        fmap <= '0;
        idx <= '0;
    end
    else if(s_rst_n) begin
        fmap.flat_d[idx] <= val;
        idx <= idx + 1'b1;//never out of bound
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        s_rst_n <= 1'b0;
    end
    else begin
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
    input  logic            clk,
    input  logic            rst_n,
    input  logic            exti,
    output logic  [N-1:0]   val
);

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) val <= {1'b1, {(N-1){1'b0}} };
    else if(exti) val <= {val[0], val[N-1:1]};
end

endmodule


