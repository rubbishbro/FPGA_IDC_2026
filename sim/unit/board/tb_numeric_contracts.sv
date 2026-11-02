`timescale 1ns/1ps
module tb_numeric_contracts;
    import config_pkg::*;
    import joystick_pkg::*;
    logic clk=0,rst_n=0,tick=0;
    always #5 clk=~clk;
    logic signed[14:0] dx=0,dy=0;
    joy_dir_t direction=JOY_CENTER;
    sidebar_scene_t scene;
    sidebar_ctrl #(.HOT_DWELL_MS(1000000000)) navigation(
        .clk(clk),.rst_n(rst_n),.tick_ms(tick),.joy_calibrated(1'b1),.joy_stale(1'b0),
        .dx(dx),.dy(dy),.direction(direction),.nav_valid(1'b0),.nav_repeat(1'b0),
        .nav_dir(JOY_CENTER),.nav_ready(),.key_valid(1'b0),.key_event(3'd0),
        .active_values('0),.supported('0),.cfg_valid(),.cfg_ready(1'b1),.cfg_request(),
        .rsp_valid(1'b0),.rsp_ready(),.cfg_response('0),.scene(scene));
    integer model_x=400,model_y=240,mx,my,sx,sy;
    envelope_ADSR #(.SLOTS(1)) envelope(.clk(1'b0),.rst_n(1'b0),.clk_en(1'b0),
        .sustain_mode(1'b0),.slot_a_step(32'd0),.slot_r_step(32'd0),.A_STEP(32'd0),.D_STEP(32'd0),
        .S_LEVEL(32'd0),.decay_limit(32'd0),.R_STEP(32'd0),.retrigger(1'b0),.slot_clear(1'b0),
        .note_on(1'b0),.note_gate(1'b0),.emap(),.emap_valid(),.dead());
    integer checks=0,seed=43521;
    logic[31:0] a,b;
    task automatic range_check(input integer index,input logic signed[31:0] value);
        logic expected;
        expected=index>=0 && index<CFG_COUNT && cfg_id(index)!=16'hffff && value>=0 && value<=cfg_max(index);
        if(cfg_value_valid(index,value)!==expected)$fatal(1,"FAIL config range equivalence %d/%d",index,value);
        checks++;
    endtask
    initial begin
        for(integer i=-2;i<22;i++)begin
            range_check(i,0);range_check(i,-1);range_check(i,1);range_check(i,2);
            range_check(i,cfg_max(i));range_check(i,cfg_max(i)+1);range_check(i,cfg_max(i)-1);
            range_check(i,32'sh7fffffff);range_check(i,32'sh80000000);
            range_check(i,65534);range_check(i,65535);range_check(i,65536);
            range_check(i,1000);range_check(i,1001);range_check(i,1024);
            repeat(10000)range_check(i,$urandom(seed));
        end
        repeat(100000)begin
            a=$urandom(seed);b=$urandom(seed);
            if(envelope.le32(a,b)!==(a<=b) || !envelope.le32(a,a))$fatal(1,"FAIL octet compare %h/%h",a,b);
            checks+=2;
        end
        repeat(4)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
        for(integer n=0;n<50000;n++)begin
            @(negedge clk);tick=1;
            direction=(n%64==0)?JOY_CENTER:JOY_DOWN;
            case(n%16)
                0:begin dx=-16384;dy=16383;end
                1:begin dx=16383;dy=-16384;end
                2:begin dx=900;dy=-900;end
                3:begin dx=901;dy=-901;end
                4:begin dx=2047;dy=-2048;end
                default:begin dx=15'($urandom(seed));dy=15'($urandom(seed));end
            endcase
            // Original 32-bit mathematical contract, independent of narrowed RTL.
            mx=int'(dx);my=int'(dy);
            sx=(mx<0)?-mx:mx;sy=(my<0)?-my:my;
            sx=(sx>900 && direction!=JOY_CENTER)?((sx/2048)==0?1:sx/2048):0;
            sy=(sy>900 && direction!=JOY_CENTER)?((sy/2048)==0?1:sy/2048):0;
            model_x+=(mx<0)?-sx:sx;model_y+=(my>0)?-sy:sy;
            if(model_x<0)model_x=0;else if(model_x>799)model_x=799;
            if(model_y<0)model_y=0;else if(model_y>479)model_y=479;
            @(negedge clk);tick=0;
            if(scene.cursor_x!==10'(model_x) || scene.cursor_y!==9'(model_y) || scene.open)
                $fatal(1,"FAIL navigation equivalence %d dx/dy=%d/%d cursor=%d/%d expected=%d/%d",n,dx,dy,scene.cursor_x,scene.cursor_y,model_x,model_y);
            checks++;
        end
        $display("PASS tb_numeric_contracts checks=%d config_ranges_unsigned_compare_navigation",checks);$finish;
    end
endmodule
