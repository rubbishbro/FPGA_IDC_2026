`timescale 1ns/1ps
module tb_joystick_adapter #(
    parameter integer CALIB_LOG2 = 2,
    parameter bit SWAP_XY = 0,
    parameter bit INVERT_X = 0,
    parameter bit INVERT_Y = 0
);
    import joystick_pkg::*;
    localparam integer CLK_HZ = 10_000;
    localparam integer MS_CYCLES = 10;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, recalibrate = 0, sample_valid = 0, nav_ready = 1;
    logic [13:0] raw_x = 0, raw_y = 0, center_x, center_y;
    logic calibrated, stale, position_update, nav_valid, nav_repeat;
    logic signed [14:0] dx, dy;
    joy_dir_t direction, nav_dir;
    joystick_adapter #(
        .CLK_HZ(CLK_HZ), .CALIB_LOG2(CALIB_LOG2),
        .REPEAT_DELAY_MS(4), .REPEAT_PERIOD_MS(2), .SAMPLE_TIMEOUT_MS(12),
        .SWAP_XY(SWAP_XY), .INVERT_X(INVERT_X), .INVERT_Y(INVERT_Y)
    ) dut (.*);

    integer cycles = 0, events = 0;
    integer event_cycle [0:8191];
    logic [3:0] event_dir [0:8191];
    logic event_repeat [0:8191];
    logic held = 0;
    logic [3:0] held_dir;
    logic held_repeat;
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (!rst_n) held = 0;
        else begin
            if (held && (!nav_valid || nav_dir !== held_dir || nav_repeat !== held_repeat))
                $fatal(1, "payload changed under backpressure");
            if (nav_valid && nav_ready) begin
                event_cycle[events] = cycles;
                event_dir[events] = nav_dir;
                event_repeat[events] = nav_repeat;
                events = events + 1;
            end
            held = nav_valid && !nav_ready;
            held_dir = nav_dir;
            held_repeat = nav_repeat;
        end
    end

    task automatic wait_clocks(input integer n);
        repeat (n) begin @(posedge clk); #1; end
    endtask
    task automatic sample(input integer x, input integer y);
        @(negedge clk);
        raw_x = 14'(x); raw_y = 14'(y); sample_valid = 1;
        @(posedge clk); #1;
        @(negedge clk); sample_valid = 0;
    endtask
    task automatic calibrate(input integer cx, input integer cy);
        for (integer i=0; i<(2**CALIB_LOG2); i=i+1) begin
            // 非恒定样本，验证累加和平均；N=1 直接取一对。
            sample(cx + ((CALIB_LOG2 == 0) ? 0 : ((i%2) ? 20 : -20)),
                   cy + ((CALIB_LOG2 == 0) ? 0 : ((i%2) ? -40 : 40)));
            if (calibrated !== (i == (2**CALIB_LOG2)-1))
                $fatal(1, "calibration count");
            if (position_update || direction != JOY_CENTER)
                $fatal(1, "movement during calibration");
        end
        if (center_x != cx || center_y != cy || stale)
            $fatal(1, "calibration average %0d/%0d", center_x, center_y);
    endtask
    function automatic integer axis_ref(input integer value, input integer previous);
        if (value >= 1400) axis_ref = 1;
        else if (value <= -1400) axis_ref = -1;
        else if (previous == 1 && value > 900) axis_ref = 1;
        else if (previous == -1 && value < -900) axis_ref = -1;
        else axis_ref = 0;
    endfunction
    function automatic integer dir_ref(input integer x, input integer y);
        case (y)
             1: dir_ref = (x < 0) ? JOY_UP_LEFT : ((x > 0) ? JOY_UP_RIGHT : JOY_UP);
            -1: dir_ref = (x < 0) ? JOY_DOWN_LEFT : ((x > 0) ? JOY_DOWN_RIGHT : JOY_DOWN);
            default: dir_ref = (x < 0) ? JOY_LEFT : ((x > 0) ? JOY_RIGHT : JOY_CENTER);
        endcase
    endfunction
    integer ref_x = 0, ref_y = 0;
    task automatic move(input integer x, input integer y);
        integer mx, my;
        mx = INVERT_X ? -x : x;
        my = INVERT_Y ? -y : y;
        sample(int'(center_x) + (SWAP_XY ? my : mx),
               int'(center_y) + (SWAP_XY ? mx : my));
        ref_x = axis_ref(x, ref_x); ref_y = axis_ref(y, ref_y);
        if (!position_update || stale || $signed(dx) != x || $signed(dy) != y ||
            direction != dir_ref(ref_x, ref_y))
            $fatal(1, "position/direction x=%0d y=%0d got %0d/%0d dir=%0d expected=%0d",
                   x, y, dx, dy, direction, dir_ref(ref_x, ref_y));
    endtask

    integer first, before_events, seed, random_value, rx, ry;
    initial begin
        seed = 20261027;
        if ($value$plusargs("seed=%d", seed)) begin end
        random_value = $urandom(seed);
        wait_clocks(3);
        @(negedge clk); rst_n = 1;
        wait_clocks(130);
        if (calibrated || !stale || nav_valid || direction != JOY_CENTER)
            $fatal(1, "startup without samples");
        calibrate(8100, 8300);
        move(0,0);
        move(0,2000); move(2000,2000); move(2000,0); move(2000,-2000);
        move(0,-2000); move(-2000,-2000); move(-2000,0); move(-2000,2000);
        move(0,0);

        // 阈值等号、迟滞带、正负方向直接反转、中心抖动。
        move(1399,0); move(1400,0); move(1000,0); move(900,0);
        move(-1399,0); move(-1400,0); move(-901,0); move(-900,0);
        move(2000,0); move(-2000,0); move(0,0);
        move(0,1399); move(0,1400); move(0,901); move(0,900);
        move(0,-1400); move(0,-901); move(0,-900);
        for (integer i=0; i<64; i=i+1) begin
            rx = int'($urandom_range(0,1600))-800;
            ry = int'($urandom_range(0,1600))-800;
            move(rx,ry);
            if (direction != JOY_CENTER) $fatal(1, "center jitter");
        end
        // 全量程输入也必须先零扩展再相减，不得按 ADC 符号位翻转。
        sample(0,16383);
        rx = -int'(center_x); ry = 16383-int'(center_y);
        if (SWAP_XY) begin random_value = rx; rx = ry; ry = random_value; end
        if (INVERT_X) rx = -rx;
        if (INVERT_Y) ry = -ry;
        ref_x = axis_ref(rx,ref_x); ref_y = axis_ref(ry,ref_y);
        if ($signed(dx) != rx || $signed(dy) != ry || direction != dir_ref(ref_x,ref_y))
            $fatal(1, "ADC signed extrema");
        for (integer i=0; i<1000; i=i+1)
            move(int'($urandom_range(0,10000))-5000, int'($urandom_range(0,10000))-5000);
        move(0,0); wait_clocks(4);

        first = events;
        move(2000,0); wait_clocks(4);
        if (events != first+1 || event_dir[first] != JOY_RIGHT || event_repeat[first])
            $fatal(1, "initial direction event");
        // 保持推杆且持续提供新样本，重复间隔应等于 2ms，而非采样帧数。
        for (integer i=0; i<30; i=i+1) begin move(2000,0); wait_clocks(5); end
        if (events < first+5) $fatal(1, "missing repeats");
        if (event_cycle[first+1]-event_cycle[first] < 30 ||
            event_cycle[first+1]-event_cycle[first] > 41)
            $fatal(1, "first repeat delay");
        for (integer i=first+1; i<events; i=i+1) begin
            if (event_dir[i] != JOY_RIGHT || !event_repeat[i]) $fatal(1, "repeat payload");
            if (i>first+1 && event_cycle[i]-event_cycle[i-1] != 2*MS_CYCLES)
                $fatal(1, "repeat interval");
        end

        move(0,0); wait_clocks(4);
        @(negedge clk); nav_ready = 0;
        move(-2000,0); wait_clocks(4);
        if (!nav_valid || nav_dir != JOY_LEFT || nav_repeat) $fatal(1, "held event");
        for (integer i=0; i<25; i=i+1) begin move(-2000,0); wait_clocks(5); end
        move(0,2000); move(0,0); move(2000,-2000);
        before_events = events;
        @(negedge clk); nav_ready = 1;
        wait_clocks(4);
        if (events != before_events+2 || event_dir[before_events] != JOY_LEFT ||
            event_dir[before_events+1] != JOY_DOWN_RIGHT || event_repeat[before_events+1])
            $fatal(1, "coalesced latest direction after backpressure");

        // 采样断流必须停连发并回中；恢复不应重新校准已知中心。
        wait_clocks(130);
        if (!stale || !calibrated || direction != JOY_CENTER || dx != 0 || dy != 0)
            $fatal(1, "sample timeout");
        before_events = events; wait_clocks(60);
        if (events != before_events) $fatal(1, "repeats after timeout");
        ref_x = 0; ref_y = 0; move(-2000,-2000); wait_clocks(4);

        // 重校准将连续状态回中；在途事件仍遵守 valid/ready。
        @(negedge clk); nav_ready = 0;
        move(2000,0); wait_clocks(4);
        @(negedge clk); recalibrate = 1;
        wait_clocks(1);
        @(negedge clk); recalibrate = 0;
        if (calibrated || !stale || direction != JOY_CENTER) $fatal(1, "recalibrate");
        calibrate(7000,9000);
        @(negedge clk); nav_ready = 1;
        wait_clocks(4);
        if (nav_valid) $fatal(1, "stale pending movement after recalibration drain");
        ref_x = 0; ref_y = 0; move(0,0);

        // 校准被断流打断后，应丢弃部分累计，再取完整的一组。
        @(negedge clk); recalibrate = 1;
        wait_clocks(1); @(negedge clk); recalibrate = 0;
        if (CALIB_LOG2 > 0) begin
            sample(1000,1000); wait_clocks(130);
            if (!stale || calibrated) $fatal(1, "partial calibration timeout");
        end
        calibrate(8192,8192);
        // 复位取消未交付事件。
        @(negedge clk); nav_ready = 0;
        ref_x = 0; ref_y = 0; move(0,-2000); wait_clocks(4);
        @(negedge clk); rst_n = 0;
        wait_clocks(2);
        if (nav_valid || calibrated || !stale || direction != JOY_CENTER)
            $fatal(1, "reset cancellation");
        $display("PASS joystick_adapter cal=%0d swap=%0d inv=%0d%0d events=%0d", CALIB_LOG2,
                 SWAP_XY, INVERT_X, INVERT_Y, events);
        $finish;
    end
    initial begin #1000000; $fatal(1,"watchdog"); end
endmodule
