`timescale 1ns/1ps
// Real guide mailbox, renderer, sidebar overlay and final RGB/DE pipeline.
module tb_guide_render;
    import config_pkg::*;
    logic clk=0,rst_n=0,frame_pulse=0,key_valid=0;
    always #5 clk=~clk;
    logic [9:0] x=0,y=0;
    guide_display_t guide;
    logic [5:0] r,g,b;
    logic de;
    sidebar_scene_t scene;
    integer image,checks=0;
    string filename;
    sidebar_system #(.CTRL_HZ(1_000_000),.HAS_JOYSTICK(0)) dut(
        .rst_n(rst_n),.ctrl_clk(clk),.pix_clk(clk),.joy_sample_valid(1'b0),.joy_raw_x(14'd0),.joy_raw_y(14'd0),
        .key_valid(key_valid),.key_event(3'd2),.ext_cfg_valid(1'b0),.ext_cfg_ready(),.ext_cfg_request('0),
        .ext_rsp_valid(),.ext_rsp_ready(1'b1),.ext_cfg_response(),.backend_supported('0),.backend_valid(),
        .backend_ready(1'b0),.backend_request(),.backend_source(),.backend_rsp_valid(1'b0),
        .backend_rsp_ready(),.backend_response('0),.backend_audio_valid(1'b0),.backend_audio_fault(1'b0),.backend_audio_state('0),
        .guide_display(guide),.frame_pulse(frame_pulse),.lcd_valid(y<480),.pix_x(x),.pix_y(y),.q_y(10'd0),.q_ov(10'd0),
        .wave_rd_data(10'd0),.wave_rd_addr(),.curve_rd_data(40'd0),.curve_rd_addr(),
        .lcd_r(r),.lcd_g(g),.lcd_b(b),.lcd_valid_out(de),.active_values(),.ui_scene(scene),.sidebar_width());
    task automatic frame;
        repeat(20)@(negedge clk);frame_pulse=1;@(negedge clk);frame_pulse=0;
        repeat(20)@(negedge clk);
    endtask
    task automatic capture(input string name,input bit sidebar);
        integer xx,yy,slot,col,row;
        logic [17:0] expected;
        frame();frame();
        image=$fopen(name,"wb");$fwrite(image,"P6\n800 480\n255\n");
        for(integer k=0;k<800*480+3;k++)begin
            @(negedge clk);x=10'(k%800);y=10'(k/800);
            @(posedge clk);#1;
            if(k>=3)begin
                xx=(k-3)%800;yy=(k-3)/800;
                if(de!==1'b1 || (^{r,g,b})===1'bx)$fatal(1,"FAIL RGB/DE guide alignment k=%0d de=%b rgb=%h/%h/%h guide=%b pixel_guide=%b hit=%b sidebarhit=%b",k,de,r,g,b,guide.enabled,dut.pixel_guide.enabled,dut.guide_hit,dut.overlay_hit);
                $fwrite(image,"%c%c%c",{r,r[5:4]},{g,g[5:4]},{b,b[5:4]});
                if(!sidebar && xx>=90 && xx<720 && (xx-90)%160==0 && yy>=122 && yy<408 && (yy-122)%80==0)begin
                    col=(xx-90)/160;row=(yy-122)/80;slot=row*4+col;
                    case(slot)
                        4:expected={6'h08,6'h27,6'h1b};
                        6,10:expected={6'h2d,6'h23,6'h07};
                        0,3:expected={6'h16,6'h13,6'h08};
                        default:expected={6'h07,6'h0e,6'h13};
                    endcase
                    if({r,g,b}!==expected)$fatal(1,"FAIL slot %0d color got=%h expected=%h",slot,{r,g,b},expected);
                    checks++;
                end
            end
        end
        $fclose(image);
    endtask
    initial begin
        guide='0;guide.enabled=1;guide.audio.source=2;guide.audio.channel=2;guide.audio.guide=1;
        // Same actual legacy map as router_pkg::default_note_map; no router/DSP needed here.
        guide.note_map={7'd76,7'd71,7'd67,7'd64,7'd62,7'd60,7'd58,7'd56,7'd54,7'd52,7'd50,7'd48,7'd46,7'd44,7'd42,7'd40};
        guide.target=16'h0450;guide.pressed=16'h0030;guide.glow=16'h0009;guide.outside_count=1;guide.last_outside=61;
        repeat(4)@(negedge clk);rst_n=1;frame();frame();frame();
        if(!$value$plusargs("image=%s",filename))filename="guide.ppm";
        capture(filename,0);
        if(checks!=16)$fatal(1,"FAIL not all16 cells checked %0d",checks);
        @(negedge clk);key_valid=1;@(negedge clk);key_valid=0;
        repeat(16)frame();capture({filename,".sidebar.ppm"},1);
        if(dut.sidebar_width!=288)$fatal(1,"FAIL guide sidebar did not open");
        guide.enabled=0;frame();frame();
        if(dut.pixel_guide.enabled)$fatal(1,"FAIL guide page did not exit through CDC");
        $display("PASS tb_guide_render cells=%0d RGB/DE and sidebar snapshots",checks);$finish;
    end
    initial begin #30000000;$fatal(1,"FAIL guide render watchdog");end
endmodule
