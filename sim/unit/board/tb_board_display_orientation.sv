`timescale 1ns/1ps
// Independent full-frame comparison: the panel still scans forward, while the
// production sidebar/font pipeline must emit the exact 180-degree image.
module tb_board_display_orientation;
    import config_pkg::*;
    logic clk=0,render_n=0,scan_n=0,warm_frame=0;
    always #5 clk=~clk;
    wire de0,de1,frame0,frame1;
    wire [9:0] x0,y0,x1,y1;
    lcd_timing normal(.lcd_clk(clk),.rst_n(scan_n),.lcd_en(de0),.frame_pulse(frame0),.pix_x(x0),.pix_y(y0));
    lcd_timing #(.ROTATE_180(1)) rotated(.lcd_clk(clk),.rst_n(scan_n),.lcd_en(de1),.frame_pulse(frame1),.pix_x(x1),.pix_y(y1));
    sidebar_snapshot_t view;
    wire hit0,hit1;
    wire [5:0] r0,g0,b0,r1,g1,b1;
    wire [8:0] width0,width1;
    lcd_sidebar a(.clk(clk),.rst_n(render_n),.frame_pulse(warm_frame|frame0),.lcd_valid(de0),
        .pix_x(x0),.pix_y(y0),.view(view),.guide_view('0),.hit(hit0),.r(r0),.g(g0),.b(b0),.visible_width(width0));
    lcd_sidebar b(.clk(clk),.rst_n(render_n),.frame_pulse(warm_frame|frame1),.lcd_valid(de1),
        .pix_x(x1),.pix_y(y1),.view(view),.guide_view('0),.hit(hit1),.r(r1),.g(g1),.b(b1),.visible_width(width1));
    wire fh0,fh1;
    wire [5:0] fr0,fg0,fb0,fr1,fg1,fb1;
    lcd_fft f0(.clk(clk),.rst_n(render_n),.frame_pulse(1'b0),.dot_en(1'b0),
        .peak_en(1'b0),.theme(1'b0),.smooth_en(1'b0),.q_y(10'd160),.q_ov(10'd180),
        .pix_x(x0),.pix_y(y0),.fft_hit(fh0),.fft_r(fr0),.fft_g(fg0),.fft_b(fb0));
    lcd_fft #(.REVERSE_SCAN(1)) f1(.clk(clk),.rst_n(render_n),.frame_pulse(1'b0),.dot_en(1'b0),
        .peak_en(1'b0),.theme(1'b0),.smooth_en(1'b0),.q_y(10'd160),.q_ov(10'd180),
        .pix_x(x1),.pix_y(y1),.fft_hit(fh1),.fft_r(fr1),.fft_g(fg1),.fft_b(fb1));
    logic [18:0] reference_image[0:383999],rotated_image[0:383999];
    logic [18:0] reference_fft[0:383999],rotated_fft[0:383999];
    integer id0=-1,id1=-1,id2=-1,physical_id=-1,active=0,clocks=0;
    integer captured0=0;
    always @(posedge clk)begin
        physical_id=de0 ? int'(y0)*800+int'(x0) : -1;
        if(scan_n)begin
            if(de0!==de1 || frame0!==frame1)$fatal(1,"rotation changed panel timing");
            clocks++;
            if(de0)begin
                active++;
                if(x1!=799-x0 || y1!=479-y0)$fatal(1,"rotated coordinate mismatch");
            end
        end
        id2=id1;id1=id0;id0=physical_id;
        #1;
        // The counters belong to the coordinate sampled before this edge,
        // held in pxx, rather than the timing counter's next pixel.
        if(render_n && id0>=0 && f1.pxx<768 &&
           (f1.bar_idx_c!=f1.pxx/6 || f1.xmod_c!=f1.pxx%6))
            $fatal(1,"reverse FFT bar index mismatch x=%0d bar=%0d mod=%0d",f1.pxx,f1.bar_idx_c,f1.xmod_c);
        if(render_n && id0>=0)begin
            reference_fft[id0]={fh0,fr0,fg0,fb0};
            rotated_fft[id0]={fh1,fr1,fg1,fb1};
        end
        if(render_n && id2>=0)begin
            reference_image[id2]={hit0,r0,g0,b0};
            rotated_image[id2]={hit1,r1,g1,b1};
            captured0++;
        end
    end
    initial begin
        view='0;view.display_cfg=display_defaults();view.values=cfg_defaults();view.supported=LOCAL_MASK;
        view.scene.open=1;view.scene.layer=1;view.scene.category=3;view.scene.selection=0;
        repeat(4)@(negedge clk);render_n=1;
        repeat(12)begin warm_frame=1;@(negedge clk);warm_frame=0;repeat(32)@(negedge clk);end
        if(width0!=288 || width1!=288)$fatal(1,"sidebar warmup");
        @(negedge clk);scan_n=1;
        wait(frame0);@(posedge clk);@(negedge clk);#2;
        if(active!=384000 || clocks!=1192*533 || captured0!=384000)
            $fatal(1,"frame coverage active=%0d clocks=%0d captured=%0d",active,clocks,captured0);
        for(integer i=0;i<384000;i++)begin
            if(rotated_image[i]!==reference_image[383999-i])
                $fatal(1,"sidebar not rotated pixel=%0d actual=%h expected=%h",i,rotated_image[i],reference_image[383999-i]);
            if(rotated_fft[i]!==reference_fft[383999-i])
                $fatal(1,"FFT not rotated pixel=%0d actual=%h expected=%h",i,rotated_fft[i],reference_fft[383999-i]);
        end
        $display("PASS tb_board_display_orientation 384000 sidebar/font + FFT pixels exact180, unchanged DE/frame timing");
        $finish;
    end
    initial begin #10000000;$fatal(1,"display orientation watchdog");end
endmodule
