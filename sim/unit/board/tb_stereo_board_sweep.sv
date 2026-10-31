`timescale 1ns/1ps
// Verify optional board demonstration control uses the actual I2S frame clock,
// reaches both endpoints and is passed to the shared MIDI/PAD audio consumer.
module tb_stereo_board_sweep;
    logic clk=0,aclk=0,pclk=0,rst_n=0;
    always #10 clk=~clk;
    always #40 aclk=~aclk;
    always #15 pclk=~pclk;
    tri [3:0] dq;
    wire bclk,ws,din;
    logic [2:0] diagnostics;
    integer frames=0,expected=16,backwards=0,lo=16,hi=16;
    instrument_system #(.STEREO_AUTO_SWEEP(1),.SWEEP_HOLD_FRAMES(2)) dut(
        .clk_core(clk),.clk_audio(aclk),.clk_pix(pclk),.rst_n(rst_n),.key0(1'b1),.key1(1'b1),
        .uart_rx(2'b11),.session_restart(2'b0),.bt_state(1'b0),.pan_position(6'd63),.itd_enable(1'b1),
        .uart_tx(),.pad_row(),.pad_ch(),.led_dat(),.flash_cs_n(),.flash_sck(),.flash_dq(dq),
        .amp_bclk(bclk),.amp_ws(ws),.amp_din(din),.amp_sd(),.lcd_clk(),.lcd_en(),.lcd_r(),.lcd_g(),.lcd_b(),
        .sample_valid(),.sample_value(),.audio_diagnostics(diagnostics));
    defparam dut.u_pad.input_inst.adc_inst.CHECK_MUX=0;
    integer decoded,nz;
    i2s_scoreboard wirecheck(clk,dut.core_n,bclk,ws,din,dut.spatial_frame_tick,16'd0,decoded,nz);
    always @(posedge clk)if(dut.core_n && dut.spatial_frame_tick)begin
        frames++;
        if(frames%2==0)begin
            if(expected==32)begin expected=31;backwards=1;end
            else if(expected==0)begin expected=1;backwards=0;end
            else expected=backwards?expected-1:expected+1;
        end
    end
    always @(negedge clk)if(dut.core_n)begin
        if(dut.spatial_pan!==6'(expected) || dut.u_sound.pan_position!==6'(expected))
            $fatal(1,"FAIL board sweep frame=%d position=%d expected=%d",frames,dut.spatial_pan,expected);
        if(expected<lo)lo=expected;
        if(expected>hi)hi=expected;
        if(diagnostics!=0)$fatal(1,"FAIL board sweep audio diagnostics %b",diagnostics);
    end
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        wait(frames==200);@(negedge clk);
        if(lo!=0 || hi!=32 || decoded<190 || nz!=0)$fatal(1,"FAIL board sweep coverage");
        $display("PASS tb_stereo_board_sweep frames=%0d range=%0d..%0d decoded=%0d I2S-clocked bounce/consumer/silence",frames,lo,hi,decoded);
        $finish;
    end
    initial begin #10000000;$fatal(1,"FAIL board sweep timeout");end
endmodule
