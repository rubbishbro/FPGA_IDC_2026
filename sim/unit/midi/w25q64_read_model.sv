`timescale 1ns/1ps
// Independent 6Bh wire model: SPI command/address, 8 dummy, quad data.
// Not derived from loader counters or its header helper.
module w25q64_read_model #(
    parameter integer N_MODES=4
) (
    input logic cs_n,sck,
    input logic [3:0] dq_o,
    input logic dq_oe,blank,
    output logic [3:0] dq_i
);
    integer clocks=0,nibbles=0,transactions=0;
    logic [7:0] command;
    logic [23:0] address;
    logic [7:0] byte_value;
    function automatic logic [31:0] word_at(input integer addr);
        word_at={8'h10,8'(addr/(N_MODES*64)),8'((addr%(N_MODES*64))/64),8'((addr%64)/4)};
    endfunction
    function automatic logic [7:0] byte_at(input integer addr);
        logic [31:0] w;
        begin w=word_at(addr);byte_at=w[31-(addr%4)*8 -: 8];end
    endfunction
    always @(negedge cs_n) begin
        clocks=0;nibbles=0;command=0;address=0;dq_i=0;transactions++;
    end
    always @(posedge sck) if(!cs_n) begin
        if(clocks<32 && dq_oe!==1) $fatal(1,"FAIL QSPI serial header not driven");
        if(clocks>=32 && dq_oe!==0) $fatal(1,"FAIL QSPI dummy/data bus contention");
        if(clocks<8) command={command[6:0],dq_o[0]};
        else if(clocks<32) address={address[22:0],dq_o[0]};
        if(clocks==7 && command!=8'h6b) $fatal(1,"FAIL QSPI opcode %02x",command);
        if(clocks>=40) nibbles++;
        clocks++;
    end
    always @(negedge sck) if(!cs_n && clocks>=40) begin
        byte_value=blank?8'd0:byte_at(address+nibbles/2);
        dq_i=nibbles%2 ? byte_value[3:0] : byte_value[7:4];
    end
endmodule
