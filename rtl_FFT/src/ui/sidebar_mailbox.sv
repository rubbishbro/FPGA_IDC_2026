`timescale 1ns/1ps
// 共用异步复位；两域必须一起复位。在途整包保持，目标只在 ready（帧头）接受。
module sidebar_mailbox #(parameter integer WIDTH=32)(
    input logic rst_n,src_clk,dst_clk,
    input logic src_valid,
    output logic src_ready,
    input logic[WIDTH-1:0] src_data,
    output logic src_done,
    output logic[WIDTH-1:0] src_done_data,
    output logic dst_valid,
    input logic dst_ready,
    output logic[WIDTH-1:0] dst_data
);
    (* ASYNC_REG="TRUE" *) logic[1:0] src_reset,dst_reset;
    always_ff @(posedge src_clk or negedge rst_n)
        if(!rst_n)src_reset<=0;else src_reset<={src_reset[0],1'b1};
    always_ff @(posedge dst_clk or negedge rst_n)
        if(!rst_n)dst_reset<=0;else dst_reset<={dst_reset[0],1'b1};
    wire src_n=src_reset[1],dst_n=dst_reset[1];
    logic request_toggle,ack_toggle,busy;
    logic[WIDTH-1:0] held_data;
    (* ASYNC_REG="TRUE" *) logic ack_meta,ack_sync,req_meta,req_sync;
    always_ff @(posedge src_clk or negedge src_n)begin
        if(!src_n)begin ack_meta<=0;ack_sync<=0;end
        else begin ack_meta<=ack_toggle;ack_sync<=ack_meta;end
    end
    always_ff @(posedge dst_clk or negedge dst_n)begin
        if(!dst_n)begin req_meta<=0;req_sync<=0;end
        else begin req_meta<=request_toggle;req_sync<=req_meta;end
    end
    assign src_ready=src_reset[1]&&!busy;
    assign dst_valid=dst_reset[1]&&(req_sync!=ack_toggle);
    assign dst_data=held_data;
    // Entire payload is captured before request_toggle changes. Consumers must
    // qualify dst_data/src_done_data with dst_valid/src_done respectively.
    // Keep data stable while busy; a shared reset cancels the handshake only.
    always_ff @(posedge src_clk)begin
        if(src_n)begin
            if(busy && ack_sync==request_toggle)src_done_data<=held_data;
            else if(src_valid&&src_ready)held_data<=src_data;
        end
    end
    always_ff @(posedge src_clk or negedge src_n)begin
        if(!src_n)begin request_toggle<=0;busy<=0;src_done<=0;end
        else begin
            src_done<=0;
            if(busy && ack_sync==request_toggle)begin
                busy<=0;src_done<=1;
            end else if(src_valid&&src_ready)begin
                request_toggle<=!request_toggle;busy<=1;
            end
        end
    end
    always_ff @(posedge dst_clk or negedge dst_n)begin
        if(!dst_n)ack_toggle<=0;
        else if(dst_valid&&dst_ready)ack_toggle<=req_sync;
    end
endmodule
