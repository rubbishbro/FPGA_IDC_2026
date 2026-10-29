`timescale 1ns/1ps
module tb_board_inputs;
    logic clk=0,rst_n=0,sample=0;
    always #5 clk=~clk;
    logic [13:0] x=3000,y=3200;
    logic calibrated,stale,update;
    logic signed [14:0] dx,dy;
    joystick_pkg::joy_dir_t direction;
    joystick_adapter #(.CLK_HZ(1_000_000),.CALIB_LOG2(1),.FILTER_CENTER(1),.SAMPLE_TIMEOUT_MS(2)) dut(
        .clk(clk),.rst_n(rst_n),.recalibrate(1'b0),.sample_valid(sample),.raw_x(x),.raw_y(y),
        .calibrated(calibrated),.stale(stale),.center_x(),.center_y(),.position_update(update),
        .dx(dx),.dy(dy),.direction(direction),.nav_valid(),.nav_ready(1'b1),.nav_dir(),.nav_repeat());
    task automatic put(input int a,b);
        @(negedge clk);x=14'(a);y=14'(b);sample=1;@(negedge clk);sample=0;
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;put(3000,3200);put(3000,3200);
        if(!calibrated)$fatal(1,"FAIL calibration");
        put(5000,4200);
        if(dx!=2000 || dy!=0 || direction!=joystick_pkg::JOY_RIGHT)$fatal(1,"FAIL transverse axis escaped deadzone");
        put(5000,4700);if(dy!=1500)$fatal(1,"FAIL diagonal activation");
        put(5000,4200);if(dy!=1000)$fatal(1,"FAIL hysteresis retention");
        put(5000,4000);if(dy!=0)$fatal(1,"FAIL axis release");
        put(3200,3300);if(dx!=0 || dy!=0 || direction!=joystick_pkg::JOY_CENTER)$fatal(1,"FAIL center drift");
        repeat(2200)@(negedge clk);if(!stale || dx!=0 || dy!=0)$fatal(1,"FAIL stale input");
        $display("PASS tb_board_inputs per-axis deadzone/hysteresis/center/stale");$finish;
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
