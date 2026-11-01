`timescale 1ns/1ps
module tb_cordic_data_reset;
    logic clk=0,rst_n=0,in_valid=0;
    always #5 clk=~clk;
    logic signed [10:0] x=0,y=0;
    wire [19:0] radius,reference_radius;
    wire [15:0] angle,reference_angle;
    wire valid,reference_valid;
    cordic_polar dut(.clk(clk),.rst_n(rst_n),.x_in(x),.y_in(y),.in_valid(in_valid),
        .r_out(radius),.ang_out(angle),.out_valid(valid));
    cordic_polar_reset_reference ref_dut(.clk(clk),.rst_n(rst_n),.x_in(x),.y_in(y),.in_valid(in_valid),
        .r_out(reference_radius),.ang_out(reference_angle),.out_valid(reference_valid));
    integer compared=0;
    always @(posedge clk)begin
        #1;
        if(valid!==reference_valid)$fatal(1,"FAIL CORDIC validity changed");
        if(valid)begin
            if({radius,angle}!=={reference_radius,reference_angle} || (^{radius,angle})===1'bx)
                $fatal(1,"FAIL CORDIC valid result changed");
            compared++;
        end
    end
    initial begin
        // No data initialization in DUT: initial Xs and retained warm-reset
        // contents must be excluded by the validity pipeline.
        repeat(3)@(negedge clk);
        for(integer epoch=0;epoch<6;epoch++)begin
            #2;rst_n=0;#2;
            if(valid!==0)$fatal(1,"FAIL CORDIC asynchronous invalidation");
            repeat(3)@(negedge clk);rst_n=1;
            for(integer i=0;i<160;i++)begin
                @(negedge clk);x=11'($random);y=11'($random);
                in_valid=i<25 || i%5!=0;
            end
        end
        if(compared<500)$fatal(1,"FAIL insufficient CORDIC comparisons");
        $display("PASS tb_cordic_data_reset valid_vectors=%0d",compared);$finish;
    end
endmodule

module tb_polar_data_reset;
    logic clk=0,rst_n=0,lcd_valid=0,frame_pulse=0,theme=0;
    logic [9:0] x=0,y=0;
    always #5 clk=~clk;
    integer compared=0;
    for(genvar reverse=0;reverse<2;reverse++)begin:g_scan
        wire [9:0] addr,ref_addr;
        logic [39:0] data=0,ref_data=0;
        wire [17:0] rgb,ref_rgb;
        wire hit,ref_hit;
        lcd_polar_curve #(.REVERSE_SCAN(reverse)) dut(.clk(clk),.rst_n(rst_n),.frame_pulse(frame_pulse),
            .lcd_valid(lcd_valid),.pix_x(x),.pix_y(y),.curve_rd_addr(addr),.curve_rd_data(data),
            .theme(theme),.hit(hit),.r(rgb[17:12]),.g(rgb[11:6]),.b(rgb[5:0]));
        lcd_polar_curve_reset_reference #(.REVERSE_SCAN(reverse)) ref_dut(.clk(clk),.rst_n(rst_n),.frame_pulse(frame_pulse),
            .lcd_valid(lcd_valid),.pix_x(x),.pix_y(y),.curve_rd_addr(ref_addr),.curve_rd_data(ref_data),
            .theme(theme),.hit(ref_hit),.r(ref_rgb[17:12]),.g(ref_rgb[11:6]),.b(ref_rgb[5:0]));
        function automatic [39:0] history(input [9:0] col);
            return {10'(col/2),10'(col/3),10'(col/4),10'(col/5)};
        endfunction
        always @(posedge clk)begin
            data<=history(addr);ref_data<=history(ref_addr);
            #1;
            if({hit,rgb}!=={ref_hit,ref_rgb} || (^{hit,rgb})===1'bx)
                $fatal(1,"FAIL polar observable output changed reverse=%0d",reverse);
            if(dut.cord_v && addr!==ref_addr)$fatal(1,"FAIL valid curve address changed");
        end
    end
    initial begin
        repeat(4)@(negedge clk);
        for(integer epoch=0;epoch<5;epoch++)begin
            #2;rst_n=0;repeat(3)@(negedge clk);rst_n=1;
            for(integer i=0;i<1800;i++)begin
                @(negedge clk);x=10'(i%1192);y=10'((epoch*73+i/1192)%533);
                lcd_valid=i%1192<800;frame_pulse=i%1192==0;theme=epoch%2;
                compared++;
            end
        end
        $display("PASS tb_polar_data_reset scan_cycles=%0d both_directions",compared);$finish;
    end
endmodule

module tb_rgb_data_reset;
    logic pix_clk=0,pix_n=0,lcd_valid=0,overlay_hit=0,guide_hit=0;
    logic [5:0] base_r=0,base_g=0,base_b=0,overlay_r=0,overlay_g=0,overlay_b=0,
                guide_r=0,guide_g=0,guide_b=0;
    always #5 pix_clk=~pix_clk;
    wire lcd_valid_out;
    wire [5:0] lcd_r,lcd_g,lcd_b;
    wire ref_valid;
    wire [5:0] ref_r,ref_g,ref_b;
    rgb_pipeline_probe dut(.*);
    rgb_pipeline_reference ref_dut(.pix_clk(pix_clk),.pix_n(pix_n),.lcd_valid(lcd_valid),
        .base_r(base_r),.base_g(base_g),.base_b(base_b),.overlay_hit(overlay_hit),.guide_hit(guide_hit),
        .overlay_r(overlay_r),.overlay_g(overlay_g),.overlay_b(overlay_b),
        .guide_r(guide_r),.guide_g(guide_g),.guide_b(guide_b),.lcd_valid_out(ref_valid),
        .lcd_r(ref_r),.lcd_g(ref_g),.lcd_b(ref_b));
    always @(posedge pix_clk)begin
        #1;
        if({lcd_valid_out,lcd_r,lcd_g,lcd_b}!=={ref_valid,ref_r,ref_g,ref_b} ||
            (^{lcd_valid_out,lcd_r,lcd_g,lcd_b})===1'bx)$fatal(1,"FAIL RGB/DE equivalence");
    end
    initial begin
        repeat(3)@(negedge pix_clk);
        for(integer epoch=0;epoch<5;epoch++)begin
            #2;pix_n=0;#1;
            if({lcd_valid_out,lcd_r,lcd_g,lcd_b}!==19'd0)$fatal(1,"FAIL asynchronous LCD blanking");
            repeat(3)@(negedge pix_clk);pix_n=1;
            for(integer i=0;i<200;i++)begin
                @(negedge pix_clk);lcd_valid=i%7!=0;overlay_hit=i%3==0;guide_hit=i%5==0;
                {base_r,base_g,base_b}=$random;
                {overlay_r,overlay_g,overlay_b}=$random;{guide_r,guide_g,guide_b}=$random;
            end
        end
        $display("PASS tb_rgb_data_reset cold_warm_reset_DE_overlay");$finish;
    end
endmodule

module tb_mailbox_data_reset;
    logic src_clk=0,dst_clk=0,rst_n=0,src_valid=0,dst_ready=0,dst_running=1;
    logic [63:0] src_data=0;
    always #5 src_clk=~src_clk;
    always #7 if(dst_running)dst_clk=~dst_clk;else dst_clk=0;
    wire src_ready,src_done,dst_valid;
    wire [63:0] src_done_data,dst_data;
    wire ref_ready,ref_done,ref_valid;
    wire [63:0] ref_completed,ref_data;
    sidebar_mailbox #(.WIDTH(64)) dut(.*);
    sidebar_mailbox_reset_reference #(.WIDTH(64)) ref_dut(.rst_n(rst_n),.src_clk(src_clk),.dst_clk(dst_clk),
        .src_valid(src_valid),.src_ready(ref_ready),.src_data(src_data),.src_done(ref_done),
        .src_done_data(ref_completed),.dst_valid(ref_valid),.dst_ready(dst_ready),.dst_data(ref_data));
    integer deliveries=0;
    always @(posedge src_clk)begin
        #1;
        if({src_ready,src_done}!=={ref_ready,ref_done})$fatal(1,"FAIL mailbox source handshake");
        if(src_done && src_done_data!==ref_completed)$fatal(1,"FAIL mailbox completion payload");
    end
    always @(posedge dst_clk)begin
        if(rst_n && dst_valid && dst_ready)deliveries++;
        #1;
        if(dst_valid!==ref_valid)$fatal(1,"FAIL mailbox destination validity");
        if(dst_valid && (dst_data!==ref_data || (^dst_data)===1'bx))$fatal(1,"FAIL mailbox valid payload");
    end
    task put(input [63:0] value);
        @(negedge src_clk);while(!src_ready)@(negedge src_clk);
        src_data=value;src_valid=1;
        @(negedge src_clk);src_valid=0;src_data=~value;
    endtask
    task reset_shared;
        #2;rst_n=0;src_valid=0;dst_ready=0;#3;
        if(src_ready || src_done || dst_valid)$fatal(1,"FAIL mailbox reset isolation");
        repeat(4)@(negedge src_clk);rst_n=1;
        repeat(15)@(negedge src_clk);
        if(dst_valid || src_done || !src_ready)$fatal(1,"FAIL phantom transaction after reset");
    endtask
    initial begin
        repeat(4)@(negedge src_clk);reset_shared();
        for(integer i=0;i<30;i++)begin
            put({32'hc0db1234,32'(i)});
            wait(dst_valid);
            repeat(5)begin
                @(negedge dst_clk);
                if(dst_data!=={32'hc0db1234,32'(i)})$fatal(1,"FAIL stalled payload changed");
            end
            dst_ready=1;wait(src_done);@(negedge src_clk);dst_ready=0;
            if(src_done_data!=={32'hc0db1234,32'(i)})$fatal(1,"FAIL completed payload");
        end
        put(64'hffffffffffffffff);wait(dst_valid);reset_shared();
        // Destination clock stopped with an outstanding transaction, then reset.
        @(negedge dst_clk);dst_running=0;
        put(64'h0123456789abcdef);repeat(5)@(negedge src_clk);reset_shared();
        dst_running=1;repeat(10)@(negedge src_clk);
        if(dst_valid || src_done)$fatal(1,"FAIL stale request after stopped-clock reset");
        put(64'h76543210fedcba98);wait(dst_valid);dst_ready=1;wait(src_done);
        if(src_done_data!==64'h76543210fedcba98)$fatal(1,"FAIL first post-reset payload");
        if(deliveries!=31)$fatal(1,"FAIL mailbox deliveries=%0d",deliveries);
        $display("PASS tb_mailbox_data_reset async_clocks_stalls_cancellation_restart");$finish;
    end
    initial begin #100000;$fatal(1,"FAIL mailbox test timeout");end
endmodule
