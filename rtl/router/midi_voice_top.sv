`timescale 1ns/1ps
// 已解析事件 -> 现有状态层和router。只在本顶层集中准入、控制超时、清理与配置提交。
// NOTE_BANKS=1时加载连续32音中的一组16音；first_midi_note由资源清单提供。
// 未支持控制消费后记录，不伪造效果成功；外部控制在valid/ready握手时原子生效，
// 超时/维护时control_cancel撤销未握手请求，后端不得在未握手时不可撤销地应用。
module midi_voice_top #(
    parameter integer SLOTS=16, N_MODES=64, CLK_HZ=100_000_000, SR_HZ=48_000,
    parameter logic [7:0] PAD_NOTE_ON_TH=8'd230, PAD_NOTE_OFF_TH=8'd26,
    // AUDIO_ENABLE requires audio_clk; actual Fs = audio_clk / (64*AUDIO_CLK_DIV).
    parameter bit AUDIO_ENABLE=1'b0, PT8211_ENABLE=1'b0,
    parameter int AUDIO_CLK_DIV=4, PCM_HEADROOM_BITS=3,
    parameter bit STEREO_ENABLE=1'b1,
    parameter int ITD_MAX_SAMPLES=4,
    parameter logic [31:0] FLASH_BASE=32'h0000_0000,
    parameter int FLASH_BYTES=8_388_608,
    parameter bit NOTE_BANKS=1'b0, SINGLE_SOURCE=1'b1,
    // 开启后由backend事务独占配置；旧并行配置输入不再是第二个写入者。
    parameter bit CONFIG_BACKEND=1'b0,
    parameter logic [11:0] RESOURCE_MASK=12'b000000000001,
    parameter logic [4:0] CONTROL_SUPPORTED=5'b0, // CC1,CC7,CC11,Program,Bend
    parameter integer CONTROL_TIMEOUT_CYCLES=CLK_HZ/100,
    parameter integer OP_TIMEOUT_CYCLES=CLK_HZ/20,
    parameter integer CONFIG_TIMEOUT_CYCLES=CLK_HZ/5
) (
    input logic clk,rst_n,run,
    input logic audio_clk,
    // Same clk domain; one position owns both ILD and auxiliary ITD.
    input logic [5:0] pan_position=6'd16,
    input logic itd_enable=1'b1,
    output logic amp_bclk,amp_ws,amp_din,
    output wire dac_bck,dac_ws,dac_din,
    output logic audio_sample_tick,audio_deadline_miss,audio_overflow,audio_underflow,
    input pad_driver_pkg::mat4x4 fmap,
    input router_pkg::instrument_e pad_instrument,
    input router_pkg::reverb_preset reverb_preset,
    input logic reload,midi_select,midi_source_id,panic,
    input logic [3:0] selected_channel,
    input logic note_bank,
    input logic [6:0] first_midi_note,
    input logic [SLOTS*7-1:0] slot_note_map,
    input logic backend_valid,backend_source,
    output logic backend_ready,
    input config_pkg::cfg_request_t backend_request,
    output logic backend_rsp_valid,
    input logic backend_rsp_ready,
    output config_pkg::cfg_response_t backend_response,
    output logic [config_pkg::CFG_COUNT-1:0] backend_supported,
    output logic backend_audio_valid,backend_audio_fault,
    output config_pkg::guide_display_t guide_display,
    output config_pkg::audio_config_t backend_audio_state,
    input logic event_valid,
    output logic event_ready,
    input logic [31:0] event_data,
    input logic event_source_id,
    input logic [1:0] source_cleanup_req,
    output logic [1:0] source_cleanup_done,source_ops_idle,
    output logic midi_ops_idle,
    output logic control_valid,control_cancel,
    input logic control_ready,
    output logic [31:0] control_data,
    output logic control_source_id,
    output logic channel_mapped,config_busy,config_failed,
    output logic [3:0] active_channel,
    output logic active_bank,
    output logic [31:0] rejected_note_count,unsupported_count,control_timeout_count,dropped_count,
    output logic [3:0] error_sticky, // unsupported,control timeout,note timeout,configuration failure
    output logic ready,done,load_err,y_valid,
    output logic signed [63:0] y_data,
    output logic qspi_cs_n,qspi_sck,qspi_dq_oe,
    output logic [3:0] qspi_dq_o,
    input logic [3:0] qspi_dq_i
);
    typedef enum logic [2:0] {C_INIT,C_CLEAN,C_APPLY,C_WAIT,C_DRAIN,C_RUN,C_FAULT,C_RELEASE} cfg_t;
    cfg_t cfg_state;
    logic [3:0] channel_q,target_channel;
    logic bank_q,target_bank,mode_q,target_mode,source_q,target_source;
    logic guide_q,target_guide,arm_pad;
    logic [15:0] guide_revision;
    logic [6:0] first_q,target_first;
    router_pkg::instrument_e mapped_inst,inst_use,pad_q,target_pad;
    logic reload_q,panic_q,map_reload,maint_seen;
    logic backend_inflight,have_commit;
    config_pkg::cfg_request_t pending_request;
    config_pkg::audio_config_t candidate;
    router_pkg::instrument_e candidate_pad,committed_pad;
    logic [7:0] candidate_result;
    logic [15:0] candidate_inst;
    logic candidate_supported;
    router_pkg::reverb_preset reverb_q;
    logic [1:0] target_reverb;
    logic [31:0] cfg_timer,op_timer,ctrl_timer,cleanup_timer;
    logic state_idle,state_ready,state_valid,op_valid,op_ready;
    logic [1:0] backend_stage;
    config_pkg::audio_config_t candidate_q;
    router_pkg::instrument_e candidate_pad_q;
    logic [7:0] candidate_result_q;
    logic [1:0] state_cleanup_done,state_source_idle,op_cleanup_sources;
    logic [31:0] op_event_data;
    logic op_source_id,op_rejected;
    logic [SLOTS-1:0] gate,retrigger,hard_clear,voice_idle;
    logic [SLOTS-1:0] pitch_slot_source;
    logic pitch_ready,pitch_rejected;
    logic [SLOTS*7-1:0] velocity,note_map,slot_map_q,target_slot_map;
    logic [SLOTS*32-1:0] offsets;
    logic router_ready,router_done,router_midi_ready,router_midi_inflight,load_complete;
    logic maintenance_done,router_y_valid;
    logic [SLOTS-1:0] guide_target,guide_glow,pad_keys_down;
    logic [1:0] guide_cleanup_done;
    logic guide_idle,guide_ready;
    logic [31:0] guide_outside_count;
    logic [6:0] guide_last_outside;
    localparam integer MS_DIV=(CLK_HZ<1000)?1:CLK_HZ/1000;
    localparam integer MS_W=(MS_DIV<2)?1:$clog2(MS_DIV);
    logic [MS_W-1:0] guide_ms;
    wire guide_tick=guide_ms==MS_DIV-1;
    wire synth_midi=mode_q && !guide_q;
    wire internal_pitch=synth_midi && router_pkg::is_sustain(inst_use) &&
         (op_event_data[31:28]==4 || (op_event_data[31:28]==2 && op_event_data[23:17]==1));
    logic pads_released;
    always_comb begin
        pads_released=1;
        for(integer i=0;i<SLOTS;i++)
            if(fmap.raw[i*8 +:8]>=PAD_NOTE_OFF_TH)pads_released=0;
    end
    always_ff @(posedge clk or negedge rst_n)
        if(!rst_n)guide_ms<=0;else if(guide_tick)guide_ms<=0;else guide_ms<=guide_ms+1'b1;
    logic signed [63:0] router_y;
    wire cfg_clean=cfg_state==C_CLEAN;
    wire [1:0] cleanup=source_cleanup_req | {2{cfg_clean || cfg_state==C_FAULT}};
    wire source_maintenance=SINGLE_SOURCE && synth_midi && source_cleanup_req[source_q];
    wire maintain_req=cfg_clean || source_maintenance;
    wire [3:0] kind=event_data[31:28];
    wire new_on=kind==1 && event_data[16:10]!=0;
    wire note_off=kind==0 || (kind==1 && event_data[16:10]==0);
    wire changing=!CONFIG_BACKEND && ((selected_channel!=channel_q) || (midi_select!=mode_q) ||
                  (SINGLE_SOURCE && midi_source_id!=source_q) ||
                  (NOTE_BANKS && (note_bank!=bank_q || first_midi_note!=first_q)) ||
                  (!mode_q && pad_instrument!=pad_q) || (!NOTE_BANKS && slot_note_map!=slot_map_q));
    wire admit=cfg_state==C_RUN && !backend_inflight && !changing && !panic && mode_q;
    wire filtered=(!admit) || source_cleanup_req[event_source_id] || ((SINGLE_SOURCE || guide_q) && event_source_id!=source_q) ||
                  ((guide_q || !note_off) && event_data[27:24]!=channel_q) || (new_on && !channel_mapped);
    wire lifecycle_op=op_event_data[31:28]==0 || op_event_data[31:28]==1 ||
        (op_event_data[31:28]==2 && (op_event_data[23:17]==64 ||
         op_event_data[23:17]==120 || op_event_data[23:17]==123));
    wire control_op=op_valid && !(|op_cleanup_sources) && !lifecycle_op;
    logic ctrl_supported;
    wire timed_control=control_op && ctrl_supported && ctrl_timer>=CONTROL_TIMEOUT_CYCLES;
    wire cancelling=op_valid && !(|op_cleanup_sources) && cleanup[op_source_id];
    wire cancel_audio=cancelling && !control_op && !router_midi_inflight;
    wire note_timeout=op_valid && !control_op && !(|op_cleanup_sources) &&
                      op_timer>=OP_TIMEOUT_CYCLES;
    wire config_request=changing || (reload && !reload_q) || (panic && !panic_q) || note_timeout;
    wire cancel_control=control_op && (cancelling || timed_control);
    wire cleanup_pending=(|(cleanup & ~state_cleanup_done)) ||
                         (source_maintenance && !maint_seen && !maintenance_done);
    wire router_run=run || cfg_state!=C_RUN || (|(cleanup & ~state_cleanup_done)) ||
                    (source_maintenance && !maint_seen) || (|op_cleanup_sources);
    pad_driver_pkg::mat4x4 pad_use;
    function automatic logic [31:0] inc(input logic [31:0] v);
        inc=(v==32'hffffffff)?v:v+1'b1;
    endfunction
    midi_instrument_map u_map(.channel(channel_q),.mapped(channel_mapped),.instrument(mapped_inst));
    // Decode before the existing C_APPLY commit, alongside channel/mode.
    // The router sees a register, not channel decode + selection + its own FSM.
    assign backend_ready=CONFIG_BACKEND && rst_n && !backend_inflight && backend_stage==0 && !backend_rsp_valid &&
                         (cfg_state==C_RUN || cfg_state==C_FAULT) && !panic && !reload;
    assign backend_audio_valid=CONFIG_BACKEND && have_commit && cfg_state==C_RUN && !config_failed;
    assign backend_audio_fault=CONFIG_BACKEND && config_failed;
    // 当前只开放有真实提交路径的参数。资源是否存在由集成者给出，不凭枚举猜测。
    always_comb begin
        backend_supported='0;
        if(CONFIG_BACKEND)begin
            backend_supported[0]=|RESOURCE_MASK;
            backend_supported[2]=1;
            backend_supported[5]=NOTE_BANKS;
            backend_supported[11]=1;
            backend_supported[12]=1;
            backend_supported[17]=1;
            backend_supported[20]=1;
        end
        candidate=have_commit ? backend_audio_state :
                  config_pkg::audio_config_t'({16'd0,5'd2,2'd0,1'b0,2'd0,1'b0});
        candidate_pad=have_commit ? committed_pad : router_pkg::INST_PIANO;
        candidate_result=config_pkg::CFG_OK;
        candidate_supported=1;
        case(pending_request.id)
            16'h0100:begin
                candidate.instrument=16'(pending_request.value);
                if(candidate.source==0)candidate_pad=router_pkg::instrument_e'(pending_request.value);
                else candidate.channel=config_pkg::instrument_channel(16'(pending_request.value));
            end
            16'h0200:candidate.reverb=2'(pending_request.value);
            16'h0300:begin
                candidate.bank=1'(pending_request.value);
                if(!NOTE_BANKS)candidate_supported=0;
            end
            16'h0500:begin
                candidate.source=2'(pending_request.value);
                if(candidate.source!=backend_audio_state.source)candidate.guide=0;
                candidate.instrument=candidate.source==0 ? 16'(candidate_pad) :
                                     config_pkg::midi_instrument(candidate.channel);
            end
            16'h0501:begin
                candidate.channel=5'(pending_request.value);
                if(candidate.source!=0)candidate.instrument=config_pkg::midi_instrument(candidate.channel);
            end
            16'h0503:candidate.guide=pending_request.value[0];
            16'h8001:;
            default:candidate_supported=0;
        endcase
        candidate_inst=candidate.source==0 ? 16'(candidate_pad) : candidate.instrument;
        if(!candidate_supported)candidate_result=config_pkg::CFG_UNSUPPORTED;
        else if(!config_pkg::cfg_value_valid(config_pkg::cfg_index(pending_request.id),pending_request.value))
            candidate_result=config_pkg::CFG_OUT_OF_RANGE;
        else if((pending_request.id==16'h0100 && pending_request.value>11) ||
                !config_pkg::audio_config_valid(candidate) || candidate_inst>11)
            candidate_result=config_pkg::CFG_UNSUPPORTED;
        else if(!RESOURCE_MASK[candidate_inst[3:0]])candidate_result=config_pkg::CFG_UNSUPPORTED;
    end
    always_comb begin
        ctrl_supported=internal_pitch;
        case(op_event_data[31:28])
            2:case(op_event_data[23:17])
                1:ctrl_supported=internal_pitch || CONTROL_SUPPORTED[0];7:ctrl_supported=CONTROL_SUPPORTED[1];
                11:ctrl_supported=CONTROL_SUPPORTED[2];default:;
            endcase
            3:ctrl_supported=CONTROL_SUPPORTED[3];
            4:ctrl_supported=internal_pitch || CONTROL_SUPPORTED[4];
            default:;
        endcase
        note_map=slot_map_q;
        offsets='0;
        for(integer i=0;i<SLOTS;i++) begin
            if(NOTE_BANKS) note_map[i*7 +: 7]=7'(first_q+(bank_q?SLOTS:0)+i);
            offsets[i*32 +: 32]=32'(((NOTE_BANKS && bank_q)?SLOTS+i:i)*N_MODES*64);
        end
        pad_use=maintain_req || config_busy || config_failed || panic ? '0 : fmap;
        guide_display='0;
        guide_display.enabled=CONFIG_BACKEND && have_commit && backend_audio_state.guide && cfg_state==C_RUN && !config_failed;
        guide_display.waiting_release=cfg_state==C_RELEASE;
        guide_display.fault=config_failed;
        guide_display.link_fault=mode_q && source_cleanup_req[source_q];
        guide_display.revision=guide_revision;guide_display.banked=NOTE_BANKS;
        guide_display.audio=backend_audio_state;
        guide_display.outside_count=guide_outside_count;
        guide_display.last_outside=guide_last_outside;
        for(integer i=0;i<SLOTS;i++)begin
            guide_display.note_map[i*7 +:7]=note_map[i*7 +:7];
            guide_display.target[i]=guide_target[i];guide_display.glow[i]=guide_glow[i];
            guide_display.pressed[i]=cfg_state==C_RUN && pad_keys_down[i];
        end
    end
    assign config_busy=cfg_state!=C_RUN && cfg_state!=C_FAULT;
    assign state_valid=event_valid && !filtered && !config_request && !guide_q;
    // 未选来源/维护期间明确丢弃旧演奏事件，不堵住comm共享事件FIFO。
    assign event_ready=rst_n && (filtered || config_request || (guide_q?guide_ready:state_ready));
    assign control_valid=control_op && ctrl_supported && !internal_pitch && !cancel_control;
    assign control_cancel=cancel_control && !internal_pitch;
    assign control_data=op_event_data;
    assign control_source_id=op_source_id;
    assign op_ready=control_op ? (!ctrl_supported || cancel_control || (internal_pitch ? pitch_ready : control_ready)) :
                    (cancel_audio || router_midi_ready);
    assign source_cleanup_done=(cfg_state==C_FAULT)?2'b0:
        state_cleanup_done & guide_cleanup_done & source_cleanup_req &
        ((source_maintenance && !maint_seen && !maintenance_done)?2'b0:2'b11);
    assign source_ops_idle=state_source_idle & {2{cfg_state==C_RUN && guide_idle}};
    assign midi_ops_idle=state_idle && guide_idle && cfg_state==C_RUN &&
                         !((| (cleanup & ~state_cleanup_done))) &&
                         (!source_maintenance || maint_seen || maintenance_done);
    assign ready=router_ready && cfg_state==C_RUN && !config_failed;
    assign done=router_done;
    assign y_valid=router_y_valid;
    assign y_data=config_busy || config_failed || maintain_req || panic ? 64'sd0 : router_y;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            slot_map_q<=router_pkg::default_note_map();target_slot_map<=router_pkg::default_note_map();
            guide_q<=0;target_guide<=0;guide_revision<=0;arm_pad<=0;
            cfg_state<=C_INIT;channel_q<=0;bank_q<=0;first_q<=0;mode_q<=0;source_q<=0;
            target_channel<=0;target_bank<=0;target_first<=0;target_mode<=0;target_source<=0;
            pad_q<=router_pkg::INST_PIANO;target_pad<=router_pkg::INST_PIANO;
            inst_use<=router_pkg::INST_PIANO;
            reload_q<=0;panic_q<=0;map_reload<=0;maint_seen<=0;
            backend_stage<=0;candidate_q<='0;candidate_pad_q<=router_pkg::INST_PIANO;candidate_result_q<=0;
            backend_inflight<=0;backend_rsp_valid<=0;backend_response<='0;pending_request<='0;
            backend_audio_state<='0;have_commit<=0;committed_pad<=router_pkg::INST_PIANO;
            reverb_q<=router_pkg::REVERB_NONE;target_reverb<=0;
            cfg_timer<=0;op_timer<=0;ctrl_timer<=0;cleanup_timer<=0;config_failed<=0;active_channel<=0;active_bank<=0;
            unsupported_count<=0;control_timeout_count<=0;dropped_count<=0;error_sticky<=0;
        end else begin
            reload_q<=reload;panic_q<=panic;map_reload<=0;
            if(backend_rsp_valid && backend_rsp_ready)backend_rsp_valid<=0;
            if(CONFIG_BACKEND && backend_inflight && backend_stage==0 && cfg_state==C_FAULT)begin
                backend_response.tag<=pending_request.tag;backend_response.id<=pending_request.id;
                backend_response.result<=config_pkg::CFG_FAILED;backend_response.applied_value<=0;
                backend_rsp_valid<=1;backend_inflight<=0;
            end
            if(!maintain_req) maint_seen<=0;
            else if(maintenance_done) maint_seen<=1;
            if(cleanup_pending) cleanup_timer<=inc(cleanup_timer); else cleanup_timer<=0;
            if(op_valid) op_timer<=inc(op_timer); else op_timer<=0;
            if(control_op && ctrl_supported && !op_ready) ctrl_timer<=inc(ctrl_timer); else ctrl_timer<=0;
            if(event_valid && event_ready && (filtered || config_request)) dropped_count<=inc(dropped_count);
            if(control_op && op_ready && !ctrl_supported) begin
                unsupported_count<=inc(unsupported_count);error_sticky[0]<=1;
            end
            if(control_op && internal_pitch && pitch_ready && pitch_rejected)begin
                unsupported_count<=inc(unsupported_count);error_sticky[0]<=1;
            end
            if(timed_control && !cancelling) begin
                control_timeout_count<=inc(control_timeout_count);error_sticky[1]<=1;
            end
            if(note_timeout) error_sticky[2]<=1;
            if(config_busy && cfg_state!=C_RELEASE) cfg_timer<=inc(cfg_timer); else cfg_timer<=0;
            case(cfg_state)
                C_INIT,C_RUN,C_FAULT: if(cfg_state==C_INIT ||
                    (cfg_state==C_RUN && config_request) ||
                    (cfg_state==C_FAULT && ((reload && !reload_q) || (panic && !panic_q)))) begin
                    target_slot_map<=slot_note_map;
                    target_guide<=CONFIG_BACKEND && have_commit && backend_audio_state.guide;
                    target_channel<=CONFIG_BACKEND ? (have_commit ? 4'(backend_audio_state.channel-1'b1) : 4'd1) : selected_channel;
                    target_mode<=CONFIG_BACKEND ? (have_commit && backend_audio_state.source!=0) : midi_select;
                    target_source<=CONFIG_BACKEND ? (have_commit && backend_audio_state.source==2) : (SINGLE_SOURCE?midi_source_id:1'b0);
                    target_bank<=CONFIG_BACKEND ? (have_commit && backend_audio_state.bank) : (NOTE_BANKS?note_bank:1'b0);
                    target_first<=NOTE_BANKS?first_midi_note:7'd0;
                    target_pad<=CONFIG_BACKEND ? committed_pad : pad_instrument;
                    target_reverb<=CONFIG_BACKEND && have_commit ? backend_audio_state.reverb : 2'd0;
                    cfg_timer<=0;cfg_state<=C_CLEAN;
                    config_failed<=0;
                end
                C_CLEAN: if((&state_cleanup_done) && (&guide_cleanup_done) && (maint_seen || maintenance_done)) cfg_state<=C_APPLY;
                C_APPLY: begin
                    if((target_mode && target_channel>5) ||
                       (CONFIG_BACKEND && !RESOURCE_MASK[target_mode ?
                         4'(config_pkg::midi_instrument({1'b0,target_channel}+5'd1)) : 4'(target_pad)]) ||
                       (NOTE_BANKS && (32'(target_first)+2*SLOTS>128))) begin
                        config_failed<=1;error_sticky[3]<=1;cfg_state<=C_FAULT;
                    end else begin
                        slot_map_q<=target_slot_map;
                        arm_pad<=CONFIG_BACKEND && backend_inflight && pending_request.id!=16'h8001 &&
                            (!target_mode || target_guide) &&
                            (target_mode!=mode_q || target_guide!=guide_q || target_source!=source_q ||
                             target_channel!=channel_q || target_bank!=bank_q || target_pad!=pad_q);
                        channel_q<=target_channel;mode_q<=target_mode;source_q<=target_source;guide_q<=target_guide;
                        inst_use<=target_mode ? router_pkg::instrument_e'(config_pkg::midi_instrument({1'b0,target_channel}+5'd1)) : target_pad;
                        bank_q<=target_bank;first_q<=target_first;pad_q<=target_pad;
                        case(target_reverb)
                            0:reverb_q<=router_pkg::REVERB_NONE;
                            1:reverb_q<=router_pkg::REVERB_HALL;
                            default:reverb_q<=router_pkg::REVERB_BATHROOM;
                        endcase
                        map_reload<=1;cfg_state<=C_WAIT;
                    end
                end
                C_WAIT: if(load_complete) begin
                    if(load_err) begin config_failed<=1;error_sticky[3]<=1;cfg_state<=C_FAULT;end
                    else cfg_state<=C_DRAIN;
                end
                C_DRAIN,C_RELEASE: if(router_done) begin
                    if(arm_pad && !pads_released)begin
                        cfg_state<=C_RELEASE;
                    end else begin
                        active_channel<=channel_q;active_bank<=bank_q;config_failed<=0;cfg_state<=C_RUN;
                        if(CONFIG_BACKEND)begin
                            backend_audio_state.instrument<=16'(inst_use);
                            backend_audio_state.channel<={1'b0,channel_q}+5'd1;
                            backend_audio_state.source<=mode_q ? (source_q ? 2'd2 : 2'd1) : 2'd0;
                            backend_audio_state.bank<=bank_q;backend_audio_state.reverb<=target_reverb;
                            backend_audio_state.guide<=guide_q;guide_revision<=guide_revision+1'b1;
                            committed_pad<=pad_q;have_commit<=1;
                            if(backend_inflight)begin
                                backend_response.tag<=pending_request.tag;backend_response.id<=pending_request.id;
                                backend_response.result<=config_pkg::CFG_OK;
                                backend_response.applied_value<=pending_request.value;
                                backend_rsp_valid<=1;backend_inflight<=0;
                            end
                        end
                    end
                end
                default: cfg_state<=C_FAULT;
            endcase
            // Request transport, validation and execution are separate cycles.
            // Never propagate an upstream ID decode through the whole backend.
            if(backend_valid && backend_ready)begin
                pending_request<=backend_request;
                backend_inflight<=1;
                backend_stage<=1;
            end
            if(backend_stage==1)begin
                candidate_q<=candidate;candidate_pad_q<=candidate_pad;
                candidate_result_q<=candidate_result;backend_stage<=2;
            end
            if(backend_stage==2)begin
                backend_stage<=0;
                if(candidate_result_q!=config_pkg::CFG_OK || panic || reload ||
                   (cfg_state!=C_RUN && cfg_state!=C_FAULT))begin
                    backend_response.tag<=pending_request.tag;backend_response.id<=pending_request.id;
                    backend_response.result<=candidate_result_q!=config_pkg::CFG_OK ? candidate_result_q : config_pkg::CFG_FAILED;
                    backend_response.applied_value<=0;
                    backend_rsp_valid<=1;backend_inflight<=0;
                end else begin
                    target_slot_map<=slot_note_map;target_guide<=candidate_q.guide;
                    target_channel<=4'(candidate_q.channel-1'b1);target_mode<=candidate_q.source!=0;
                    target_source<=candidate_q.source==2;target_bank<=candidate_q.bank;
                    target_first<=NOTE_BANKS?first_midi_note:7'd0;target_pad<=candidate_pad_q;
                    target_reverb<=candidate_q.reverb;
                    config_failed<=0;cfg_timer<=0;cfg_state<=C_CLEAN;
                end
            end
            if((config_busy && cfg_state!=C_RELEASE && cfg_timer>=CONFIG_TIMEOUT_CYCLES-1) ||
               (cfg_state==C_RUN && cleanup_pending && cleanup_timer>=CONFIG_TIMEOUT_CYCLES)) begin
                config_failed<=1;error_sticky[3]<=1;cfg_state<=C_FAULT;
            end
        end
    end
    midi_guide_state #(.SLOTS(SLOTS)) u_guide(
        .clk(clk),.rst_n(rst_n),.tick_ms(guide_tick),.source_id(source_q),
        .clear(cfg_clean || cfg_state==C_FAULT || !guide_q || panic),
        .event_valid(event_valid && !filtered && !config_request && guide_q),
        .event_ready(guide_ready),.event_data(event_data),.note_map(note_map),
        .source_cleanup_req(cleanup),.source_cleanup_done(guide_cleanup_done),.idle(guide_idle),
        .target(guide_target),.glow(guide_glow),.outside_count(guide_outside_count),.last_outside(guide_last_outside));
    midi_note_state #(.SLOTS(SLOTS),.CHECK_VOICE_IDLE(1)) u_notes (
        .clk(clk),.rst_n(rst_n),.event_valid(state_valid),.event_ready(state_ready),
        .event_data(event_data),.event_source_id(event_source_id),.slot_note_map(note_map),.voice_idle(voice_idle),
        .source_cleanup_req(cleanup),.source_cleanup_done(state_cleanup_done),
        .source_ops_idle(state_source_idle),.midi_ops_idle(state_idle),
        .op_valid(op_valid),.op_ready(op_ready),.op_event_data(op_event_data),.op_source_id(op_source_id),
        .op_cleanup_sources(op_cleanup_sources),.op_rejected(op_rejected),.op_retrigger(retrigger),
        .op_hard_clear(hard_clear),.slot_gate(gate),.slot_velocity(velocity),.slot_owned(),.slot_key_down(),
        .slot_source(pitch_slot_source),.slot_channel(),.slot_original_note(),.rejected_note_count(rejected_note_count)
    );
    voice_router #(.SLOTS(SLOTS),.N_MODES(N_MODES),.CLK_HZ(CLK_HZ),.SR_HZ(SR_HZ),
        .PAD_NOTE_ON_TH(PAD_NOTE_ON_TH),.PAD_NOTE_OFF_TH(PAD_NOTE_OFF_TH),
        .EXTERNAL_SAMPLE_TICK(AUDIO_ENABLE),.MIDI_ENABLE(1),.DEBUG_PORT(0),.LOAD_OFFSETS(NOTE_BANKS),.FLASH_NOTES(NOTE_BANKS?2*SLOTS:SLOTS),.FLASH_BASE(FLASH_BASE),.FLASH_BYTES(FLASH_BYTES)) u_voice (
        .clk(clk),.rst_n(rst_n),.fmap(pad_use),.inst(inst_use),
        .reverb_preset(CONFIG_BACKEND ? reverb_q : reverb_preset),
        .reload(1'b0),.map_reload(map_reload),.load_offsets(offsets),.load_complete(load_complete),
        .maintenance_clear(maintain_req),.maintenance_done(maintenance_done),.voice_idle(voice_idle),
        .table_valid(),
        .slot_note_map(note_map),.pad_keys_down(pad_keys_down),.start(router_run),.sample_tick(audio_sample_tick),.done(router_done),.ready(router_ready),.load_err(load_err),
        .y_valid(router_y_valid),.y_data(router_y),.qspi_cs_n(qspi_cs_n),.qspi_sck(qspi_sck),
        .qspi_dq_o(qspi_dq_o),.qspi_dq_oe(qspi_dq_oe),.qspi_dq_i(qspi_dq_i),
        .midi_select(synth_midi),.midi_valid(op_valid && !control_op && !cancel_audio),
        .midi_ready(router_midi_ready),.midi_inflight(router_midi_inflight),
        .midi_gate(gate),.midi_velocity(velocity),.midi_retrigger(retrigger),.midi_hard_clear(hard_clear),
        .pitch_control_valid(control_op && internal_pitch && !cancel_control),.pitch_control_cancel(cancel_control),
        .pitch_control_source(op_source_id),.pitch_control_data(op_event_data),.pitch_slot_source(pitch_slot_source),
        .pitch_cleanup(cleanup),.pitch_control_ready(pitch_ready),.pitch_control_rejected(pitch_rejected),
        .ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0),.ns_rd_data(),.ns_rd_valid()
    );
    generate if(AUDIO_ENABLE) begin : g_audio
        i2s_audio_output #(.PT8211_ENABLE(PT8211_ENABLE),.CLK_DIV(AUDIO_CLK_DIV),.PCM_HEADROOM_BITS(PCM_HEADROOM_BITS),
            .STEREO_ENABLE(STEREO_ENABLE),.ITD_MAX_SAMPLES(ITD_MAX_SAMPLES)) u_audio(
            .clk(clk),.audio_clk(audio_clk),.rst_n(rst_n),
            .active(run && cfg_state==C_RUN && !config_failed && !maintain_req && !panic),
            .in_valid(router_y_valid),.in_data(router_y),.pan_position(pan_position),.itd_enable(itd_enable),.sample_tick(audio_sample_tick),
            .amp_bclk(amp_bclk),.amp_ws(amp_ws),.amp_din(amp_din),
            .dac_bck(dac_bck),.dac_ws(dac_ws),.dac_din(dac_din),
            .deadline_miss(audio_deadline_miss),.overflow(audio_overflow),.underflow(audio_underflow)
        );
    end else begin : g_no_audio
        assign {dac_bck,dac_ws,dac_din,amp_bclk,amp_ws,amp_din,audio_sample_tick,audio_deadline_miss,audio_overflow,audio_underflow}='0;
    end endgenerate
    // synthesis translate_off
    initial if(CONTROL_TIMEOUT_CYCLES<1 || OP_TIMEOUT_CYCLES<1 || CONFIG_TIMEOUT_CYCLES<1)
        $fatal(1,"midi_voice_top timeouts must be positive");
    // synthesis translate_on
endmodule
