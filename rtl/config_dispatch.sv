`timescale 1ns/1ps
// 配置端点：显示等待真实帧头确认，校准等待真实完成，其余交给显式后端。
module config_dispatch #(
    parameter integer CAL_TIMEOUT_MS=2000,
    parameter logic[19:0] LOCAL_SUPPORTED=config_pkg::LOCAL_MASK
)(
    input logic clk,rst_n,tick_ms,
    input logic req_valid,
    output logic req_ready,
    input config_pkg::cfg_request_t request,
    input logic request_source,
    output logic rsp_valid,
    input logic rsp_ready,
    output config_pkg::cfg_response_t response,
    output logic response_source,
    input logic [19:0] backend_supported,
    output logic backend_valid,
    input logic backend_ready,
    output config_pkg::cfg_request_t backend_request,
    output logic backend_source,
    input logic backend_rsp_valid,
    output logic backend_rsp_ready,
    input config_pkg::cfg_response_t backend_response,
    output config_pkg::cfg_values_t active_values,
    output config_pkg::display_config_t render_config,
    output logic [15:0] render_epoch,
    input logic display_done,
    input logic [15:0] display_done_epoch,
    output logic joy_recalibrate,
    input logic joy_calibrated,joy_stale
);
    import config_pkg::*;
    typedef enum logic[2:0] {IDLE,DISPLAY,BACKEND_SEND,BACKEND_WAIT,CAL_START,CAL_WAIT,REPLY} state_t;
    state_t state;
    cfg_request_t pending;
    integer index;
    logic [$clog2(CAL_TIMEOUT_MS+1)-1:0] cal_age;
    wire [19:0] supported=backend_supported|LOCAL_SUPPORTED;
    assign req_ready=(state==IDLE)&&rst_n;
    assign rsp_valid=(state==REPLY)&&rst_n;
    assign backend_valid=(state==BACKEND_SEND)&&rst_n;
    assign backend_request=pending;
    assign backend_source=response_source;
    assign backend_rsp_ready=(state==BACKEND_WAIT)&&rst_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=IDLE;pending<='0;response<='0;response_source<=0;
            active_values<=cfg_defaults();render_config<=display_defaults();render_epoch<=0;
            index<=0;cal_age<=0;joy_recalibrate<=0;
        end else begin
            joy_recalibrate<=0;
            case(state)
                IDLE:if(req_valid)begin
                    pending<=request;response_source<=request_source;
                    response.tag<=request.tag;response.id<=request.id;
                    response.applied_value<=0;response.result<=CFG_OK;
                    index<=cfg_index(request.id);
                    if(cfg_index(request.id)<0)begin response.result<=CFG_UNSUPPORTED;state<=REPLY;end
                    else if(!supported[cfg_index(request.id)])begin response.result<=CFG_UNSUPPORTED;state<=REPLY;end
                    else if(!cfg_value_valid(cfg_index(request.id),request.value))begin
                        response.result<=CFG_OUT_OF_RANGE;state<=REPLY;
                    end else if(request.id==16'h0400 && !style_supported(request.value[15:0]))begin
                        response.result<=CFG_UNSUPPORTED;state<=REPLY;
                    end else if(DISPLAY_MASK[cfg_index(request.id)])begin
                        case(request.id)
                            16'h0400:render_config.style_id<=request.value[15:0];
                            16'h0401:render_config.theme<=request.value[0];
                            16'h0402:render_config.peak<=request.value[0];
                            16'h0403:render_config.smooth<=request.value[0];
                            16'h0404:render_config.grid<=request.value[0];
                            default:;
                        endcase
                        render_epoch<=render_epoch+1'b1;state<=DISPLAY;
                    end else if(request.id==16'h8000)begin
                        joy_recalibrate<=1;cal_age<=0;state<=CAL_START;
                    end else state<=BACKEND_SEND;
                end
                DISPLAY:if(display_done && display_done_epoch==render_epoch)begin
                    active_values[index]<=pending.value;response.applied_value<=pending.value;state<=REPLY;
                end
                BACKEND_SEND:if(backend_ready)state<=BACKEND_WAIT;
                BACKEND_WAIT:if(backend_rsp_valid)begin
                    if(backend_response.tag!=pending.tag || backend_response.id!=pending.id)begin
                        response.result<=CFG_FAILED;
                    end else if(backend_response.result==CFG_OK && pending.id<16'h8000 &&
                                !cfg_value_valid(index,backend_response.applied_value))begin
                        response.result<=CFG_FAILED;
                    end else begin
                        response.result<=backend_response.result;
                        response.applied_value<=backend_response.applied_value;
                        if(backend_response.result==CFG_OK && pending.id<16'h8000)
                            active_values[index]<=backend_response.applied_value;
                    end
                    state<=REPLY;
                end
                CAL_START,CAL_WAIT:begin
                    if(state==CAL_START && !joy_calibrated)state<=CAL_WAIT;
                    if(state==CAL_WAIT && joy_calibrated && !joy_stale)state<=REPLY;
                    else if(tick_ms)begin
                        if(cal_age==CAL_TIMEOUT_MS-1)begin response.result<=CFG_FAILED;state<=REPLY;end
                        else cal_age<=cal_age+1'b1;
                    end
                end
                REPLY:if(rsp_ready)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
