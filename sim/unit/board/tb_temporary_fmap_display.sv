`timescale 1ns/1ps
// TEMP_FMAP_DISPLAY_20261101: asynchronous snapshot, decimal and pixel alignment.
module tb_temporary_fmap_display;
    logic core_clk=0,pix_clk=0,rst_n=0,frame_pulse=0,de=0;
    always #10 core_clk=~core_clk;
    always #15 pix_clk=~pix_clk;
    logic [127:0] fmap=0;
    logic [9:0] x=0,y=0;
    wire [5:0] r,g,b;
    temporary_fmap_display dut(
        .rst_n(rst_n),.core_clk(core_clk),.pix_clk(pix_clk),.frame_pulse(frame_pulse),
        .lcd_valid(de),.fmap_raw(fmap),.pix_x(x),.pix_y(y),
        .base_r(6'd3),.base_g(6'd5),.base_b(6'd7),.lcd_r(r),.lcd_g(g),.lcd_b(b));
    task automatic frame;
        wait(dut.snapshot_valid);
        @(negedge pix_clk);frame_pulse=1;
        @(negedge pix_clk);frame_pulse=0;
    endtask
    // Release raw reset between pixel edges while a visible panel is requested.
    // Pixel state must remain cleared for all three synchronization edges;
    // on the fourth edge the normal four-stage overlay pipeline may advance.
    task automatic reset_probe(input integer phase_ns);
        @(negedge pix_clk);x=320;y=48;de=1;frame_pulse=0;fmap='1;
        #(phase_ns);rst_n=0;
        #1;
        if(dut.pix_reset!==0 || {dut.hit_q,dut.ink_q,dut.grid_q}!==12'd0)
            $fatal(1,"overlay reset assertion was not asynchronous");
        for(integer i=0;i<16;i++)
            if(dut.numbers[i]!==0)$fatal(1,"reset retained old displayed number");
        #7;rst_n=1;
        for(integer stage=0;stage<3;stage++)begin
            @(posedge pix_clk);#1;
            if(dut.pix_n!==(stage==2))$fatal(1,"pixel reset released at wrong edge");
            if({dut.hit_q,dut.ink_q,dut.grid_q}!==12'd0)
                $fatal(1,"pixel pipeline advanced before synchronized release");
            for(integer i=0;i<16;i++)
                if(dut.numbers[i]!==0)$fatal(1,"number advanced during reset release");
        end
        @(posedge pix_clk);#1;
        if(dut.hit_q!==4'b0001)$fatal(1,"pixel pipeline did not resume after reset");
        @(negedge pix_clk);de=0;
        repeat(4)@(posedge pix_clk);
    endtask
    task automatic pixel(input integer px,py,input bit valid,
                          input integer er,eg,eb);
        @(negedge pix_clk);x=10'(px);y=10'(py);de=valid;
        repeat(4)@(posedge pix_clk);
        #1;if({r,g,b}!=={6'(er),6'(eg),6'(eb)})
            $fatal(1,"pixel (%0d,%0d) got %0d/%0d/%0d",px,py,r,g,b);
    endtask
    integer file_id;
    initial begin
        #101;rst_n=1;
        reset_probe(3);
        reset_probe(11);
        // Settle the initially queued reset map before each new group.
        for(integer group=0;group<16;group++)begin
            @(negedge core_clk);
            for(integer i=0;i<16;i++)fmap[i*8 +:8]=8'(group*16+i);
            frame();frame();
            for(integer i=0;i<16;i++)begin
                if(dut.numbers[i]!==12'(((group*16+i)/100)*256+
                       (((group*16+i)/10)%10)*16+(group*16+i)%10))
                    $fatal(1,"decimal/slot mismatch group=%0d slot=%0d",group,i);
            end
        end
        // The displayed 255 must stay unchanged despite source activity mid-frame.
        @(negedge core_clk);fmap=0;
        repeat(30)@(negedge pix_clk);
        if(dut.numbers[15]!==12'h255)$fatal(1,"snapshot changed during frame");
        pixel(319,48,1,3,5,7);   // outside: base passes through
        pixel(320,48,1,0,16,40); // grid
        pixel(321,49,1,0,0,8);   // opaque background
        pixel(335,56,1,63,63,0); // hundreds '2', top segment
        pixel(334,58,1,0,0,8);   // hundreds '2', upper-left segment absent
        pixel(340,58,1,63,63,0); // hundreds '2', upper-right segment present
        pixel(335,56,0,3,5,7);   // DE low cannot draw
        // Verify exactly four stages, not merely a settled result.
        @(negedge pix_clk);x=320;y=48;de=1;
        for(integer stage=0;stage<4;stage++)begin
            @(posedge pix_clk);#1;
            if(stage<3 && {r,g,b}!=={6'd3,6'd5,6'd7})$fatal(1,"overlay early");
            if(stage==3 && {r,g,b}!=={6'd0,6'd16,6'd40})$fatal(1,"overlay late");
        end
        frame();
        if(dut.numbers[15]!==0)$fatal(1,"new frame did not update");
        // Render a recognizable 16-value pattern; values include full unsigned range.
        @(negedge core_clk);
        for(integer i=0;i<16;i++)fmap[i*8 +:8]=8'(i*17);
        frame();frame();
        file_id=$fopen("fmap_panel.ppm","w");
        $fwrite(file_id,"P3\n256 128\n255\n");
        for(integer py=48;py<176;py++)begin
            for(integer px=320;px<576;px++)begin
                @(negedge pix_clk);x=10'(px);y=10'(py);de=1;
                repeat(4)@(posedge pix_clk);
                #1;$fwrite(file_id,"%0d %0d %0d\n",r*255/63,g*255/63,b*255/63);
            end
        end
        $fclose(file_id);
        $display("PASS tb_temporary_fmap_display reset_release all256_decimal frame_snapshot slot_order pixel_latency passthrough");
        $finish;
    end
    initial begin #20_000_000;$fatal(1,"timeout");end
endmodule
