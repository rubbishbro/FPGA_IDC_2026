`timescale 1ns/1ps
module tb_pad_load_relocated;
    tb_pad_load_failure #(.FLASH_BASE(32'h0080_0000),.FLASH_BYTES(16_777_216),.RELOCATED(1)) regression();
endmodule
