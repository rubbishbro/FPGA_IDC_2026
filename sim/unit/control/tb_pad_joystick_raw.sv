`timescale 1ns/1ps
// 行为 ADC 只验证数字接线/握手，不模拟 Gowin 原语或模拟前端。
module Gowin_ADC (
    output logic adcrdy,
    output logic [13:0] adcvalue,
    input wire drstn, adcreqi,
    input wire [9:0] fscal_value,
    input wire [13:0] offset_value
);
    integer conversion = 0;
    logic dropped_y = 0;
    logic [2:0] channel;
    logic [13:0] value;
    initial begin
        adcrdy = 0; adcvalue = 0;
        forever begin
            @(posedge adcreqi);
            adcrdy = 0;
            conversion = conversion + 1;
            channel = tb_pad_joystick_raw.input_p.ch_s;
            value = (channel == 3'd4) ? 14'(7000+conversion) :
                    ((channel == 3'd5) ? 14'(9000+conversion) : 14'(conversion));
            #200;
            if (channel !== tb_pad_joystick_raw.input_p.ch_s)
                $fatal(1,"ADC channel changed during conversion");
            if (channel == 3'd5 && !dropped_y) dropped_y = 1;
            else if (drstn) begin adcvalue = value; adcrdy = 1; end
        end
    end
endmodule

module tb_pad_joystick_raw #(
    parameter bit DUMMY_READ = 0
);
    import clk_rst_pkg::*;
    import pad_driver_pkg::*;
    import joystick_pkg::*;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic [1:0] divider = 0;
    always @(posedge clk) divider <= divider + 1'b1;
    wire clk_en = divider == 0;
    clk_rst cr;
    assign cr = {clk,clk_en,rst_n};
    input_param input_p;
    wire joy_sample_valid;
    wire [13:0] joy_raw_x, joy_raw_y;
    sense4x4_joystick #(.DISCHARGE_CYCLES(2), .SETTLE_CYCLES(2),
                        .REQ_CYCLES(2), .RDY_TIMEOUT(12), .DUMMY_READ(DUMMY_READ)) dut (
                    .cr(cr), .row_s(input_p.row_s), .ch_s(input_p.ch_s),
                    .fmap(input_p.fmap), .pos(input_p.pos),
                    .joy_sample_valid(joy_sample_valid), .joy_raw_x(joy_raw_x), .joy_raw_y(joy_raw_y));
    wire calibrated, stale, position_update, nav_valid, nav_repeat;
    wire [13:0] center_x, center_y;
    wire signed [14:0] dx, dy;
    joy_dir_t direction, nav_dir;
    joystick_adapter #(.CALIB_LOG2(1)) adapter (
        .clk(clk), .rst_n(rst_n), .recalibrate(1'b0),
        .sample_valid(joy_sample_valid), .raw_x(joy_raw_x), .raw_y(joy_raw_y),
        .calibrated(calibrated), .stale(stale), .center_x(center_x), .center_y(center_y),
        .position_update(position_update), .dx(dx), .dy(dy), .direction(direction),
        .nav_valid(nav_valid), .nav_ready(1'b1), .nav_dir(nav_dir), .nav_repeat(nav_repeat)
    );
    integer x_completions = 0, y_completions = 0, pairs = 0, published = 0;
    integer position_count = 0;
    logic [13:0] expected_x, expected_y;
    logic was_valid = 0;
    always @(posedge dut.adc_rdy) begin
        if (input_p.ch_s == 3'd4) begin
            x_completions = x_completions + 1;
            if (x_completions % (DUMMY_READ+1) == 0)
                expected_x = dut.adc_val;
        end else if (input_p.ch_s == 3'd5) begin
            y_completions = y_completions + 1;
            if (y_completions % (DUMMY_READ+1) == 0) begin
                expected_y = dut.adc_val;
                pairs = pairs + 1;
            end
        end
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (joy_sample_valid) begin
                if (was_valid) $fatal(1,"valid stretched by clk_en");
                published = published + 1;
                if (published != pairs || joy_raw_x !== expected_x || joy_raw_y !== expected_y)
                    $fatal(1,"raw pair mismatch got %0d/%0d expected %0d/%0d pairs=%0d published=%0d",
                           joy_raw_x,joy_raw_y,expected_x,expected_y,pairs,published);
            end
            if (position_update) position_count = position_count + 1;
            was_valid = joy_sample_valid;
        end
    end
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        wait (published >= 5);
        repeat (4) @(negedge clk);
        if (!calibrated || stale || position_count != published-2 ||
            !dut.adc_inst.dropped_y)
            $fatal(1,"driver -> adapter calibration/update count");
        rst_n = 0;
        repeat (2) @(negedge clk);
        if (joy_sample_valid || joy_raw_x != 0 || joy_raw_y != 0)
            $fatal(1,"raw output reset");
        $display("PASS pad joystick raw dummy=%0d pairs=%0d (includes ADC timeout retry)",DUMMY_READ,published);
        $finish;
    end
    initial begin #2000000; $fatal(1,"watchdog"); end
endmodule
