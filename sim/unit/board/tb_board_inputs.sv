`timescale 1ns/1ps
module tb_board_inputs;
    logic clk=0,rst_n=0,sample=0;
    always #5 clk=~clk;
    logic [13:0] x=3000,y=3200;
    logic calibrated,stale,update;
    logic signed [14:0] dx,dy;
    joystick_pkg::joy_dir_t direction;
    joystick_adapter #(.CLK_HZ(1_000_000),.CALIB_LOG2(1),.FILTER_CENTER(1),.SWAP_XY(1),.INVERT_X(1),.INVERT_Y(1),.DEADZONE_ON(200),.DEADZONE_OFF(100),.SAMPLE_TIMEOUT_MS(2)) dut(
        .clk(clk),.rst_n(rst_n),.recalibrate(1'b0),.sample_valid(sample),.raw_x(x),.raw_y(y),
        .calibrated(calibrated),.stale(stale),.center_x(),.center_y(),.position_update(update),
        .dx(dx),.dy(dy),.direction(direction),.nav_valid(),.nav_ready(1'b1),.nav_dir(),.nav_repeat());
    logic cursor_tick=0;
    config_pkg::sidebar_scene_t scene;
    sidebar_ctrl cursor_ui(.clk(clk),.rst_n(rst_n),.tick_ms(cursor_tick),
        .joy_calibrated(calibrated),.joy_stale(stale),.dx(dx),.dy(dy),.direction(direction),
        .nav_valid(1'b0),.nav_repeat(1'b0),.nav_dir(joystick_pkg::JOY_CENTER),.nav_ready(),
        .key_valid(1'b0),.key_event(3'd0),.active_values('0),.supported('0),
        .cfg_valid(),.cfg_ready(1'b1),.cfg_request(),.rsp_valid(1'b0),.rsp_ready(),.cfg_response('0),.scene(scene));
    task automatic put(input int a,b);
        @(negedge clk);x=14'(a);y=14'(b);sample=1;@(negedge clk);sample=0;
    endtask
    // Observe screen coordinates, not just the adapter's signed deltas.
    task automatic move_cursor(input int a,b,sx,sy);
        int old_x,old_y;
        put(3000,3200);repeat(3)@(negedge clk);
        put(a,b);repeat(3)@(negedge clk);
        old_x=scene.cursor_x;old_y=scene.cursor_y;
        cursor_tick=1;@(negedge clk);cursor_tick=0;
        if(scene.cursor_x!=old_x+sx || scene.cursor_y!=old_y+sy)
            $fatal(1,"FAIL screen cursor movement raw=%d/%d actual=%d/%d expected=%d/%d",a,b,scene.cursor_x,scene.cursor_y,old_x+sx,old_y+sy);
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;put(3000,3200);put(3000,3200);
        if(!calibrated)$fatal(1,"FAIL calibration");
        put(3300,3001);
        if(dx!=0 || dy!=-300 || direction!=joystick_pkg::JOY_DOWN)$fatal(1,"FAIL transverse axis escaped deadzone");
        put(3300,3000);if(dx!=200)$fatal(1,"FAIL diagonal activation");
        put(3300,3050);if(dx!=150)$fatal(1,"FAIL hysteresis retention");
        put(3300,3100);if(dx!=0)$fatal(1,"FAIL axis release");
        put(3100,3101);if(dx!=0 || dy!=0 || direction!=joystick_pkg::JOY_CENTER)$fatal(1,"FAIL center drift");
        put(2700,3200);
        if(dx!=0 || dy!=300 || direction!=joystick_pkg::JOY_UP)$fatal(1,"FAIL board rotated profile up");
        put(3000,3200);
        if(dx!=0 || dy!=0)$fatal(1,"FAIL board XY center release");
        move_cursor(5000,3200,0,1);  // former right -> new down
        move_cursor(1000,3200,0,-1); // former left -> new up
        move_cursor(3000,1200,1,0);  // former up -> new right
        move_cursor(3000,5200,-1,0); // former down -> new left
        put(3000,3200);
        repeat(2200)@(negedge clk);if(!stale || dx!=0 || dy!=0)$fatal(1,"FAIL stale input");
        $display("PASS tb_board_inputs board50 swapped XY inverted X/Y 200/100 four-screen-directions deadzone/hysteresis/center/stale");$finish;
    end
endmodule

module tb_board_lcd_timing;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    wire de,frame;
    wire [9:0] x,y;
    integer active=0,total=0,frames=0;
    lcd_timing dut(.lcd_clk(clk),.rst_n(rst_n),.lcd_en(de),.frame_pulse(frame),.pix_x(x),.pix_y(y));
    always @(negedge clk)if(rst_n)begin
        total++;
        if(de)begin active++;if(x>=800 || y>=480)$fatal(1,"FAIL LCD pixel outside 800x480");end
        if(frame)begin
            if(active!=800*480 || total!=1192*533)$fatal(1,"FAIL LCD extent active=%d clocks=%d",active,total);
            frames++;active=0;total=0;
            if(frames==2)begin $display("PASS tb_board_lcd_timing exact800x480 frames=2");$finish;end
        end
    end
    initial begin repeat(3)@(posedge clk);#1;rst_n=1;end
endmodule
