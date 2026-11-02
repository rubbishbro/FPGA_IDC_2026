`timescale 1ns/1ps
// Targeted test for the pixel-addressed synchronous RAM read in led8x8.
//
// The implementation stores one 24-bit pixel per RAM word, increments
// tx_pixel/tx_bit at each bit boundary, and samples the wire bit at the
// start-of-bit edge. pixel_q follows the address one core clock later, and a
// boundary that follows a '1' bit updates the address only one enable before
// the next sampled bit. The module contract is therefore at least two core
// clocks per clk_en (the board generates pad_tick once per 20 core clocks;
// consecutive enables are not a supported input). This test sweeps the two
// fastest legal spacings plus the slower ones, checks every wire bit against
// the written image, and checks pixel_q itself at each sampled bit, which the
// previous "prefetch vs direct" test could no longer do once both settings
// became the same hardware.
module tb_led_pixel_ram;
    import clk_rst_pkg::*;
    import pad_driver_pkg::*;

    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    int ce_period=1;
    int div=0;
    wire ce=div>=ce_period-1;
    always @(posedge clk) if(!rst_n||ce) div<=0; else div<=div+1;

    clk_rst cr;
    assign cr={clk,ce,rst_n};

    logic [2:0] x=0,y=0;
    pixel_t pixel='0;
    logic wr=1;
    wire dat,busy,frame_done;
    led8x8 dut(.cr(cr),.x(x),.y(y),.pix(pixel),.wr(wr),
        .dat(dat),.busy(busy),.frame_done(frame_done));

    logic [23:0] expected [0:63];
    logic [23:0] received=0;
    integer bit_count=0,pixel_count=0,frames=0,total_pixels=0;
    integer read_checks=0,write_blocks=0,width_checks=0;
    time rise_time;

    // Sampled-bit check: at the edge that starts a bit, the registered read
    // data must already belong to the pixel being shifted.
    always @(posedge dat) if(rst_n) begin
        rise_time=$time;
        if(dut.idx<1536 && dut.pixel_q!==dut.pixel_ram[dut.tx_pixel])
            $fatal(1,"FAIL stale pixel read pixel=%0d q=%06x ram=%06x",
                dut.tx_pixel,dut.pixel_q,dut.pixel_ram[dut.tx_pixel]);
        read_checks++;
    end

    always @(negedge dat) if(rst_n) begin
        width_checks++;
        if($time-rise_time!=10*ce_period && $time-rise_time!=20*ce_period)
            $fatal(1,"FAIL LED pulse width %0t for ce_period=%0d",$time-rise_time,ce_period);
        received={received[22:0],($time-rise_time==20*ce_period)};
        bit_count++;
        if(bit_count==24) begin
            if(pixel_count>=64 || received!==expected[pixel_count])
                $fatal(1,"FAIL LED GRB/MSB frame=%0d pixel=%0d expected=%06x got=%06x",
                    frames,pixel_count,expected[pixel_count],received);
            pixel_count++;total_pixels++;bit_count=0;
        end
    end

    // Writes are only allowed outside S_TX; the RAM write port must ignore the
    // transmitter window instead of corrupting the image being shifted out.
    task automatic try_write_during_tx;
        pixel_t keep_pixel;
        logic [23:0] keep_word;
        keep_word=dut.pixel_ram[0];
        keep_pixel=pixel;
        wr=1;x=3'd0;y=3'd0;pixel=24'hff_ff_ff;
        repeat(3) @(negedge clk);
        if(dut.pixel_ram[0]!==keep_word)
            $fatal(1,"FAIL write during S_TX corrupted pixel RAM");
        pixel=keep_pixel;wr=0;write_blocks++;
    endtask

    always @(negedge clk) if(rst_n && frame_done) begin
        if(pixel_count!=64 || bit_count!=0)
            $fatal(1,"FAIL incomplete LED frame");
        frames++;pixel_count=0;
    end

    task automatic send_frame(input int frame_id);
        wr=1;
        for(int cell_id=0;cell_id<64;cell_id++) begin
            @(negedge clk);while(!ce) @(negedge clk);
            x=3'(cell_id/8);y=3'(cell_id%8);
            // Mix equal-byte and independent-byte pixels so a one-pixel read
            // slip cannot hide behind repeated colour data.
            pixel.g.val=8'(frame_id*37+cell_id*3+1);
            pixel.r.val=8'(frame_id*11+cell_id*5+64);
            pixel.b.val=8'(cell_id*7+128);
            expected[(cell_id/8)*8+((cell_id/8)%2 ? 7-cell_id%8 : cell_id%8)]=
                {pixel.g.val,pixel.r.val,pixel.b.val};
        end
        @(negedge clk);while(!ce) @(negedge clk);
        @(negedge clk);wr=0;
        wait(frames==frame_id+1);
        @(negedge clk);
    endtask

    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        repeat(2) @(negedge clk);
        for(int period=2;period<=5;period++) begin
            ce_period=period;div=0;
            send_frame(2*(period-2));
            send_frame(2*(period-2)+1);
        end
        // One extra frame to attempt a write inside the transmit window.
        ce_period=2;div=0;
        wr=1;
        for(int cell_id=0;cell_id<64;cell_id++) begin
            @(negedge clk);while(!ce) @(negedge clk);
            x=3'(cell_id/8);y=3'(cell_id%8);
            pixel.g.val=8'(cell_id*3+2);pixel.r.val=8'(cell_id*5+7);
            pixel.b.val=8'(cell_id*7+9);
            expected[(cell_id/8)*8+((cell_id/8)%2 ? 7-cell_id%8 : cell_id%8)]=
                {pixel.g.val,pixel.r.val,pixel.b.val};
        end
        @(negedge clk);while(!ce) @(negedge clk);
        @(negedge clk);wr=0;
        wait(dut.state==dut.S_TX && dut.idx>120);
        try_write_during_tx();
        wait(frames==9);
        @(negedge clk);
        if(total_pixels!=576) $fatal(1,"FAIL missing decoded pixels %0d",total_pixels);
        if(width_checks!=576*24) $fatal(1,"FAIL missing wire bits %0d",width_checks);
        if(read_checks!=width_checks)
            $fatal(1,"FAIL sampled-bit checks %0d != wire bits %0d",read_checks,width_checks);
        if(write_blocks!=1) $fatal(1,"FAIL transmit-window write not exercised");
        $display("PASS tb_led_pixel_ram frames=9 pixels=%0d bits=%0d ce_periods=2..5 sampled_read_checks=%0d",
            total_pixels,width_checks,read_checks);
        $finish;
    end

    initial begin #20000000;$fatal(1,"FAIL LED pixel RAM timeout");end
endmodule
