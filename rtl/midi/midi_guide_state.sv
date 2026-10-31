`timescale 1ns/1ps
// Display-only MIDI consumer. No voice ownership, DSP gate or sustain dependency.
// event_valid/ready is a real FIFO pop; cleanup wins over an event on the same edge.
module midi_guide_state #(
    parameter integer SLOTS=16, HOLD_MS=80
)(
    input logic clk,rst_n,tick_ms,clear,source_id,
    input logic event_valid,
    output wire event_ready,
    input logic [31:0] event_data,
    input logic [SLOTS*7-1:0] note_map,
    input logic [1:0] source_cleanup_req,
    output logic [1:0] source_cleanup_done,
    output wire idle,
    output logic [SLOTS-1:0] target,glow,
    output logic [31:0] outside_count,
    output logic [6:0] last_outside
);
    localparam integer CW=(HOLD_MS<2)?1:$clog2(HOLD_MS+1);
    logic [SLOTS-1:0][CW-1:0] hold_count;
    wire [3:0] kind=event_data[31:28];
    wire [6:0] note=event_data[23:17],velocity=event_data[16:10];
    wire on_event=kind==1 && velocity!=0;
    wire off_event=kind==0 || (kind==1 && velocity==0);
    logic [SLOTS-1:0] match_note;
    assign event_ready=rst_n && !clear && !source_cleanup_req[source_id];
    assign idle=rst_n; // every accepted event commits completely on that edge
    always_comb begin
        for(integer i=0;i<SLOTS;i++)begin
            match_note[i]=note_map[i*7 +:7]==note;
            glow[i]=hold_count[i]!=0;
        end
    end
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            target<='0;hold_count<='0;outside_count<=0;last_outside<=0;
            source_cleanup_done<=0;
        end else begin
            source_cleanup_done<=source_cleanup_req;
            if(clear || source_cleanup_req[source_id])begin
                target<='0;hold_count<='0;
                if(clear)begin outside_count<=0;last_outside<=0;end
            end else begin
                if(tick_ms)for(integer i=0;i<SLOTS;i++)
                    if(hold_count[i]!=0)hold_count[i]<=hold_count[i]-1'b1;
                if(event_valid && event_ready)begin
                    if(on_event)begin
                        target<=target | match_note;
                        for(integer i=0;i<SLOTS;i++)if(match_note[i])hold_count[i]<=CW'(HOLD_MS);
                        if(!( |match_note))begin
                            if(outside_count!=32'hffffffff)outside_count<=outside_count+1'b1;
                            last_outside<=note;
                        end
                    end else if(off_event)target<=target & ~match_note;
                    else if(kind==2 && (note==120 || note==123) && velocity==0)begin
                        target<='0;hold_count<='0;
                    end
                    // CC64 intentionally does not turn a released target into a held key.
                end
            end
        end
    end
endmodule
