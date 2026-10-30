`timescale 1ns/1ps
// MIDI 事件 -> 有序的演奏状态事务，工作在通信时钟域。
// 不做歌曲存储、时长计时、压力映射，也不访问引擎 RAM。
// 下游适配器必须消费完每一个 op 才能接收下一个事件。
// op_ready 表示 gate/重触发/硬清除/控制效果已经退休，
// 而不只是复制进了寄存器。本模块本身不是引擎桥。
module midi_note_state #(
    parameter integer SLOTS = 16,
    parameter bit CHECK_VOICE_IDLE = 1'b0
) (
    input  logic clk, rst_n,
    input  logic event_valid,
    output logic event_ready,
    input  logic [31:0] event_data,
    input  logic event_source_id,

    // 实际预载音高，slot 0 在 [6:0]。改这张表**不会**让引擎重新调音；
    // 只能配合相应的资源事务一起改。
    input  logic [SLOTS*7-1:0] slot_note_map,
    input  logic [SLOTS-1:0] voice_idle,
    input  logic [1:0] source_cleanup_req,
    output logic [1:0] source_cleanup_done,
    output logic [1:0] source_ops_idle,
    output logic midi_ops_idle,

    output logic op_valid, // 下游有一个op等待消费(op = operation)
    input  logic op_ready, // 下游已经消费了op，允许下一个op产生
    output logic [31:0] op_event_data, // op对应的原始midi,kind/channel/data1/data2
    // kind: 事件类型：0=Note Off，1=Note On，2=CC；其他值原样透传, channel: 0-15, data1: 0-127, data2: 0-127
    output logic op_source_id, // 时间来自的物理源头(0:wired,1:蓝牙)
    output logic [1:0] op_cleanup_sources, // 1表示该源头的所有音符都被清除(全清理)
    output logic op_rejected, // 由于音高被占用或不支持的音高而拒绝了该事件
    output logic [SLOTS-1:0] op_retrigger, // 1表示该槽位的音符被重触发(即使是同一个音符)
    output logic [SLOTS-1:0] op_hard_clear, // 1表示该槽位的音符被强制清除(不管是否按下)
    // 完整状态快照，在 op_valid && !op_ready 期间保持稳定。
    output logic [SLOTS-1:0] slot_owned, slot_key_down, slot_gate, // 槽是否有归属,物理按键是否按住,现在是否发声
    output logic [SLOTS*7-1:0] slot_velocity, // 最近一次noteon velocity，0表示没有按下
    output logic [SLOTS-1:0] slot_source, // 槽的归属源头(0:wired,1:蓝牙)
    output logic [SLOTS*4-1:0] slot_channel, // midi channel，0-15
    output logic [SLOTS*7-1:0] slot_original_note, // 槽的原始音高(0-127)，不随slot_note_map变化而变化
    output logic [31:0] rejected_note_count // 由于音高被占用或不支持的音高而拒绝的事件计数
);
    localparam logic [3:0] NOTE_OFF = 0, NOTE_ON = 1, CC = 2;
    logic [31:0] sustain; // {source, channel}；不需要 128 音符的 RAM。
    logic [1:0] cleanup_issued; // 仅在 op_valid && !op_ready 期间保持稳定
    wire [1:0] cleanup_new = source_cleanup_req & ~cleanup_issued; // 仅在 op_valid && !op_ready 期间保持稳定
    logic pending, matched, event_source_q;
    logic [31:0] event_q;
    wire [3:0] kind = event_q[31:28];
    wire [3:0] channel = event_q[27:24];
    wire [6:0] data1 = event_q[23:17];
    wire [6:0] data2 = event_q[16:10];
    wire [4:0] control_index = {event_source_q, channel};
    logic [SLOTS-1:0] owner_match, mapped_match;
    logic [SLOTS-1:0] owner_pick, mapped_pick, target_pick;
    // Match is registered before priority selection. Every write below uses a
    // constant slice; no integer target*7 barrel mux / address DSP is needed.
    always_comb begin
        for (integer i=0;i<SLOTS;i=i+1) begin
            owner_pick[i] = owner_match[i] &&
                ((owner_match & ((SLOTS'(1)<<i)-1'b1)) == '0);
            mapped_pick[i] = mapped_match[i] &&
                ((mapped_match & ((SLOTS'(1)<<i)-1'b1)) == '0);
        end
        target_pick = (|owner_match) ? owner_pick : mapped_pick;
    end
    assign event_ready = rst_n && !pending && !op_valid && !(|source_cleanup_req);
    assign midi_ops_idle = rst_n && !pending && !op_valid;
    always_comb begin
        source_ops_idle = {2{rst_n}};
        if (pending) source_ops_idle[event_source_q] = 1'b0;
        if (op_valid) begin
            if (|op_cleanup_sources) source_ops_idle = ~op_cleanup_sources;
            else source_ops_idle[op_source_id] = 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending<=0; matched<=0; event_q<='0; event_source_q<=0;
            owner_match<='0; mapped_match<='0;
            sustain <= '0;
            cleanup_issued <= '0;
            source_cleanup_done <= '0;
            op_valid <= 1'b0;
            op_event_data <= '0;
            op_source_id <= 1'b0;
            op_cleanup_sources <= '0;
            op_rejected <= 1'b0;
            op_retrigger <= '0;
            op_hard_clear <= '0;
            slot_owned <= '0;
            slot_key_down <= '0;
            slot_gate <= '0;
            slot_velocity <= '0;
            slot_source <= '0;
            slot_channel <= '0;
            slot_original_note <= '0;
            rejected_note_count <= '0;
        end else begin
            cleanup_issued <= cleanup_issued & source_cleanup_req;
            source_cleanup_done <= source_cleanup_done & source_cleanup_req;
            if (op_valid) begin
                if (op_ready) begin
                    op_valid <= 1'b0;
                    source_cleanup_done <=
                        (source_cleanup_done | op_cleanup_sources) & source_cleanup_req;
                end
            end else if (pending && source_cleanup_req[event_source_q]) begin
                // Accepted but not committed: quarantine cancels this source's
                // staged event. Its cleanup is issued next, never acknowledged early.
                pending <= 1'b0;
                matched <= 1'b0;
            end else if (pending && !matched) begin
                matched <= 1'b1;
                for (integer i=0;i<SLOTS;i=i+1) begin
                    owner_match[i] <= slot_owned[i] && slot_source[i]==event_source_q &&
                        slot_channel[i*4 +:4]==channel && slot_original_note[i*7 +:7]==data1;
                    mapped_match[i] <= slot_note_map[i*7 +:7]==data1 && !slot_gate[i] &&
                        (!CHECK_VOICE_IDLE || !slot_owned[i] || voice_idle[i]);
                end
            end else if (!pending && (|cleanup_new)) begin
                // 等之前的 op 退休；绝不修改一个已经卡住的 op。
                cleanup_issued <= (cleanup_issued & source_cleanup_req) | cleanup_new;
                op_valid <= 1'b1;
                op_event_data <= '0;
                op_source_id <= 1'b0;
                op_cleanup_sources <= cleanup_new;
                op_rejected <= 1'b0;
                op_retrigger <= '0;
                op_hard_clear <= '0;
                for (integer s = 0; s < 2; s = s + 1)
                    if (cleanup_new[s]) sustain[s*16 +: 16] <= '0;
                for (integer i = 0; i < SLOTS; i = i + 1)
                    if (slot_owned[i] && cleanup_new[slot_source[i]]) begin
                        op_hard_clear[i] <= 1'b1;
                        slot_owned[i] <= 1'b0;
                        slot_key_down[i] <= 1'b0;
                        slot_gate[i] <= 1'b0;
                        slot_velocity[i*7 +: 7] <= '0;
                    end
            end else if (pending) begin
                pending <= 1'b0;
                matched <= 1'b0;
                op_valid <= 1'b1;
                op_event_data <= event_q;
                op_source_id <= event_source_q;
                op_cleanup_sources <= '0;
                op_rejected <= 1'b0;
                op_retrigger <= '0;
                op_hard_clear <= '0;
                if (kind == NOTE_ON && data2 != 0) begin
                    if (|target_pick) begin
                        for (integer i=0;i<SLOTS;i=i+1) if(target_pick[i]) begin
                            slot_owned[i] <= 1'b1;
                            slot_source[i] <= event_source_q;
                            slot_channel[i*4 +:4] <= channel;
                            slot_original_note[i*7 +:7] <= data1;
                            slot_velocity[i*7 +:7] <= data2;
                            slot_key_down[i] <= 1'b1;
                            slot_gate[i] <= 1'b1;
                            op_retrigger[i] <= 1'b1;
                        end
                    end else begin
                        // 不支持的音高 / 已被占用的音高：显式拒绝，
                        // 不抢占，也不清除另一个归属的音。
                        op_rejected <= 1'b1;
                        if (rejected_note_count != 32'hffff_ffff)
                            rejected_note_count <= rejected_note_count + 1'b1;
                    end
                end else if (kind == NOTE_OFF || (kind == NOTE_ON && data2 == 0)) begin
                    for (integer i=0;i<SLOTS;i=i+1) if(owner_pick[i]) begin
                        slot_key_down[i] <= 1'b0;
                        slot_gate[i] <= slot_gate[i] && sustain[control_index];
                    end
                end else if (kind == CC) begin
                    if (data1 == 64) begin
                        sustain[control_index] <= data2 >= 64;
                        if (data2 < 64)
                            for (integer i = 0; i < SLOTS; i = i + 1)
                                if (slot_owned[i] && slot_source[i] == event_source_q &&
                                    slot_channel[i*4 +: 4] == channel && !slot_key_down[i])
                                    slot_gate[i] <= 1'b0;
                    end else if ((data1 == 123 || data1 == 120) && data2 == 0) begin
                        for (integer i = 0; i < SLOTS; i = i + 1)
                            if (slot_owned[i] && slot_source[i] == event_source_q &&
                                slot_channel[i*4 +: 4] == channel) begin
                                slot_key_down[i] <= 1'b0;
                                slot_gate[i] <= slot_gate[i] && data1 == 123 && sustain[control_index];
                                if (data1 == 120) op_hard_clear[i] <= 1'b1;
                            end
                    end
                end
                // Program/Bend/CC1/7/11 仍留在 op_event_data 里，交给它们真正的
                // 消费者。不要把 op_ready 直接接 1 然后声称已经实现。
            end else if(event_valid && event_ready) begin
                event_q<=event_data; event_source_q<=event_source_id;
                pending<=1'b1; matched<=1'b0;
            end
        end
    end
endmodule
