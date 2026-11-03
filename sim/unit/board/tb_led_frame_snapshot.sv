`timescale 1ns/1ps
// Targeted test for the per-frame snapshot and the shared radius subtraction
// introduced with the pixel-RAM/radius rework.
//
// Contracts checked:
//   1. frame_travel is latched once per frame from the travel_acc value that
//      existed at the frame tick, and is constant for the whole frame; the live
//      travel_acc keeps advancing, so a renderer that used it would fail.
//   2. radius == frame_travel - snap_birth_travel[wave_idx] at every wave slot
//      visit, i.e. one subtraction over the frame snapshot instead of 16 live
//      subtractions.
//   3. snap_* and snap_valid are immutable from the pixel address state until
//      the fill completes; a strike committed mid-frame changes wave_* but not
//      the frame being rendered.
//   4. The framebuffer prefetch delivers framebuffer[fill_idx] on each accepted
//      fill tick with one enable per core clock (tightest spacing).
//   5. A wave retired by the age clock after the snapshot still renders for that
//      whole frame and disappears from the next frame's snapshot.
module tb_led_frame_snapshot #(parameter int CE_PERIOD=1);
    import clk_rst_pkg::*;
    import pad_driver_pkg::*;

    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    int div=0;
    wire ce=div>=CE_PERIOD-1;
    always @(posedge clk) if(!rst_n||ce) div<=0; else div<=div+1;

    clk_rst cr;
    assign cr={clk,ce,rst_n};

    logic [127:0] force_values=0;
    mat4x4 force_map;
    assign force_map=force_values;
    led_param leds;
    wire dat,busy,frame_done;
    pad_led_effects dut(.cr(cr),.force_map(force_map),.led_busy(busy),
        .led_frame_done(frame_done),.leds(leds));
    led8x8 driver(.cr(cr),.x(leds.x),.y(leds.y),.pix(leds.pix),.wr(leds.wr),
        .dat(dat),.busy(busy),.frame_done(frame_done));

    // Capture the pre-edge travel_acc that the snapshot must latch.
    logic [23:0] travel_at_tick=0;
    always @(posedge clk)
        if(rst_n && dut.frame_tick && dut.state==dut.R_IDLE) travel_at_tick=dut.travel_acc;

    logic [15:0] cap_valid;
    logic [3:0]  cap_pad [0:15];
    logic [5:0]  cap_colour [0:15],cap_age [0:15];
    logic [23:0] cap_birth [0:15],cap_travel;
    int prev_state=-1,frame_no=0;
    int radius_checks=0,fill_checks=0,immutable_checks=0,frame_checks=0;
    bit in_frame=0;
    bit cur_sv0=0,cur_wv0_dropped=0;
    bit mid_committed=0,boundary_seen=0;
    int mid_slot=-1;
    // A force right-hand side that is an expression is treated as a continuous
    // assignment by the simulator, so the boundary age is captured in a stable
    // variable first; otherwise the forced birth would follow age_clock.
    logic [15:0] forced_birth_age=0;

    always @(negedge clk) begin
        if(!rst_n) begin
            in_frame=0;prev_state=-1;frame_no=0;
            cur_sv0=0;cur_wv0_dropped=0;
        end else begin
            // Frame boundaries: the snapshot is written on the frame tick edge,
            // so the first render state is the first edge where it must hold.
            if(dut.state==dut.R_PIXEL_ADDR && prev_state==dut.R_IDLE) begin
                if(frame_no>0) begin
                    // A wave retired during the frame that just ended must not be
                    // snapshotted again, and a strike committed during it must.
                    if(cur_sv0 && cur_wv0_dropped) begin
                        boundary_seen=1;
                        if(dut.snap_valid[0])
                            $fatal(1,"FAIL retired wave snapshotted in frame %0d",frame_no+1);
                    end
                    if(mid_committed && !dut.snap_valid[mid_slot])
                        $fatal(1,"FAIL mid-frame strike missing from snapshot slot=%0d",mid_slot);
                end
                cap_valid=dut.snap_valid;
                cap_travel=dut.frame_travel;
                for(int i=0;i<16;i++) begin
                    cap_pad[i]=dut.snap_pad[i];
                    cap_colour[i]=dut.snap_colour[i];
                    cap_age[i]=dut.snap_age[i];
                    cap_birth[i]=dut.snap_birth_travel[i];
                end
                in_frame=1;
                frame_no++;frame_checks++;
                if(dut.frame_travel!==travel_at_tick)
                    $fatal(1,"FAIL frame_travel %06x != travel_acc at frame tick %06x",
                        dut.frame_travel,travel_at_tick);
                // The snapshot must not store a wave that is already expired.
                if(dut.snap_valid[0] &&
                   16'(dut.age_clock-16'd1-dut.wave_birth_age[0])>=16'd64)
                    $fatal(1,"FAIL expired wave snapshotted");
                cur_sv0=dut.snap_valid[0];
                cur_wv0_dropped=0;
            end

            if(dut.state==dut.R_IDLE || dut.state==dut.R_BOOT_FILL) in_frame=0;

            if(in_frame) begin
                // Snapshot immutability for the whole render and fill window.
                if(dut.snap_valid!==cap_valid) $fatal(1,"FAIL snap_valid changed in frame %0d",frame_no);
                for(int i=0;i<16;i++) begin
                    if(dut.snap_pad[i]!==cap_pad[i] || dut.snap_colour[i]!==cap_colour[i] ||
                       dut.snap_age[i]!==cap_age[i] || dut.snap_birth_travel[i]!==cap_birth[i])
                        $fatal(1,"FAIL snapshot slot %0d changed in frame %0d",i,frame_no);
                end
                immutable_checks++;
                // The live counter advances past the snapshot; the renderer must
                // not follow it.
                if(dut.travel_acc!==cap_travel+24'd1966)
                    $fatal(1,"FAIL travel_acc not exactly one step ahead of frame_travel");
                if(dut.state==dut.R_DISTANCE) begin
                    if(dut.radius!==(dut.frame_travel-dut.snap_birth_travel[dut.wave_idx]))
                        $fatal(1,"FAIL radius %06x != frame_travel-birth %06x wave=%0d",
                            dut.radius,dut.frame_travel-dut.snap_birth_travel[dut.wave_idx],dut.wave_idx);
                    radius_checks++;
                end
                if(dut.state==dut.R_FILL && ce) begin
                    if(leds.pix!==dut.framebuffer[dut.fill_idx])
                        $fatal(1,"FAIL prefetch pixel %0d got %06x want %06x",
                            dut.fill_idx,leds.pix,dut.framebuffer[dut.fill_idx]);
                    if(leds.x!==dut.fill_idx[2:0] || leds.y!==dut.fill_idx[5:3])
                        $fatal(1,"FAIL fill address mapping");
                    fill_checks++;
                end
                if(!dut.wave_valid[0]) cur_wv0_dropped=1;
            end
            prev_state=dut.state;
        end
    end

    task automatic strike(input int id,input int hold);
        force_values[id*8 +:8]=8'd160;
        repeat(hold) @(negedge clk);
        force_values[id*8 +:8]=8'd0;
    endtask

    task automatic wait_frames(input int n);
        int target;
        target=frame_no+n;
        wait(frame_no>=target);
        @(negedge clk);
    endtask

    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        wait_frames(2);
        // Wave 0: normal strike, then push its birth age to the boundary so the
        // retirement path is reached in a few frames instead of 640. This is a
        // white-box shortcut; the age counter itself still runs for real.
        strike(0,6);
        wait(dut.wave_valid[0]);
        @(negedge clk);
        forced_birth_age=dut.age_clock-16'd63;
        force dut.wave_birth_age[0]=forced_birth_age;
        wait_frames(1);
        // Wave 1: strike in the middle of a frame; it must not leak into the
        // frame being rendered but must appear in the next snapshot.
        wait(dut.state==dut.R_PIXEL_ADDR && dut.pixel_idx==6'd12);
        mid_slot=int'(dut.next_slot);
        strike(1,8);
        wait(dut.wave_valid[mid_slot]);
        mid_committed=1;
        if(dut.snap_valid[mid_slot]) $fatal(1,"FAIL mid-frame strike leaked into current snapshot");
        wait_frames(2);
        if(!dut.snap_valid[mid_slot]) $fatal(1,"FAIL mid-frame strike missing from snapshot");
        // Wait for wave 0 to retire, then confirm the boundary frame was seen.
        wait(!dut.wave_valid[0]);
        wait_frames(2);
        release dut.wave_birth_age[0];
        if(!boundary_seen) $fatal(1,"FAIL retirement boundary frame not observed");
        if(radius_checks<16) $fatal(1,"FAIL too few radius checks %0d",radius_checks);
        if(fill_checks<64) $fatal(1,"FAIL too few fill checks %0d",fill_checks);
        if(immutable_checks<64) $fatal(1,"FAIL too few immutability checks %0d",immutable_checks);
        if(frame_checks<5) $fatal(1,"FAIL too few frames %0d",frame_checks);
        $display("PASS tb_led_frame_snapshot frames=%0d radius_checks=%0d fill_checks=%0d immutable_checks=%0d ce_period=%0d",
            frame_checks,radius_checks,fill_checks,immutable_checks,CE_PERIOD);
        $finish;
    end

    initial begin #20000000;$fatal(1,"FAIL LED snapshot timeout");end
endmodule
