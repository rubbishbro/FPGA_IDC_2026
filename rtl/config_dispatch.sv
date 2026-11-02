`timescale 1ns/1ps
// 配置端点：显示等待真实帧头确认，校准等待真实完成，其余交给显式后端。
module config_dispatch #(
    parameter integer CAL_TIMEOUT_MS=2000,
    parameter logic[config_pkg::CFG_COUNT-1:0] LOCAL_SUPPORTED=config_pkg::LOCAL_MASK,
    parameter bit AUDIO_BACKEND=1'b0
)(
    input logic clk,rst_n,tick_ms,
    input logic [5:0] initial_pan=6'd16,
    input logic req_valid,
    output logic req_ready,
    input config_pkg::cfg_request_t request,
    input logic request_source,
    output logic rsp_valid,
    input logic rsp_ready,
    output config_pkg::cfg_response_t response,
    output logic response_source,
    input logic [config_pkg::CFG_COUNT-1:0] backend_supported,
    output logic backend_valid,
    input logic backend_ready,
    output config_pkg::cfg_request_t backend_request,
    output logic backend_source,
    input logic backend_rsp_valid,
    output logic backend_rsp_ready,
    input config_pkg::cfg_response_t backend_response,
    input logic backend_audio_valid,
    input config_pkg::audio_config_t backend_audio_state,
    output config_pkg::cfg_values_t active_values,
    output config_pkg::display_config_t render_config,
    output logic [15:0] render_epoch,
    input logic display_done,
    input logic [15:0] display_done_epoch,
    output logic joy_recalibrate,
    input logic joy_calibrated,joy_stale
);
    import config_pkg::*;
    typedef enum logic[3:0] {IDLE,VALIDATE,DISPLAY,BACKEND_SEND,BACKEND_WAIT,BACKEND_CHECK,BACKEND_APPLY,CAL_START,CAL_WAIT,REPLY} state_t;
    state_t state;
    cfg_request_t pending;
    integer index;
    logic [$clog2(CAL_TIMEOUT_MS+1)-1:0] cal_age;
    logic [4:0] remote_wait_ms;
    logic audio_synced,pan_initialized;
    cfg_response_t backend_q;
    audio_config_t audio_q;
    logic audio_valid_q,commit_audio,commit_scalar,boot_pending;
    wire audio_reply_ok=audio_valid_q && audio_config_valid(audio_q) &&
        (!audio_parameter(pending.id) ||
         (audio_value(audio_q,pending.id)==backend_q.applied_value &&
          backend_q.applied_value==pending.value));
    wire [config_pkg::CFG_COUNT-1:0] supported=backend_supported|LOCAL_SUPPORTED;
    assign req_ready=(state==IDLE)&&!boot_pending&&pan_initialized&&rst_n;
    assign rsp_valid=(state==REPLY)&&rst_n;
    assign backend_valid=(state==BACKEND_SEND)&&rst_n;
    assign backend_request=pending;
    assign backend_source=response_source;
    assign backend_rsp_ready=(state==BACKEND_WAIT)&&rst_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=IDLE;pending<='0;response<='0;response_source<=0;remote_wait_ms<=0;
            active_values<=cfg_defaults();pan_initialized<=0;render_config<=display_defaults();render_epoch<=0;
            index<=0;cal_age<=0;joy_recalibrate<=0;
            audio_synced<=0;backend_q<='0;audio_q<='0;audio_valid_q<=0;
            commit_audio<=0;commit_scalar<=0;boot_pending<=0;
        end else begin
            joy_recalibrate<=0;
            if(!pan_initialized)begin
                active_values[21]<=32'(initial_pan>32?6'd32:initial_pan);pan_initialized<=1;
            end
            // External requests have a bounded PRE-ACCEPT wait. Once the audio
            // backend accepts, wait for its authoritative completion (no false BUSY).
            if(state!=BACKEND_SEND)remote_wait_ms<=0;
            else if(tick_ms && remote_wait_ms<20)remote_wait_ms<=remote_wait_ms+1'b1;
            // Initial publication uses the same held snapshot, independent of
            // upstream backend mux/valid propagation and ordinary requests.
            if(AUDIO_BACKEND && !audio_synced && state==IDLE && !req_valid &&
               !boot_pending && backend_audio_valid)begin
                audio_q<=backend_audio_state;audio_valid_q<=backend_audio_valid;boot_pending<=1;
            end
            if(boot_pending)begin
                boot_pending<=0;
                if(audio_valid_q && audio_config_valid(audio_q))begin
                    audio_synced<=1;
                    active_values[0]<=32'(audio_q.instrument);active_values[2]<=32'(audio_q.reverb);
                    active_values[5]<=32'(audio_q.bank);active_values[11]<=32'(audio_q.source);
                    active_values[12]<=32'(audio_q.channel);active_values[20]<=32'(audio_q.guide);
                end
            end
            case(state)
                IDLE:if(req_valid && req_ready)begin
                    pending<=request;response_source<=request_source;
                    response.tag<=request.tag;response.id<=request.id;
                    response.applied_value<=0;response.result<=CFG_OK;
                    index<=cfg_index(request.id);state<=VALIDATE;
                end
                VALIDATE:begin
                    if(index<0)begin response.result<=CFG_UNSUPPORTED;state<=REPLY;end
                    else if(!supported[index])begin response.result<=CFG_UNSUPPORTED;state<=REPLY;end
                    else if(!cfg_value_valid(index,pending.value))begin
                        response.result<=CFG_OUT_OF_RANGE;state<=REPLY;
                    end else if(pending.id==16'h0400 && !style_supported(pending.value[15:0]))begin
                        response.result<=CFG_UNSUPPORTED;state<=REPLY;
                    end else if(DISPLAY_MASK[index])begin
                        case(pending.id)
                            16'h0400:render_config.style_id<=pending.value[15:0];
                            16'h0401:render_config.theme<=pending.value[0];
                            16'h0402:render_config.peak<=pending.value[0];
                            16'h0403:render_config.smooth<=pending.value[0];
                            16'h0404:render_config.grid<=pending.value[0];
                            default:;
                        endcase
                        render_epoch<=render_epoch+1'b1;state<=DISPLAY;
                    end else if(pending.id==16'h8000)begin
                        joy_recalibrate<=1;cal_age<=0;state<=CAL_START;
                    end else state<=BACKEND_SEND;
                end
                DISPLAY:if(display_done && display_done_epoch==render_epoch)begin
                    active_values[index]<=pending.value;response.applied_value<=pending.value;state<=REPLY;
                end
                BACKEND_SEND:if(backend_ready)state<=BACKEND_WAIT;
                    else if(response_source && remote_wait_ms>=20)begin
                        response.result<=CFG_BUSY;state<=REPLY;
                    end
                BACKEND_WAIT:if(backend_rsp_valid)begin
                    backend_q<=backend_response;audio_q<=backend_audio_state;
                    audio_valid_q<=backend_audio_valid;state<=BACKEND_CHECK;
                end
                BACKEND_CHECK:begin
                    commit_audio<=0;commit_scalar<=0;
                    if(backend_q.tag!=pending.tag || backend_q.id!=pending.id)begin
                        response.result<=CFG_FAILED;
                    end else if(backend_q.result==CFG_OK && pending.id<16'h8000 &&
                                !cfg_value_valid(index,backend_q.applied_value))begin
                        response.result<=CFG_FAILED;
                    end else if(AUDIO_BACKEND && backend_q.result==CFG_OK &&
                                (audio_parameter(pending.id) || pending.id==16'h8001) && !audio_reply_ok)begin
                        response.result<=CFG_FAILED;
                    end else begin
                        response.result<=backend_q.result;response.applied_value<=backend_q.applied_value;
                        commit_audio<=AUDIO_BACKEND && backend_q.result==CFG_OK && audio_reply_ok;
                        commit_scalar<=backend_q.result==CFG_OK && pending.id<16'h8000 &&
                                       !(AUDIO_BACKEND && audio_parameter(pending.id));
                    end
                    state<=BACKEND_APPLY;
                end
                BACKEND_APPLY:begin
                    if(commit_audio)begin
                        audio_synced<=1;
                        active_values[0]<=32'(audio_q.instrument);active_values[2]<=32'(audio_q.reverb);
                        active_values[5]<=32'(audio_q.bank);active_values[11]<=32'(audio_q.source);
                        active_values[12]<=32'(audio_q.channel);active_values[20]<=32'(audio_q.guide);
                    end
                    if(commit_scalar)active_values[index]<=backend_q.applied_value;
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
