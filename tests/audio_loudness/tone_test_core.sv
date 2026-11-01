`timescale 1ns/1ps
module tone_test_core #(
    parameter bit USE_PROJECT_TX=0,
    parameter int DEBOUNCE_CYCLES=1_000_000
)(
    input wire clk,rst_n,key0,key1,
    output logic amp_bclk,amp_ws,amp_din,amp_sd,
    output logic dac_bck,dac_ws,dac_din,dac_pa_en
);
    // All logic uses the board's 50MHz input; no PLL, synth, FIFO or Q24 gain.
    (* ASYNC_REG="TRUE" *) logic [1:0] reset_sync;
    (* ASYNC_REG="TRUE" *) logic [1:0] key_meta,key_sync;
    wire reset_n=reset_sync[1];
    always_ff @(posedge clk or negedge rst_n)
        if(!rst_n)reset_sync<=0;else reset_sync<={reset_sync[0],1'b1};
    always_ff @(posedge clk or negedge reset_n)
        if(!reset_n)begin key_meta<=2'b11;key_sync<=2'b11;end
        else begin key_meta<={key1,key0};key_sync<=key_meta;end
    localparam int CW=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
    logic [1:0] stable;
    logic [1:0] pressed;
    for(genvar k=0;k<2;k++)begin:g_key
        logic [CW-1:0] count;
        always_ff @(posedge clk or negedge reset_n)begin
            if(!reset_n)begin stable[k]<=1;count<=0;pressed[k]<=0;end
            else begin
                pressed[k]<=0;
                if(key_sync[k]==stable[k])count<=0;
                else if(count==DEBOUNCE_CYCLES-1)begin
                    stable[k]<=key_sync[k];count<=0;pressed[k]<=!key_sync[k];
                end else count<=count+1'b1;
            end
        end
    end
    logic [1:0] level_sel,channel_sel;
    logic [6:0] tone_phase;
    wire frame_tick;
    logic signed [15:0] amplitude,square_sample;
    wire [31:0] pcm_pair={channel_sel==2 ? 16'd0 : square_sample,
                          channel_sel==1 ? 16'd0 : square_sample};
    always_comb begin
        case(level_sel)
            0:amplitude=16'sd4096;
            1:amplitude=16'sd8192;
            2:amplitude=16'sd16384;
            default:amplitude=16'sd32767;
        endcase
        square_sample=tone_phase<48 ? amplitude : -amplitude;
    end
    always_ff @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin level_sel<=2;channel_sel<=0;tone_phase<=0;end
        else begin
            if(pressed[0])level_sel<=level_sel+1'b1;
            if(pressed[1])channel_sel<=channel_sel==2 ? 2'd0 : channel_sel+1'b1;
            if(frame_tick)tone_phase<=tone_phase==95 ? 7'd0 : tone_phase+1'b1;
        end
    end
    // One common 50MHz output register stage on all serial pins. Preserves
    // BCLK/WS/DIN alignment and allows Gowin output-register placement.
    wire serial_bclk,serial_ws,serial_din,serial_db,serial_dw,serial_dd;
    always_ff @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin
            {amp_bclk,amp_ws,amp_din,dac_bck,dac_ws,dac_din}<=0;
            amp_sd<=0;dac_pa_en<=0;
        end else begin
            {amp_bclk,amp_ws,amp_din,dac_bck,dac_ws,dac_din}<=
                {serial_bclk,serial_ws,serial_din,serial_db,serial_dw,serial_dd};
            amp_sd<=1;dac_pa_en<=1;
        end
    end
    generate if(USE_PROJECT_TX)begin:g_project
        // Direct signed PCM16 into the EXACT production serial encoders.
        i2s_amp_tx #(.CLK_DIV(16)) u_i2s(
            .clk(clk),.rst_n(reset_n),.diag_clear(1'b0),.in_valid(1'b1),.in_data(pcm_pair),
            .in_ready(),.amp_bclk(serial_bclk),.amp_ws(serial_ws),.amp_din(serial_din),
            .underflow_pulse(),.underflow_sticky(),.frame_tick(frame_tick));
        pt8211_tx #(.CLK_DIV(32)) u_pt(
            .clk(clk),.rst_n(reset_n),.in_valid(1'b1),.in_data(pcm_pair),.in_ready(),
            .dac_bck(serial_db),.dac_ws(serial_dw),.dac_din(serial_dd),.frame_tick());
    end else begin:g_reference
        reference_audio_tx u_tx(.clk(clk),.rst_n(reset_n),.pcm_pair(pcm_pair),
            .amp_bclk(serial_bclk),.amp_ws(serial_ws),.amp_din(serial_din),
            .dac_bck(serial_db),.dac_ws(serial_dw),.dac_din(serial_dd),.frame_tick(frame_tick));
    end endgenerate
endmodule
