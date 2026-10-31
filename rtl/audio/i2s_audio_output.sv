`timescale 1ns/1ps
// I2S is the sample master. Frame toggle -> core sample_tick -> one PCM token/frame.
// A result computed after tick K is captured at K+1 and played at K+2. This gives
// the CDC FIFO a whole frame of margin; FIFO capacity does not set the latency.
// During load/stop/fault, still send a zero token per frame. No panic queue flush.
// Stereo processing takes 26 core clocks after frame assembly, inside the same
// whole-frame CDC margin. Paired L/R tokens cannot be torn across clock domains.
module i2s_audio_output #(
    parameter int CLK_DIV=4,
    parameter int FIFO_DEPTH=16,
    parameter int PCM_HEADROOM_BITS=3, // Q24 -> Q1.15: >> (9 + headroom)
    parameter bit STEREO_ENABLE=1'b1,
    parameter bit PT8211_ENABLE=1'b0,
    parameter int ITD_MAX_SAMPLES=4
)(
    input logic clk, audio_clk, rst_n,
    input logic active, in_valid,
    input logic signed [63:0] in_data,
    input logic [5:0] pan_position=6'd16,
    input logic itd_enable=1'b1,
    output logic sample_tick,
    output logic amp_bclk, amp_ws, amp_din,
    output wire dac_bck,dac_ws,dac_din,
    // Sticky diagnostics, all synchronized to clk. Reset clears them.
    output logic deadline_miss, overflow, underflow
);
    initial if (PCM_HEADROOM_BITS<0 || PCM_HEADROOM_BITS>53)
        $error("PCM_HEADROOM_BITS must be 0..53");
    localparam int SHIFT=9+PCM_HEADROOM_BITS;
    function automatic logic signed [15:0] pcm16(input logic signed [63:0] y);
        logic signed [79:0] extended;
        logic [15:0] integer_part;
        logic fits;
        begin
            // Exactly (y + 2**(SHIFT-1)) >>> SHIFT, followed by saturation.
            // Check sign extension before rounding, so the carry chain is only
            // 16 bits. Widening also handles every allowed headroom setting.
            extended=$signed(y);
            integer_part=extended[SHIFT +:16];
            fits=extended[79:SHIFT+15]=={(65-SHIFT){extended[SHIFT+15]}};
            if(!fits)pcm16=y[63]?16'sh8000:16'sh7fff;
            else if(integer_part==16'h7fff && y[SHIFT-1])pcm16=16'sh7fff;
            else pcm16=integer_part+16'(y[SHIFT-1]);
        end
    endfunction
    function automatic logic signed [15:0] spatial_pcm16(input logic signed [83:0] y);
        logic signed [99:0] extended;
        logic [15:0] integer_part;
        logic fits;
        begin
            extended=$signed(y);
            integer_part=extended[SHIFT+18 +:16];
            fits=extended[99:SHIFT+33]=={(67-SHIFT){extended[SHIFT+33]}};
            if(!fits)spatial_pcm16=y[83]?16'sh8000:16'sh7fff;
            else if(integer_part==16'h7fff && y[SHIFT+17])spatial_pcm16=16'sh7fff;
            else spatial_pcm16=integer_part+16'(y[SHIFT+17]);
        end
    endfunction
    (* ASYNC_REG="TRUE" *) logic [1:0] arst_sync;
    always_ff @(posedge audio_clk or negedge rst_n)
        if(!rst_n) arst_sync<=0;
        else arst_sync<={arst_sync[0],1'b1};
    wire arst_n=arst_sync[1];
    logic frame_audio, frame_toggle, frame_seen;
    (* ASYNC_REG="TRUE" *) logic frame_s1,frame_s2;
    always_ff @(posedge audio_clk or negedge arst_n)
        if(!arst_n) frame_toggle<=0;
        else if(frame_audio) frame_toggle<=~frame_toggle;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin frame_s1<=0;frame_s2<=0;frame_seen<=0;end
        else begin frame_s1<=frame_toggle;frame_s2<=frame_s1;frame_seen<=frame_s2;end
    end
    assign sample_tick=frame_s2 ^ frame_seen;

    logic pending;
    // run may become true on the same edge as a frame tick while the router is
    // still leaving S_DONE. Allow that boundary plus the first full compute frame.
    logic [1:0] warmup;
    logic signed [63:0] result_data,frame_data;
    logic wready,rvalid,rready;
    logic [31:0] token,rdata;
    logic token_valid,spatial_busy;
    assign frame_data=active ? (in_valid ? in_data : (pending ? result_data : 64'sd0)) : 64'sd0;
    generate if(STEREO_ENABLE)begin:g_stereo
        logic spatial_valid;
        logic signed [83:0] left_data,right_data;
        stereo_spatializer #(.ITD_MAX_SAMPLES(ITD_MAX_SAMPLES)) u_spatial(
            .clk(clk),.rst_n(rst_n),.sample_valid(sample_tick),.clear(!active),.in_data(frame_data),
            .pan_position(pan_position),.itd_enable(itd_enable),.busy(spatial_busy),.out_valid(spatial_valid),
            .out_left(left_data),.out_right(right_data),.position_q4(),.gain_left_q12(),.gain_right_q12(),
            .delay_left_q6(),.delay_right_q6());
        assign token_valid=spatial_valid;
        assign token={spatial_pcm16(left_data),spatial_pcm16(right_data)};
    end else begin:g_mono_compat
        assign spatial_busy=1'b0;
        assign token_valid=sample_tick;
        assign token={pcm16(frame_data),pcm16(frame_data)};
    end endgenerate
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin pending<=0;warmup<=0;result_data<=0;deadline_miss<=0;overflow<=0;end
        else begin
            if(!active) begin pending<=0;warmup<=0;end
            else if(in_valid) begin
                result_data<=in_data;pending<=1;
                if(pending && !sample_tick) overflow<=1; // unexpected duplicate result
            end
            if(sample_tick) begin
                pending<=0;
                if(active && warmup<2) warmup<=warmup+1'b1;
                if(active && warmup==2 && !pending && !in_valid) deadline_miss<=1;
                if(spatial_busy)overflow<=1;
            end
            if(token_valid && !wready)overflow<=1;
        end
    end
    audio_async_fifo #(.WIDTH(32),.DEPTH(FIFO_DEPTH)) u_fifo(
        .wclk(clk),.rclk(audio_clk),.rst_n(rst_n),
        .wvalid(token_valid),.wready(wready),.wdata(token),
        .rvalid(rvalid),.rready(rready),.rdata(rdata),.wfull(),.rempty()
    );
    // Serializer always runs. Missing startup data and planned silence are zeros.
    // After the first token, an empty FIFO at a frame boundary is a real fault.
    logic started,under_audio;
    always_ff @(posedge audio_clk or negedge arst_n) begin
        if(!arst_n) begin started<=0;under_audio<=0;end
        else if(rready) begin
            if(rvalid) started<=1;
            else if(started) under_audio<=1;
        end
    end
    (* ASYNC_REG="TRUE" *) logic under_s1,under_s2;
    always_ff @(posedge clk or negedge rst_n)
        if(!rst_n) begin under_s1<=0;under_s2<=0;end
        else begin under_s1<=under_audio;under_s2<=under_s1;end
    assign underflow=under_s2;
    i2s_amp_tx #(.CLK_DIV(CLK_DIV)) u_tx(
        .clk(audio_clk),.rst_n(arst_n),.diag_clear(1'b0),
        .in_valid(1'b1),.in_ready(rready),.in_data(rvalid ? rdata : 32'd0),
        .amp_bclk(amp_bclk),.amp_ws(amp_ws),.amp_din(amp_din),
        .underflow_pulse(),.underflow_sticky(),.frame_tick(frame_audio)
    );
    generate if(PT8211_ENABLE)begin:g_pt8211
        wire ready_pt,frame_pt;
        pt8211_tx #(.CLK_DIV(2*CLK_DIV)) u_tx(
            .clk(audio_clk),.rst_n(arst_n),.in_valid(1'b1),.in_ready(ready_pt),
            .in_data(rvalid?rdata:32'd0),.dac_bck(dac_bck),.dac_ws(dac_ws),.dac_din(dac_din),.frame_tick(frame_pt));
        // Both serializers consume the SAME FIFO entry on the SAME audio edge.
        // synthesis translate_off
        always @(negedge audio_clk)if(arst_n && (ready_pt!==rready || frame_pt!==frame_audio))
            $fatal(1,"FAIL PT8211/I2S frame alignment");
        // synthesis translate_on
    end else begin:g_no_pt8211
        assign {dac_bck,dac_ws,dac_din}=3'b000;
    end endgenerate
endmodule
