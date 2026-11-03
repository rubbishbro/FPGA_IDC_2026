`timescale 1ns/1ps
// Regression fixture for the LUT renderer; not executed by the implementation task.
module tb_pad_led_effects #(parameter int CE_PERIOD=4);
    import clk_rst_pkg::*;
    import pad_driver_pkg::*;
    logic clk=0,rst_n=0;
    always #10 clk=~clk;
    logic [$clog2(CE_PERIOD)-1:0] div=0;
    wire ce=div==CE_PERIOD-1;
    always @(posedge clk) if(!rst_n || ce) div<=0; else div<=div+1'b1;
    clk_rst cr;
    assign cr={clk,ce,rst_n};
    logic [127:0] force_values=0;
    mat4x4 force_map;
    assign force_map=force_values;
    led_param leds;
    wire dat,busy,frame_done;
    pad_led_effects dut(.cr(cr),.force_map(force_map),.led_busy(busy),.led_frame_done(frame_done),.leds(leds));
    led8x8 driver(.cr(cr),.x(leds.x),.y(leds.y),
        .pix(leds.pix),.wr(leds.wr),.dat(dat),.busy(busy),.frame_done(frame_done));

    // Independent clock/publication model: do not use dut.phase_for_hit to
    // calculate its own expected hit colour. Test the default 200Hz profile.
    integer model_ticks=0;
    logic [31:0] model_phase=0;
    logic [15:0] model_frame_phase=0,model_tx_phase=0,model_displayed_phase=0;
    logic model_wr=0;
    always @(posedge clk) begin
        if(!rst_n)begin
            model_ticks<=0;model_phase<=0;model_frame_phase<=0;
            model_tx_phase<=0;model_displayed_phase<=0;model_wr<=0;
        end else begin
            if(ce)begin
                if(model_ticks==12499)begin
                    model_ticks<=0;model_frame_phase<=model_phase[31:16];
                    model_phase<=model_phase+32'd4129776;
                end else model_ticks<=model_ticks+1;
            end
            model_wr<=leds.wr;
            if(model_wr && !leds.wr)model_tx_phase<=model_frame_phase;
            if(frame_done)model_displayed_phase<=model_tx_phase;
        end
    end

    logic [1535:0] expected_bits=0;
    logic [63:0] written=0;
    logic writing=0;
    integer frame_bits=0,frames=0,writes=0;
    time rise_time;
    logic [23:0] received_pixel=0;
    bit frame_has_colour=0;
    integer coloured_wire_frames=0;
    always @(posedge dat) rise_time=$time;
    always @(negedge dat) if(rst_n) begin
        if($time-rise_time!=20*CE_PERIOD && $time-rise_time!=40*CE_PERIOD) $fatal(1,"FAIL LED pulse width");
        if(frame_bits>=1536 || (($time-rise_time==40*CE_PERIOD)!==expected_bits[frame_bits]))
            $fatal(1,"FAIL LED wire data frame=%0d bit=%0d",frames,frame_bits);
        received_pixel={received_pixel[22:0],1'($time-rise_time==40*CE_PERIOD)};
        if(frame_bits%24==23 && (received_pixel[23:16]!=received_pixel[15:8] ||
                                received_pixel[15:8]!=received_pixel[7:0])) frame_has_colour=1;
        frame_bits++;
    end
    always @(negedge clk) begin
        if(!rst_n) begin frame_bits=0; frames=0; written=0; writes=0; writing=0;
            received_pixel=0;frame_has_colour=0;coloured_wire_frames=0;end
        else begin
            if(frame_done) begin
                if(frame_bits!=1536) $fatal(1,"FAIL incomplete frame");
                frames++; frame_bits=0;
                if(frame_has_colour)coloured_wire_frames++;
                frame_has_colour=0;
            end
            if(ce && leds.wr) begin
                if(busy) $fatal(1,"FAIL framebuffer write while TX busy");
                if(!writing) begin written=0; writes=0; writing=1; end
                if(written[{leds.y,leds.x}]) $fatal(1,"FAIL duplicate pixel");
                written[{leds.y,leds.x}]=1; writes++;
                // Protocol order, not the driver's internal storage bit order.
                for(int b=0;b<24;b++)
                    expected_bits[((7-int'(leds.x))*8+(leds.x[0] ? 7-int'(leds.y) : int'(leds.y)))*24+b]=
                        1'(24'(leds.pix) >> (23-b));
            end
            if(!leds.wr && writing) begin
                if(written!=='1 || writes!=64) $fatal(1,"FAIL missing pixel");
                writing=0;
            end
        end
    end
    task automatic clocks(input int n); repeat(n) @(negedge clk); endtask
    task automatic next_frames(input int n);
        int target;
        target=frames+n; wait(frames>=target); clocks(2);
    endtask
    task automatic pressure(input int id,input logic [7:0] value);
        @(negedge clk); force_values[id*8 +:8]=value; clocks(40);
    endtask
    task automatic strike(input int id,input int slot);
        logic [15:0] phase;
        logic [5:0] expected_colour;
        real offset;
        integer offset_word;
        offset=-$sqrt(real'((id/4*2)**2+(id%4*2)**2))/4.2*65536.0;
        offset_word=integer'($floor(offset+0.5));
        phase=(frame_done?model_tx_phase:model_displayed_phase)+16'(offset_word);
        expected_colour=6'(int'(phase[15:8])*56/256);
        pressure(id,160); // Board raw ADC byte40 after the x4 force mapping.
        if(!dut.wave_valid[slot] || dut.wave_ram[slot][3:0]!=4'(id) || dut.wave_ram[slot][9:4]!=expected_colour)
            $fatal(1,"FAIL strike top-left phase/colour lock id=%0d",id);
    endtask
    logic [5:0] locked_colour;
    logic [23:0] old_origin;
    initial begin
        clocks(5); rst_n=1; next_frames(2);
        // Idle is a grayscale spatial wave with substantial brightness contrast.
        begin
            int lo,hi;
            pixel_t p;
            lo=255; hi=0;
            for(int i=0;i<64;i++) begin
                p=dut.framebuffer[i];
                if(p.r!==p.g || p.g!==p.b) $fatal(1,"FAIL background is not grayscale");
                if(int'(p.r.val)<lo) lo=int'(p.r.val);
                if(int'(p.r.val)>hi) hi=int'(p.r.val);
            end
            if(hi-lo<50) $fatal(1,"FAIL background contrast");
        end
        pressure(5,64);
        if(dut.pressed[5] || dut.wave_valid!=0) $fatal(1,"FAIL strict on threshold");
        strike(5,0); locked_colour=dut.wave_ram[0][9:4]; old_origin=dut.wave_ram[0][49:26];
        pressure(5,48); next_frames(10);
        if(!dut.pressed[5] || dut.next_slot!=1 || dut.wave_ram[0][9:4]!=locked_colour)
            $fatal(1,"FAIL hold/hysteresis/colour lifetime");
        // The front takes about 120ms to reach the nearest LED. Check visible
        // colour, not only that an internal wave record was allocated.
        next_frames(30);
        begin
            bit coloured;
            pixel_t p;
            coloured=0;
            for(int i=0;i<64;i++) begin
                p=dut.framebuffer[i];
                if(p.r!==p.g || p.g!==p.b) coloured=1;
            end
            if(!coloured) $fatal(1,"FAIL strike produced no visible coloured wave");
            if(coloured_wire_frames==0)$fatal(1,"FAIL colour never reached serialized LED pins");
        end
        pressure(5,47);
        if(dut.pressed[5] || !dut.wave_valid[0]) $fatal(1,"FAIL release cut off tail");
        strike(5,1);
        if(dut.wave_ram[0][49:26]!=old_origin || !dut.wave_valid[0]) $fatal(1,"FAIL retrigger overwrote tail");
        @(negedge clk); force_values=0; clocks(40);
        @(negedge clk); force_values={16{8'd68}}; clocks(160);
        if(dut.wave_valid!==16'hffff || dut.pending!=0) $fatal(1,"FAIL simultaneous strikes/pool");
        next_frames(3);
        // Every generated output byte remains within the reserved sum budget.
        for(int i=0;i<64;i++) begin
            pixel_t p;
            p=dut.framebuffer[i];
            if(p.r.val>240 || p.g.val>240 || p.b.val>240) $fatal(1,"FAIL colour overflow");
        end
        @(negedge clk); force_values=0;
        wait(dut.wave_valid==0); next_frames(2);
        wait(busy); @(negedge clk); rst_n=0; clocks(2);
        if(dat!==0 || dut.pressed!==0 || dut.wave_valid!==0 || dut.displayed_phase!==0)
            $fatal(1,"FAIL live reset");
        $display("PASS tb_pad_led_effects grayscale_phase_lock_retrigger_16waves_retirement_wire_reset");
        $finish;
    end
    initial begin #(500000000*64'(CE_PERIOD)); $fatal(1,"FAIL LED effects timeout"); end
endmodule
