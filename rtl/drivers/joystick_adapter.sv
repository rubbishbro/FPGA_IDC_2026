`timescale 1ns/1ps
// 双轴万向摇杆：原始 ADC -> 中心校准、连续偏移、八方向和导航重复。
// 全部端口同 clk 域；不依赖 clk_en / 极坐标 / UI 菜单 / control_loop。
module joystick_adapter #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer CALIB_LOG2 = 4,       // 上电/重校准平均 2**N 对样本
    parameter integer DEADZONE_ON = 1400,   // ADC counts，进入方向阈值
    parameter integer DEADZONE_OFF = 900,   // 退出阈值，形成迟滞
    parameter integer REPEAT_DELAY_MS = 400,
    parameter integer REPEAT_PERIOD_MS = 100,
    parameter integer SAMPLE_TIMEOUT_MS = 100,
    parameter bit SWAP_XY = 1'b0,
    parameter bit INVERT_X = 1'b0,
    parameter bit INVERT_Y = 1'b0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic recalibrate,               // 单周期；校准时摇杆保持松手
    input  logic sample_valid,              // 一对新样本，一拍；不支持反压
    input  logic [13:0] raw_x,
    input  logic [13:0] raw_y,

    output logic calibrated,
    output logic stale,                     // 无新样本超时，方向回中并停连发
    output logic [13:0] center_x,           // 原始轴顺序，不受 swap/invert 影响
    output logic [13:0] center_y,
    output logic position_update,           // 校准后的连续偏移更新，一拍
    output logic signed [14:0] dx,          // ADC counts；+X 向右，+Y 向上
    output logic signed [14:0] dy,
    output joystick_pkg::joy_dir_t direction,

    output logic nav_valid,
    input  logic nav_ready,
    output joystick_pkg::joy_dir_t nav_dir,
    output logic nav_repeat
);
    import joystick_pkg::*;
    localparam integer MS_DIV = CLK_HZ / 1000;
    localparam integer MS_W = (MS_DIV > 1) ? $clog2(MS_DIV) : 1;
    localparam integer CAL_W = (CALIB_LOG2 > 0) ? CALIB_LOG2 : 1;
    localparam integer SUM_W = 14 + CALIB_LOG2;
    localparam integer AGE_W = (SAMPLE_TIMEOUT_MS > 1) ? $clog2(SAMPLE_TIMEOUT_MS+1) : 1;
    localparam integer RPT_MAX = (REPEAT_DELAY_MS > REPEAT_PERIOD_MS)
                              ? REPEAT_DELAY_MS : REPEAT_PERIOD_MS;
    localparam integer RPT_W = (RPT_MAX > 1) ? $clog2(RPT_MAX+1) : 1;

    logic [MS_W-1:0] ms_count;
    wire tick_ms = (ms_count == MS_W'(MS_DIV-1));
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ms_count <= '0;
        else if (tick_ms) ms_count <= '0;
        else ms_count <= ms_count + 1'b1;
    end

    logic [CAL_W-1:0] cal_count;
    logic [SUM_W-1:0] sum_x, sum_y;
    wire [SUM_W-1:0] sum_next_x = sum_x + SUM_W'(raw_x);
    wire [SUM_W-1:0] sum_next_y = sum_y + SUM_W'(raw_y);
    logic [AGE_W-1:0] sample_age;
    logic signed [1:0] axis_x, axis_y;
    wire signed [14:0] raw_dx = $signed({1'b0, raw_x}) - $signed({1'b0, center_x});
    wire signed [14:0] raw_dy = $signed({1'b0, raw_y}) - $signed({1'b0, center_y});
    wire signed [14:0] mapped_x = SWAP_XY ? raw_dy : raw_dx;
    wire signed [14:0] mapped_y = SWAP_XY ? raw_dx : raw_dy;
    wire signed [14:0] delta_x = INVERT_X ? -mapped_x : mapped_x;
    wire signed [14:0] delta_y = INVERT_Y ? -mapped_y : mapped_y;

    function automatic logic signed [1:0] classify_axis(
        input logic signed [14:0] delta,
        input logic signed [1:0] previous
    );
        if      (delta >= DEADZONE_ON)  classify_axis = 2'sd1;
        else if (delta <= -DEADZONE_ON) classify_axis = -2'sd1;
        else if (previous == 2'sd1 && delta > DEADZONE_OFF)
            classify_axis = 2'sd1;
        else if (previous == -2'sd1 && delta < -DEADZONE_OFF)
            classify_axis = -2'sd1;
        else classify_axis = 2'sd0;
    endfunction

    always_comb begin
        direction = JOY_CENTER;
        if (axis_y > 0) begin
            if      (axis_x < 0) direction = JOY_UP_LEFT;
            else if (axis_x > 0) direction = JOY_UP_RIGHT;
            else direction = JOY_UP;
        end else if (axis_y < 0) begin
            if      (axis_x < 0) direction = JOY_DOWN_LEFT;
            else if (axis_x > 0) direction = JOY_DOWN_RIGHT;
            else direction = JOY_DOWN;
        end else if (axis_x < 0) direction = JOY_LEFT;
        else if (axis_x > 0) direction = JOY_RIGHT;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            calibrated <= 1'b0;
            stale <= 1'b1;
            center_x <= 14'd8192;
            center_y <= 14'd8192;
            position_update <= 1'b0;
            dx <= '0;
            dy <= '0;
            axis_x <= '0;
            axis_y <= '0;
            cal_count <= '0;
            sum_x <= '0;
            sum_y <= '0;
            sample_age <= '0;
        end else begin
            position_update <= 1'b0;
            if (recalibrate) begin
                calibrated <= 1'b0;
                stale <= 1'b1;
                dx <= '0;
                dy <= '0;
                axis_x <= '0;
                axis_y <= '0;
                cal_count <= '0;
                sum_x <= '0;
                sum_y <= '0;
                sample_age <= '0;
            end else if (sample_valid) begin
                stale <= 1'b0;
                sample_age <= '0;
                if (!calibrated) begin
                    if (cal_count == CAL_W'((2**CALIB_LOG2)-1)) begin
                        center_x <= 14'(sum_next_x >> CALIB_LOG2);
                        center_y <= 14'(sum_next_y >> CALIB_LOG2);
                        calibrated <= 1'b1;
                    end else begin
                        sum_x <= sum_next_x;
                        sum_y <= sum_next_y;
                        cal_count <= cal_count + 1'b1;
                    end
                end else begin
                    dx <= delta_x;
                    dy <= delta_y;
                    axis_x <= classify_axis(delta_x, axis_x);
                    axis_y <= classify_axis(delta_y, axis_y);
                    position_update <= 1'b1;
                end
            end else if (tick_ms && !stale) begin
                if (sample_age == AGE_W'(SAMPLE_TIMEOUT_MS-1)) begin
                    stale <= 1'b1;
                    dx <= '0;
                    dy <= '0;
                    axis_x <= '0;
                    axis_y <= '0;
                    // 不将断开前的部分校准样本与恢复后的样本混合。
                    if (!calibrated) begin
                        cal_count <= '0;
                        sum_x <= '0;
                        sum_y <= '0;
                    end
                end else sample_age <= sample_age + 1'b1;
            end
        end
    end

    // 重复计时基于系统毫秒节拍，不以 ADC 帧数作为时间。
    logic [RPT_W-1:0] repeat_left;
    joy_dir_t repeat_direction;
    wire repeat_due = tick_ms && repeat_left == RPT_W'(1) &&
                      direction == repeat_direction && direction != JOY_CENTER &&
                      calibrated && !stale && !recalibrate;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            repeat_left <= '0;
            repeat_direction <= JOY_CENTER;
        end else if (recalibrate || !calibrated || stale || direction == JOY_CENTER) begin
            repeat_left <= '0;
            repeat_direction <= JOY_CENTER;
        end else if (direction != repeat_direction) begin
            repeat_direction <= direction;
            repeat_left <= RPT_W'(REPEAT_DELAY_MS);
        end else if (tick_ms) begin
            if (repeat_left <= RPT_W'(1)) repeat_left <= RPT_W'(REPEAT_PERIOD_MS);
            else repeat_left <= repeat_left - 1'b1;
        end
    end

    // 一项持久事件槽；反压期间载荷稳定。方向变化合并为最新状态，
    // 不积压重复事件。旧槽取走后补发当前方向（包括回中），无需新 ADC 样本。
    joy_dir_t announced_direction;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nav_valid <= 1'b0;
            nav_dir <= JOY_CENTER;
            nav_repeat <= 1'b0;
            announced_direction <= JOY_CENTER;
        end else if (!nav_valid || nav_ready) begin
            nav_valid <= 1'b0;
            if (!recalibrate && direction != announced_direction) begin
                nav_valid <= 1'b1;
                nav_dir <= direction;
                nav_repeat <= 1'b0;
                announced_direction <= direction;
            end else if (repeat_due) begin
                nav_valid <= 1'b1;
                nav_dir <= direction;
                nav_repeat <= 1'b1;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_HZ < 1000 || CLK_HZ % 1000 != 0)
            $fatal(1, "joystick_adapter CLK_HZ must be a positive multiple of 1000");
        if (CALIB_LOG2 < 0 || CALIB_LOG2 > 16)
            $fatal(1, "joystick_adapter CALIB_LOG2 must be 0..16");
        if (DEADZONE_OFF < 0 || DEADZONE_ON <= DEADZONE_OFF || DEADZONE_ON > 16383)
            $fatal(1, "joystick_adapter needs 0 <= DEADZONE_OFF < DEADZONE_ON <= 16383");
        if (REPEAT_DELAY_MS < 1 || REPEAT_PERIOD_MS < 1 || SAMPLE_TIMEOUT_MS < 1)
            $fatal(1, "joystick_adapter timing parameters must be >= 1 ms");
    end
    // synthesis translate_on
endmodule
