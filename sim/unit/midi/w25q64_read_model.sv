`timescale 1ns/1ps
// Independent 6Bh wire model: SPI command/address, 8 dummy, quad data.
// Not derived from loader counters or its header helper.
module w25q64_read_model #(
    parameter integer N_MODES=4,
    parameter MEM_FILE="",
    parameter integer MEM_BYTES=786432, FLASH_BYTES=8388608,
    parameter bit ABC_COEFF=0 // Stable synthetic eng1 recurrence; not a real instrument table.
) (
    input logic cs_n,sck,
    input logic [3:0] dq_o,
    input logic dq_oe,blank,
    output logic [3:0] dq_i
);
    logic [7:0] memory[0:MEM_BYTES-1];
    initial if(MEM_FILE!="")$readmemh(MEM_FILE,memory);
    integer clocks=0,nibbles=0,transactions=0;
    logic [7:0] command;
    logic [23:0] address;
    logic [7:0] byte_value;
    function automatic logic [31:0] word_at(input integer addr);
        if(MEM_FILE!="") begin
            if(addr<0 || (addr/4)*4+3>=FLASH_BYTES)$fatal(1,"FAIL flash model address %d",addr);
            // The loaded file is not the physical chip boundary. Quad output
            // can prefetch the following byte before CS rises; unwritten space is FF.
            if((addr/4)*4+3>=MEM_BYTES)word_at=32'hffffffff;
            else word_at={memory[(addr/4)*4],memory[(addr/4)*4+1],memory[(addr/4)*4+2],memory[(addr/4)*4+3]};
        end else if(ABC_COEFF) begin
            case((addr%64)/4)
                0:word_at=32'd16777216; // G=1, signed Q24
                1:word_at=-32'sd1047000; // a1 near -1, signed Q20
                default:word_at=0; // a2=0, remaining fields unused
            endcase
        end else word_at={8'h10,8'(addr/(N_MODES*64)),8'((addr%(N_MODES*64))/64),8'((addr%64)/4)};
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
