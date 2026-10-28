`timescale 1ns/1ps
module tb_sidebar_render;
    import config_pkg::*;
    logic clk=0,rst_n=0,frame_pulse=0;
    always #5 clk=~clk;
    logic[9:0] x=0,y=0;
    sidebar_snapshot_t view;
    wire hit;
    wire[5:0] r,g,b;
    wire[8:0] width;
    integer image,bright=0,panel=0;
    string filename;
    lcd_sidebar dut(.clk(clk),.rst_n(rst_n),.frame_pulse(frame_pulse),.lcd_valid(1'b1),
        .pix_x(x),.pix_y(y),.view(view),.hit(hit),.r(r),.g(g),.b(b),.visible_width(width));
    task automatic frame();
        @(negedge clk);frame_pulse=1;@(negedge clk);frame_pulse=0;
    endtask
    task automatic capture(input string name);
        image=$fopen(name,"wb");$fwrite(image,"P6\n800 480\n255\n");
        for(integer yy=0;yy<480;yy=yy+1)begin
            for(integer xx=0;xx<800;xx=xx+1)begin
                @(negedge clk);x=10'(xx);y=10'(yy);
                @(posedge clk);#1;
                if(hit)begin
                    $fwrite(image,"%c%c%c",{r,r[5:4]},{g,g[5:4]},{b,b[5:4]});panel=panel+1;
                    if(r>40&&g>40&&b>40)bright=bright+1;
                end else begin
                    // 测试底图，不是音频或 FFT 数据；用来检查侧栏覆盖与透明区。
                    if(yy>260+((xx/12)%7)*18)$fwrite(image,"%c%c%c",8'd25,8'd145,8'd115);
                    else $fwrite(image,"%c%c%c",8'd9,8'd17,8'd24);
                end
                if(width!=288)$fatal(1,"width changed during a frame");
                if((xx<288||yy<48)!==hit)$fatal(1,"panel clipping mismatch %0d/%0d",xx,yy);
            end
        end
        $fclose(image);
    endtask
    initial begin
        view='0;view.display_cfg=display_defaults();view.values=cfg_defaults();view.supported=LOCAL_MASK;
        view.scene.open=1;view.scene.layer=1;view.scene.category=3;view.scene.selection=0;
        repeat(3)@(negedge clk);rst_n=1;
        for(integer i=0;i<12;i=i+1)frame();
        if(width!=288)$fatal(1,"open easing endpoint");
        if(!$value$plusargs("image=%s",filename))filename="sidebar.ppm";
        capture(filename);
        if(bright<500||panel!=288*480+512*48)$fatal(1,"missing font/panel pixels");
        view.scene.layer=2;view.scene.edit_index=6;view.scene.draft=1;
        capture({filename,".dropdown.ppm"});
        view.scene.open=0;
        for(integer i=0;i<12;i=i+1)frame();
        if(width!=0)$fatal(1,"close easing endpoint");
        $display("PASS sidebar_render Chinese glyph pixels=%0d",bright);$finish;
    end
    initial begin #20000000;$fatal(1,"watchdog");end
endmodule
