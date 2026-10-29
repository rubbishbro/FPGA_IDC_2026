`timescale 1ns/1ps
// I2S is the sample master. Frame toggle -> core sample_tick -> one PCM token/frame.
// A result computed after tick K is captured at K+1 and played at K+2. This gives
// the CDC FIFO a whole frame of margin; FIFO capacity does not set the latency.
// During load/stop/fault, still send a zero token per frame. No panic queue flush.
module i2s_audio_output #(
    parameter int CLK_DIV=4,
    parameter int FIFO_DEPTH=16,
    parameter int PCM_HEADROOM_BITS=3 // Q24 -> Q1.15: >> (9 + headroom)
)(
    input logic clk, audio_clk, rst_n,
    input logic active, in_valid,
    input logic signed [63:0] in_data,
    output logic sample_tick,
    output logic amp_bclk, amp_ws, amp_din,
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
    logic signed [15:0] result_pcm;
    logic wready,rvalid,rready;
    logic [15:0] token, rdata;
    assign token=active ? (in_valid ? pcm16(in_data * 64'sd12) : (pending ? result_pcm : 16'sd0)) : 16'sd0;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin pending<=0;warmup<=0;result_pcm<=0;deadline_miss<=0;overflow<=0;end
        else begin
            if(!active) begin pending<=0;warmup<=0;end
            else if(in_valid) begin
                result_pcm<=pcm16(in_data * 64'sd12);pending<=1;
                if(pending && !sample_tick) overflow<=1; // unexpected duplicate result
            end
            if(sample_tick) begin
                pending<=0;
                if(active && warmup<2) warmup<=warmup+1'b1;
                if(active && warmup==2 && !pending && !in_valid) deadline_miss<=1;
                if(!wready) overflow<=1;
            end
        end
    end
    audio_async_fifo #(.WIDTH(16),.DEPTH(FIFO_DEPTH)) u_fifo(
        .wclk(clk),.rclk(audio_clk),.rst_n(rst_n),
        .wvalid(sample_tick),.wready(wready),.wdata(token),
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
        .in_valid(1'b1),.in_ready(rready),.in_data({16'b0,rvalid ? rdata : 16'd0}),
        .amp_bclk(amp_bclk),.amp_ws(amp_ws),.amp_din(amp_din),
        .underflow_pulse(),.underflow_sticky(),.frame_tick(frame_audio)
    );
endmodule
