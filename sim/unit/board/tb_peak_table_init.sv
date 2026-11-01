`timescale 1ns/1ps
module peak_init_case #(parameter bit REVERSE_SCAN=0)(output logic finished=0);
    logic clk=0,rst_n=0,clock_running=1;
    always #5 if(clock_running)clk=~clk;else clk=0;
    logic frame_pulse=0,dot_en=1,peak_en=1,theme=0,smooth_en=0;
    logic [9:0] q_y=300,q_ov=400,pix_x=1,pix_y=100;
    wire hit,ref_hit;
    wire [17:0] rgb,ref_rgb;
    lcd_fft #(.REVERSE_SCAN(REVERSE_SCAN)) dut(
        .clk(clk),.rst_n(rst_n),.frame_pulse(frame_pulse),.dot_en(dot_en),.peak_en(peak_en),
        .theme(theme),.smooth_en(smooth_en),.q_y(q_y),.q_ov(q_ov),.pix_x(pix_x),.pix_y(pix_y),
        .fft_hit(hit),.fft_r(rgb[17:12]),.fft_g(rgb[11:6]),.fft_b(rgb[5:0]));
    // The only intentional behavior change is the 128-clock initialization
    // interval: suppress reference peak updates/display during that interval.
    lcd_fft_reset_reference #(.REVERSE_SCAN(REVERSE_SCAN)) ref_dut(
        .clk(clk),.rst_n(rst_n),.frame_pulse(frame_pulse),.dot_en(dot_en&&dut.peak_init_done),
        .peak_en(peak_en&&dut.peak_init_done),.theme(theme),.smooth_en(smooth_en),
        .q_y(q_y),.q_ov(q_ov),.pix_x(pix_x),.pix_y(pix_y),.fft_hit(ref_hit),
        .fft_r(ref_rgb[17:12]),.fft_g(ref_rgb[11:6]),.fft_b(ref_rgb[5:0]));
    integer checks=0,updates=0,decays=0;
    logic [9:0] previous_dot;
    always @(posedge clk)begin
        if(rst_n && dut.peak_init_done && dot_en && peak_en && dut.xm==1)begin
            previous_dot=dut.dot_ram[dut.bar_idx];updates++;
            #1;if(dut.dot_ram[dut.bar_idx]<previous_dot)decays++;
        end
    end
    always @(negedge clk)if(rst_n)begin
        if({hit,rgb}!=={ref_hit,ref_rgb} || (^{hit,rgb})===1'bx)
            $fatal(1,"FAIL peak rendering changed reverse=%0d",REVERSE_SCAN);
        if(dut.peak_init_done)begin
            for(integer i=0;i<128;i++)
                if(dut.dot_ram[i]!==ref_dut.dot_ram[i] || dut.fall_ram[i]!==ref_dut.fall_ram[i])
                    $fatal(1,"FAIL peak state changed index=%0d reverse=%0d",i,REVERSE_SCAN);
            checks++;
        end
    end
    task assert_reset;
        #2;rst_n=0;#1;
        if(dut.peak_init_done!==0 || dut.peak_init_addr!==0 || dut.is_peak_dot!==0)
            $fatal(1,"FAIL asynchronous peak invalidation");
        repeat(3)@(negedge clk);
    endtask
    task initialize(input integer clocks);
        @(negedge clk);rst_n=1;
        for(integer i=0;i<clocks;i++)begin
            @(posedge clk);#1;
            if(dut.dot_ram[i]!==0 || dut.fall_ram[i]!==0)
                $fatal(1,"FAIL initialization write index=%0d",i);
            if(dut.peak_init_done!==(i==127))$fatal(1,"FAIL initialization completion cycle=%0d",i);
            if(i<127 && dut.is_peak_dot!==0)$fatal(1,"FAIL stale peak visible while initializing");
            @(negedge clk);
        end
    endtask
    initial begin
        // Arbitrary retained contents must survive reset until their normal
        // write slot; this catches accidental whole-table reset or update races.
        for(integer i=0;i<128;i++)begin dut.dot_ram[i]=10'(i+200);dut.fall_ram[i]=10'(i+1);end
        repeat(3)@(negedge clk);assert_reset();
        if(dut.dot_ram[127]!==327)$fatal(1,"FAIL table still has asynchronous reset");
        initialize(37); // interrupt an incomplete clear and start again at zero.
        assert_reset();
        if(dut.dot_ram[127]!==327)$fatal(1,"FAIL initialization wrote ahead of its address");
        initialize(128);
        // Exercise every bar, then gravity with a lower target, both scan orders.
        for(integer row=0;row<110;row++)begin
            for(integer x=0;x<800;x++)begin
                @(negedge clk);pix_x=10'(REVERSE_SCAN?799-x:x);pix_y=10'(row*40);
                q_y=row<2?10'd300:10'd100;q_ov=row<2?10'd400:10'd150;
                dot_en=x<768;peak_en=row!=5;theme=row%2;smooth_en=row%3==0;
                frame_pulse=x==0;
            end
        end
        // Initialization is unconditional even with peak/page updates disabled.
        @(negedge clk);dot_en=0;peak_en=0;frame_pulse=0;
        assert_reset();initialize(128);
        for(integer i=0;i<128;i++)if(dut.dot_ram[i]!==0 || dut.fall_ram[i]!==0)
            $fatal(1,"FAIL disabled-page initialization");
        // Reset must assert with the pixel clock stopped; clearing resumes only
        // when that clock returns, then still takes all 128 clocks.
        @(negedge clk);clock_running=0;#2;rst_n=0;#30;
        if(dut.peak_init_done!==0 || dut.is_peak_dot!==0)$fatal(1,"FAIL stopped-clock reset");
        rst_n=1;#30;if(dut.peak_init_done!==0)$fatal(1,"FAIL clear advanced without clock");
        rst_n=0;clock_running=1;repeat(3)@(negedge clk);initialize(128);
        if(checks<9000 || updates<500 || decays<1)$fatal(1,"FAIL insufficient peak coverage %0d/%0d/%0d",checks,updates,decays);
        $display("PASS peak_init_case reverse=%0d comparisons=%0d updates=%0d decays=%0d",REVERSE_SCAN,checks,updates,decays);
        finished=1;
    end
endmodule

module tb_peak_table_init;
    wire forward_done,reverse_done;
    peak_init_case #(.REVERSE_SCAN(0)) forward_case(forward_done);
    peak_init_case #(.REVERSE_SCAN(1)) reverse_case(reverse_done);
    initial begin
        wait(forward_done&&reverse_done);
        $display("PASS tb_peak_table_init sequential_clear_cold_warm_interrupted_stopped_clock");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL peak initialization test timeout");end
endmodule
