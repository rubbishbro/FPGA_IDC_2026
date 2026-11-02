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
    output input_param      input_p,
    // 原始 ADC 坐标；每对 X/Y 到齐后 valid 在 cr.clk 域高一拍。
    output logic            joy_sample_valid,
    output logic [13:0]     joy_raw_x,
    output logic [13:0]     joy_raw_y,
    output logic            led_busy,
    output logic            led_frame_done
);

// led矩阵
led8x8 led_inst (.cr(cr), .x(led_p.x), .y(led_p.y), .pix(led_p.pix),
            .wr(led_p.wr), .dat(dat), .busy(led_busy), .frame_done(led_frame_done));

// 压力垫和摇杆的模拟采集器
sense4x4_joystick input_inst (.cr({cr.clk, cr.clk_en, cr.rst_n}),
                .row_s(input_p.row_s), .ch_s(input_p.ch_s), .fmap(input_p.fmap), .pos(input_p.pos),
                .joy_sample_valid(joy_sample_valid), .joy_raw_x(joy_raw_x), .joy_raw_y(joy_raw_y));

endmodule



/*
8×8 LED 点阵屏驱动

要求有效时钟周期 T = 400ns，2.5MHz扫描使能

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
    output logic       dat,
    output logic       busy,
    output logic       frame_done
);

typedef enum logic [1:0] {S_PREPARE, S_TX, S_RESET, S_LATCH} led_state_t;

// Pixel-addressed SDP memory; bit zero in each word is transmitted first.
(* syn_ramstyle="block_ram" *) logic [23:0] pixel_ram [0:63];
logic [23:0] pixel_q;
logic [5:0] tx_pixel;
logic [4:0] tx_bit;
led_state_t        state; // 状态机状态
assign busy = state == S_TX || state == S_RESET;
logic   [10:0]     idx;   // 索引，范围 0~1535
logic   [2:0]      trig;  // 触发信号，0表示未触发，1表示高电平触发，2表示低电平触发
logic   [7:0]      cnt;   // 计数器，范围 0~255
// One core-clock pulse after the serial image's reset/latch interval.
always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) frame_done <= 1'b0;
    else frame_done <= cr.clk_en && state == S_RESET && cnt == 143;
end

//由定时器复位
logic   [2:0]      t0_v;
shift_timer #(.N(3)) timer0 (.cr({cr.clk, cr.clk_en, state == S_TX}), .val(t0_v));

//写显存
// idx walks upward from bit 0. Store each pixel in wire order so that the
// receiver sees G7..G0, R7..R0, B7..B0 (WS2812 MSB first), not reversed bytes.
wire [23:0] pixel_grb = pix;
wire [23:0] serial_pixel;
for(genvar bit_index=0;bit_index<24;bit_index++) begin:g_wire_order
    assign serial_pixel[bit_index]=pixel_grb[23-bit_index];
end
// Board contract: pad_led_effects holds wr high in R_BOOT_FILL and writes all
// 64 black pixels before releasing wr. S_PREPARE cannot transmit before then.
// gram needs no reset; any other producer must provide the same full-frame
// initialization after reset. Protocol state, index and dat still reset below.
always_ff @(posedge cr.clk) begin
    if(wr && (state != S_TX) && cr.clk_en) begin
        logic [2:0] y_;
        y_ = (x[0] == 0) ? y : ~y;

        pixel_ram[{x,y_}] <= serial_pixel;
    end
end

// Synchronous pixel read. The address changes at a bit boundary and pixel_q
// follows one core clock later; a boundary after a '1' bit leaves only one
// enable before the next sampled bit. Contract: clk_en must be asserted at most
// once every two core clocks (board pad_tick is one enable per 20 clocks).
// Consecutive per-clock enables are not supported by this read path.
logic led_bit;
always_ff @(posedge cr.clk) pixel_q <= pixel_ram[tx_pixel];
assign led_bit = pixel_q[tx_bit];

//刷新屏幕
always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        dat <= 1'b0;
        state <= S_PREPARE;
        trig <= '0;
        idx <= '0;
        tx_pixel <= '0;
        tx_bit <= '0;
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
                tx_pixel <= '0;
                tx_bit <= '0;
            end
            else if(t0_v == 3'b100) begin
                dat <= 1'b1;
                trig <= led_bit ? 3'b001 : 3'b010;
            end
            else if(t0_v == trig) begin
                dat <= 1'b0;
                idx <= idx + 1'b1;
                if(tx_bit==23) begin tx_bit<=0;tx_pixel<=tx_pixel+1'b1;end
                else tx_bit<=tx_bit+1'b1;
            end
        end
        S_RESET: begin
            if(cnt >= 143) begin //此处捕获 cnt 溢出
                state <= S_LATCH;
                cnt <= '0;
            end else cnt <= cnt + 1'b1;
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

row_s：行选择（one-hot，同一时刻最多一行有效）
ch_s：列/通道选择。ch_s[2]=0 选压力垫第 {1'b0,ch_s[1:0]} 列；
      ch_s[2]=1 选摇杆 X(ch_s[1:0]=0)/Y(=1)
fmap：压力垫的压力分布，fmap.strc_d[row][col] 对应 (row_s 第 row 位, 列 col)
pos：极坐标表示的摇杆位置

可调参数（单位都是 400ns 有效拍）：
  DISCHARGE_CYCLES：换通道后先把所有行拉低，给列线/模拟开关的采样电容放电
  SETTLE_CYCLES   ：目标行拉高后等 RC 建立，再启动 ADC
  REQ_CYCLES      ：ADCREQI 高电平宽度，至少要覆盖 1 个 ADC OSC(2.5MHz) 周期
  RDY_TIMEOUT     ：等 ADCRDY 的超时；超时会重新走泄放/建立/请求，不读旧值
  DUMMY_READ      ：换通道后的第一次转换是否丢弃。ADC 内部积分器/外部电容
                    残留较大时置 1，代价是每格多一次转换时间

注意：转换时间由 Gowin ADC IP 的 Sample Count / Sample Rate 决定（手册
Nreq2rdy = 128~2048 个 ADC 时钟，OSC=2.5MHz 时约 51us~819us）。若整帧
太慢，先在 IP 配置里把 Sample Count 从 1024 降到 128、Sample Rate 从 128
降到 16，而不是靠缩短这里的建立时间。
*/
module sense4x4_joystick #(
    // 下列计数均以“有效时钟”为单位，即 cr.clk_en 有效的 400ns 拍。
    parameter int unsigned DISCHARGE_CYCLES = 32,   // 12.8us 全行拉低，泄放列线/模拟开关采样电容
    parameter int unsigned SETTLE_CYCLES    = 64,   // 25.6us 目标行拉高后等 RC 建立
    parameter int unsigned REQ_CYCLES       = 2,    // 800ns  ADCREQI 高电平宽度(ADC OSC 2.5MHz)
    parameter int unsigned RDY_TIMEOUT      = 4096, // 1.6ms  等 ADCRDY 的超时，约 2 倍手册最大值
    parameter bit          DUMMY_READ       = 1'b0  // 1=换通道后第一次转换丢弃，再转一次才存
) (
    input  clk_rst               cr,
    output logic    [3:0]        row_s,
    output logic    [2:0]        ch_s,
    output mat4x4                fmap,
    output vec2                  pos,
    output logic                 joy_sample_valid,
    output logic [13:0]          joy_raw_x,
    output logic [13:0]          joy_raw_y
);

/*
每个有效时钟 400ns，一帧 = 16 个压力单元 + 2 个摇杆通道。
扫描顺序由 slot 决定：0~15 为 (row,col) = (slot/4, slot%4)，16/17 为摇杆 X/Y。

  S_DISCHARGE : row_s = 0000，ch_s 先选中目标通道，等 DISCHARGE_CYCLES
  S_SETTLE    : 只拉高目标行，等 SETTLE_CYCLES
  S_REQUEST   : ADCREQI 拉高 REQ_CYCLES 拍（上升沿触发一次转换）
  S_WAIT_RDY  : 必须等到 ADCRDY 的完成上升沿，超时则重来
  S_STORE     : 锁存 ADCVALUE，换下一格

关键点：ADCREQI 是上升沿触发、ADCRDY 是电平/完成标志。旧代码每 256 拍
就盲读一次 adc_val 并立刻改行列，ADCRDY 可能还停在上一次转换上，读到的
是上一通道（甚至复位初值）的结果，看起来就是矩阵全亮。这里改成“换通道
-> 泄放 -> 建立 -> 请求 -> 等完成 -> 才读取”，转换期间 row_s/ch_s 不动。
*/
typedef enum logic [2:0] {
    S_DISCHARGE,
    S_SETTLE,
    S_REQUEST,
    S_WAIT_RDY,
    S_STORE
} scan_state_t;

localparam logic [4:0] SLOT_JOY_X = 5'd16;
localparam logic [4:0] SLOT_JOY_Y = 5'd17;

scan_state_t    state;
logic  [4:0]    slot;
logic  [15:0]   cnt;
logic           dummy_q;
logic           adc_clr;
logic           conv_start;
logic  [13:0]   x,y;

logic  [1:0]    row_idx, col_idx;
logic  [3:0]    pad_idx;
logic           is_joy;
logic  [2:0]    ch_next;
logic  [3:0]    row_next;

//由 ADC IP 复位/产生
logic           adc_rdy;
logic           adc_req;
logic  [13:0]   adc_val;

assign row_idx  = slot[3:2];
assign col_idx  = slot[1:0];
assign pad_idx  = {row_idx, col_idx};
assign is_joy   = (slot >= SLOT_JOY_X);
assign ch_next  = is_joy ? {1'b1, 1'b0, slot[0]} : {1'b0, col_idx};
assign row_next = is_joy ? 4'b0000 : (4'b0001 << row_idx);

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

// ---------------------------------------------------------------------------
// ADCRDY/ADCVALUE 在 ADC 内部(OSC 2.5MHz)时钟域产生，这里用主时钟同步。
// 只把完成“上升沿”变成一个 sticky 标志，再交给 400ns 的扫描 FSM 消费：
// 这样无论 ready 是窄脉冲还是电平，都不会被慢速 FSM 漏掉，也不会重复消费。
// ---------------------------------------------------------------------------
(* ASYNC_REG="TRUE" *) logic adc_rdy_meta, adc_rdy_sync;
logic adc_rdy_d;
logic           adc_done;
logic  [13:0]   adc_val_lat;

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        adc_rdy_meta <= 1'b0;
        adc_rdy_sync <= 1'b0;
        adc_rdy_d    <= 1'b0;
        adc_done     <= 1'b0;
        adc_val_lat  <= '0;
    end
    else begin
        adc_rdy_meta <= adc_rdy;
        adc_rdy_sync <= adc_rdy_meta;
        adc_rdy_d    <= adc_rdy_sync;

        if(adc_rdy_sync & ~adc_rdy_d) begin
            adc_val_lat <= adc_val;   // 完成沿锁存，数据保持到下一次转换
            adc_done    <= 1'b1;
        end
        else if(adc_clr) begin
            adc_done    <= 1'b0;      // FSM 取走结果后再清
        end
    end
end

// ---------------------------------------------------------------------------
// fmap 按字节更新。这里用移位/掩码而不是 fmap.flat_d[pad_idx]，
// 因为部分仿真器不支持对 packed union/struct 成员做变量下标。
// ---------------------------------------------------------------------------
logic [127:0]   fmap_byte, fmap_mask, fmap_shift;
assign fmap_shift = {pad_idx, 3'b000};
assign fmap_byte  = {{120{1'b0}}, adc_val_lat[13:6]};
assign fmap_mask  = 128'hFF << fmap_shift;

// 原始坐标原子快照，独立于旧极坐标转换。valid 只持续一个主时钟，
// 不随 cr.clk_en 拉长；丢弃的 dummy 转换和超时重试不发布样本。
always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if (!cr.rst_n) begin
        joy_sample_valid <= 1'b0;
        joy_raw_x <= '0;
        joy_raw_y <= '0;
    end else begin
        joy_sample_valid <= 1'b0;
        if (cr.clk_en && state == S_STORE && slot == SLOT_JOY_Y &&
            (!DUMMY_READ || dummy_q)) begin
            joy_raw_x <= x;
            joy_raw_y <= adc_val_lat;
            joy_sample_valid <= 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// 扫描 FSM
// ---------------------------------------------------------------------------
always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        state      <= S_DISCHARGE;
        slot       <= '0;
        cnt        <= '0;
        dummy_q    <= 1'b0;
        adc_req    <= 1'b0;
        adc_clr    <= 1'b0;
        conv_start <= 1'b0;
        row_s      <= '0;
        ch_s       <= '0;
        {x,y}      <= '0;
        fmap       <= '0;
    end
    else if(cr.clk_en) begin
        adc_clr    <= 1'b0;
        conv_start <= 1'b0;

        case(state)
        S_DISCHARGE: begin
            adc_req <= 1'b0;
            row_s   <= 4'b0000;          // 所有行拉低：给选中列一条泄放通路
            ch_s    <= ch_next;          // 提前选通道，让电容先充/放电
            if(cnt + 1 >= DISCHARGE_CYCLES) begin
                cnt   <= '0;
                state <= S_SETTLE;
            end
            else cnt <= cnt + 1'b1;
        end
        S_SETTLE: begin
            row_s <= row_next;           // 只有目标行拉高
            if(cnt + 1 >= SETTLE_CYCLES) begin
                cnt   <= '0;
                state <= S_REQUEST;
            end
            else cnt <= cnt + 1'b1;
        end
        S_REQUEST: begin
            // 发请求前先清掉上一次(或复位残留)的完成标志，避免 S_WAIT 把旧值
            // 当成这次转换的结果。
            if(cnt == '0) adc_clr <= 1'b1;
            if(cnt >= REQ_CYCLES) begin
                adc_req <= 1'b0;
                cnt     <= '0;
                state   <= S_WAIT_RDY;
            end
            else begin
                adc_req <= 1'b1;         // 0 -> 1 的上升沿启动一次转换
                cnt     <= cnt + 1'b1;
            end
        end
        S_WAIT_RDY: begin
            if(adc_done) begin
                cnt   <= '0;
                state <= S_STORE;
            end
            else if(cnt + 1 >= RDY_TIMEOUT) begin
                // 没有完成就重来，绝不拿旧 adc_val_lat 当本次结果
                cnt   <= '0;
                state <= S_DISCHARGE;
            end
            else cnt <= cnt + 1'b1;
        end
        S_STORE: begin
            cnt     <= '0;
            if(DUMMY_READ && !dummy_q) begin
                // 换通道后的第一次转换可能带着上一个通道的电荷，丢弃
                dummy_q <= 1'b1;
                state   <= S_REQUEST;    // row_s/ch_s 保持不变，再转一次
            end
            else begin
                dummy_q <= 1'b0;
                if(is_joy) begin
                    if(slot == SLOT_JOY_X) x <= adc_val_lat;
                    else                   y <= adc_val_lat;
                end
                else begin
                    fmap.raw <= (fmap.raw & ~fmap_mask) | (fmap_byte << fmap_shift);
                end

                if(slot == SLOT_JOY_Y) begin
                    slot       <= '0;
                    conv_start <= 1'b1;  // 摇杆 X/Y 都到齐，启动一次 cordic
                end
                else slot <= slot + 1'b1;

                state <= S_DISCHARGE;
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


