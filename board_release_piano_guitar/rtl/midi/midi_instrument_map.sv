`timescale 1ns/1ps
// 固定首版映射：界面通道 1..6，对应线上 channel 0..5。
// 本表只产生音色请求；不证明 Flash 已有该音色，也不实现多音色并发。
module midi_instrument_map (
    input logic [3:0] channel,
    output logic mapped,
    output router_pkg::instrument_e instrument
);
    import router_pkg::*;
    always_comb begin
        mapped = channel<6;
        instrument = mapped ? instrument_e'(config_pkg::midi_instrument({1'b0,channel}+5'd1)) : INST_NONE;
    end
endmodule
