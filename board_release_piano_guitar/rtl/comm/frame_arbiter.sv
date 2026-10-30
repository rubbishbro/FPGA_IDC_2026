`timescale 1ns/1ps
// 选择已校验的完整帧。一旦授权，就锁定到该帧最后一次传输结束
// （包括首字节前的停顿）；不做字节级来源混合。
module frame_arbiter (
    input logic clk, rst_n,
    input logic admit_new_frame,
    input logic [1:0] eligible,
    input logic [1:0] s_valid,
    output logic [1:0] s_ready,
    input logic [15:0] s_data, s_type,
    input logic [31:0] s_seq,
    input logic [11:0] s_payload_len,
    input logic [1:0] s_first, s_last,
    output logic m_valid,
    input logic m_ready,
    output logic [7:0] m_data, m_type,
    output logic [15:0] m_seq,
    output logic [5:0] m_payload_len,
    output logic m_first, m_last, m_source_id,
    output logic [1:0] pin,
    output logic busy
);
    logic locked, owner, rr_next;
    logic [1:0] request;
    assign request = s_valid & eligible;
    assign busy = locked;
    assign m_source_id = owner;
    assign m_valid = locked && s_valid[owner];
    assign m_data = owner ? s_data[15:8] : s_data[7:0];
    assign m_type = owner ? s_type[15:8] : s_type[7:0];
    assign m_seq = owner ? s_seq[31:16] : s_seq[15:0];
    assign m_payload_len = owner ? s_payload_len[11:6] : s_payload_len[5:0];
    assign m_first = s_first[owner];
    assign m_last = s_last[owner];
    always_comb begin
        s_ready = 2'b00;
        pin = 2'b00;
        if (locked) begin
            s_ready[owner] = m_ready;
            pin[owner] = 1'b1;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 1'b0;
            owner <= 1'b0;
            rr_next <= 1'b0;
        end else if (!locked) begin
            if (admit_new_frame && |request) begin
                owner <= request[rr_next] ? rr_next : ~rr_next;
                locked <= 1'b1;
            end
        end else if (m_valid && m_ready && m_last) begin
            locked <= 1'b0;
            rr_next <= ~owner;
        end
    end
endmodule
