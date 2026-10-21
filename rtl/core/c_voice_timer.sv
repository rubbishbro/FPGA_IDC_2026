// -----------------------------------------------------------------------------
// c_voice_timer.sv -- C 类每声部生命周期（迁移第一步）
//
// 一次性音符：start 装载 length_samples，逐采样递减；到 0 拉 done。
// choke：同组新 hit 到来时把剩余时间压到 FADE 采样（默认 5 ms @48k），
// 不硬清状态（避免 click），由上层决定何时真正释放。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module c_voice_timer #(
    parameter int CW   = 20,
    parameter int FADE = 240
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          start,       // note-on：装载 length
    input  logic [CW-1:0] length,      // length_samples
    input  logic          choke,       // 同组新 hit：压到 FADE
    output logic          active,
    output logic          done          // active && cnt==0
);

    logic [CW-1:0] cnt;
    logic          active_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cnt      <= {CW{1'b0}};
            active_r <= 1'b0;
        end else if (start) begin
            cnt      <= length;
            active_r <= 1'b1;
        end else if (active_r) begin
            if (choke) begin
                cnt <= (cnt > FADE) ? CW'(FADE) : cnt;
            end else if (cnt == {CW{1'b0}}) begin
                active_r <= 1'b0;
            end else begin
                cnt <= cnt - CW'(1);
            end
        end
    end

    assign active = active_r;
    assign done   = active_r && (cnt == {CW{1'b0}});

endmodule
