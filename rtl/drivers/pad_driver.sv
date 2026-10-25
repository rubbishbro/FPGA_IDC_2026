import clk_rst_pkg::*;
import pad_driver_pkg::*;

/*
本文件的顶层模块

要求有效时钟周期 T = 400ns

*/

// 键盘驱动
module pad_driver(
    input  clk_rst          cr,
    input  led_param        led_p,
    output logic            dat,
    output input_param      input_p
);

// led矩阵
led8x8 led_inst (.cr(cr), .x(led_p.x), .y(led_p.y), .pix(led_p.pix), 
            .wr(led_p.wr), .dat(dat));

// 压力垫和摇杆的模拟采集器
sense4x4_joystick input_inst (.cr({cr.clk, cr.clk_en, cr.rst_n}),
                .row_s(input_p.row_s), .ch_s(input_p.ch_s), .fmap(input_p.fmap), .pos(input_p.pos));

endmodule



/*
8×8 LED 点阵屏驱动

要求有效时钟周期 T = 400ns 2.5khz扫描

x、y：目标像素坐标
red、green、blue：该像素的 RGB 分量
wr：高电平写显存，低电平刷新一次屏幕
注意：一次刷新至少需要 1.9ms，传输期间
      不能写显存。

dat：屏幕串行数据输入
*/
module led8x8(
    input  clk_rst     cr,
    input  logic [2:0] x, y,
    input  pixel_t     pix,
    input  logic       wr,
    output logic       dat
);

// 联合定义8*8的数组, 用1536位的逻辑向量表示(共享内存)
typedef union packed{pixel_t [7:0][7:0] pixels; logic [1535:0] raw;} gram_t;
typedef enum logic [1:0] {S_PREPARE, S_TX, S_RESET, S_LATCH} led_state_t;

//由本模块自行复位
gram_t             gram;  // 显存
led_state_t        state; // 状态机状态

logic   [10:0]     idx;   // 索引，范围 0~1535
logic   [2:0]      trig;  // 触发信号，0表示未触发，1表示高电平触发，2表示低电平触发
logic   [7:0]      cnt;   // 计数器，范围 0~255

//由定时器复位
logic   [2:0]      t0_v;
shift_timer #(.N(3)) timer0 (.cr({cr.clk, cr.clk_en, state == S_TX}), .val(t0_v));

//写显存
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

//刷新屏幕
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
            if(idx >= 1536) begin //此处捕获 idx 溢出
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
            if(cnt >= 143) begin //此处捕获 cnt 溢出
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
4×4 力敏传感器与摇杆驱动

建议有效时钟周期 T = 400ns

val：ADC 采样值

row_s：行选择
ch_s：列选择，同时用于 ADC 通道选择
fmap：压力垫的压力分布
pos：极坐标表示的摇杆位置
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

//由 ADC IP 复位
logic           adc_rdy;
logic           adc_req;
logic  [13:0]   adc_val;
//row_s 由定时器复位
shift_timer #(.N(4)) row_scan (.cr({cr.clk, (chn_s == 2'b11) & cr.clk_en, cr.rst_n}), .val(row_s));

Gowin_ADC adc_inst(
        .adcrdy(adc_rdy),
        .adcvalue(adc_val),
        .drstn(cr.rst_n),
        .adcreqi(adc_req),
        .fscal_value(10'b10_1000_1101), //满量程标定值 fscal = 653
        .offset_value('0) //偏移量 offset = 0
    );

//pos 由 c2p 复位
cart2polar #(.IN_L(14), .OUT_L(8)) c2p_inst (.cr({cr.clk, cr.clk_en, cr.rst_n}), .start(conv_start),
                                            .x(x), .y(y), .r(pos.x), .w(pos.y));

assign ch_s = {(state == S_READ_JOYSTICK), chn_s[1:0]};

logic [7:0] cnt;//内部时钟分频，有效时钟周期 T = 100us

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        cnt <= '0;
    end
    else if(cr.clk_en) begin
        cnt <= cnt + 1'b1;//自动回绕
    end
end

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
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
            idx <= idx + 1'b1; //不会越界
            chn_s <= chn_s + 1'b1; //不会越界
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
循环右移计数器

参数 N：val 的位宽，建议取 2~8

clk：控制计数器速度的时钟
rst_n：下降沿复位

exti：外部触发，接 1'b1 表示忽略
val：初值为 {1'b1, {(N-1){1'b0}} }
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


