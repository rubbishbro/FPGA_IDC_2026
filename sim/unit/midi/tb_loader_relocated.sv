`timescale 1ns/1ps
module tb_loader_relocated;
    tb_loader_offsets #(.FLASH_BASE(32'h0080_0000),.FLASH_BYTES(16_777_216),.RELOCATED(1)) regression();
endmodule
