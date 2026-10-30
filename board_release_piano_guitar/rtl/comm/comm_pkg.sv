`timescale 1ns/1ps
// 共享的线上格式常量。不依赖音频/路由器模块。
package comm_pkg;
    localparam logic [7:0] TYPE_MIDI = 8'h01;
    localparam logic [7:0] TYPE_CONFIG = 8'h02;
    localparam logic [7:0] TYPE_REPLY = 8'h80;
    function automatic logic [15:0] crc16_byte(
        input logic [15:0] crc, input logic [7:0] data
    );
        logic [15:0] c;
        begin
            c = crc ^ {data, 8'h00};
            for (int i = 0; i < 8; i = i + 1)
                c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
            return c;
        end
    endfunction
endpackage
