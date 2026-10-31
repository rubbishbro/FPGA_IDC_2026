`timescale 1ns/1ps
// Uses the actual production PLL wrapper, initialization and vendor PLL model.
module tb_board_pll;
    logic clk=0;
    always #10 clk=~clk;
    wire core,audio,pixel,locked;
    logic core_done=0,audio_done=0,pixel_done=0;
    Gowin_PLL_core_100M dut(.clkin(clk),.init_clk(clk),.clkout0(core),.clkout_audio(audio),.clkout_pix(pixel),.lock(locked));
    realtime previous_edge,previous_rise,period,half_period;
    integer edges=0;
    initial begin
        wait(locked===1'b1);
        repeat(3)@(posedge core);
        previous_rise=$realtime;previous_edge=$realtime;
        for(integer i=0;i<256;i++)begin
            @(negedge core);half_period=$realtime-previous_edge;
            if(half_period<9.99 || half_period>10.01)$fatal(1,"FAIL PLL high width %f",half_period);
            previous_edge=$realtime;
            @(posedge core);half_period=$realtime-previous_edge;period=$realtime-previous_rise;
            if(period<19.99 || period>20.01 || half_period<9.99 || half_period>10.01 || !locked)
                $fatal(1,"FAIL PLL period/low/lock %f/%f/%b",period,half_period,locked);
            previous_rise=$realtime;previous_edge=$realtime;edges++;
        end
        core_done=1;
    end
    initial begin
        realtime last,delta;
        wait(locked);@(posedge audio);last=$realtime;
        repeat(64)begin @(negedge audio);delta=$realtime-last;if(delta<39.99||delta>40.01)$fatal(1,"FAIL audio half period");last=$realtime;
            @(posedge audio);delta=$realtime-last;if(delta<39.99||delta>40.01)$fatal(1,"FAIL audio half period");last=$realtime;end
        audio_done=1;
    end
    initial begin
        realtime last,delta;
        wait(locked);@(posedge pixel);last=$realtime;
        repeat(128)begin @(negedge pixel);delta=$realtime-last;if(delta<14.99||delta>15.01)$fatal(1,"FAIL pixel half period");last=$realtime;
            @(posedge pixel);delta=$realtime-last;if(delta<14.99||delta>15.01)$fatal(1,"FAIL pixel half period");last=$realtime;end
        pixel_done=1;
    end
    initial begin
        wait(core_done&&audio_done&&pixel_done);
        $display("PASS tb_board_pll vendor_model core=50MHz audio=12.5MHz pixel=33.333MHz duty=50%%");$finish;
    end
    initial begin #40000000;$fatal(1,"FAIL PLL lock/frequency timeout");end
endmodule
