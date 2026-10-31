`timescale 1ns/1ps
// Independent 6Bh wire model: SPI command/address, 8 dummy, quad data.
// Not derived from loader counters or its header helper.
module w25q64_read_model #(
    parameter integer N_MODES=4,
    parameter MEM_FILE="",
    parameter integer RESOURCE_BASE=0,
    parameter bit FORBID_PROGRAM_READ=0,
    parameter integer MEM_BYTES=786432, FLASH_BYTES=8388608,
    parameter bit ABC_COEFF=0, // Stable synthetic eng1 recurrence; not a real instrument table.
    parameter integer WRITE_NS=0, // Optional status-write busy time; board fixture uses 20ms.
    parameter bit ENG0_COEFF=0 // Stable routing fixture, transported through the real loader.
) (
    input logic cs_n,sck,
    input logic [3:0] dq_o,
    input logic dq_oe,blank,
    output logic [3:0] dq_i
);
    logic [7:0] memory[0:MEM_BYTES-1];
    initial if(MEM_FILE!="")$readmemh(MEM_FILE,memory);
    // transactions counts 6Bh reads; status writes have their own counter.
    integer clocks=0,nibbles=0,transactions=0,qe_writes=0;
    integer min_read_address=32'h7fffffff,max_read_address=0;
    logic wel=0,qe=0;
    logic [15:0] status_write;
    time status_ready=0;
    logic [7:0] command;
    logic [23:0] address;
    logic [7:0] byte_value;
    function automatic logic [31:0] word_at(input integer physical_addr);
        integer addr;
        begin
            // Sparse model: program occupies the prefix, resources are a separate
            // file/window. Do not allocate an 8MiB padding array just to relocate it.
            addr=physical_addr-RESOURCE_BASE;
            if(physical_addr<0)$fatal(1,"FAIL negative Flash address");
            else if(physical_addr>=FLASH_BYTES)word_at=32'hffffffff; // final prefetch
            else if(physical_addr<RESOURCE_BASE)word_at=32'hc0def00d ^ 32'(physical_addr/4);
            else begin
        if(MEM_FILE!="") begin
            // The loaded file is not the physical chip boundary. Quad output
            // can prefetch the following byte before CS rises; unwritten space is FF.
            if((addr/4)*4+3>=MEM_BYTES)word_at=32'hffffffff;
            else word_at={memory[(addr/4)*4],memory[(addr/4)*4+1],memory[(addr/4)*4+2],memory[(addr/4)*4+3]};
        end else if(ENG0_COEFF)begin
            case((addr%64)/4)
                0,3:word_at=32'd268435456;
                4:word_at=32'd1073741824;
                6:word_at=32'd32768;
                default:word_at=0;
            endcase
        end else if(ABC_COEFF) begin
            case((addr%64)/4)
                0:word_at=32'd16777216; // G=1, signed Q24
                1:word_at=-32'sd16752000; // a1 near -1, signed Q24
                default:word_at=0; // a2=0, remaining fields unused
            endcase
        end else word_at={8'h10,8'(addr/(N_MODES*64)),8'((addr%(N_MODES*64))/64),8'((addr%64)/4)};
            end
        end
    endfunction
    function automatic logic [7:0] byte_at(input integer addr);
        logic [31:0] w;
        begin w=word_at(addr);byte_at=w[31-(addr%4)*8 -: 8];end
    endfunction
    always @(negedge cs_n) begin
        clocks=0;nibbles=0;command=0;address=0;dq_i=0;status_write=0;
    end
    always @(posedge sck) if(!cs_n) begin
        if(clocks<8) begin
            if(dq_oe!==1)$fatal(1,"FAIL Flash command not driven");
            command={command[6:0],dq_o[0]};
            if(clocks==7)begin
                if(command==8'h6b)begin
                    if(!qe || $time<status_ready)$fatal(1,"FAIL quad read before QE write complete");
                    transactions++;
                end else if(command!=8'h06 && command!=8'h01)
                    $fatal(1,"FAIL QSPI opcode %02x",command);
            end
        end else if(command==8'h01)begin
            if(dq_oe!==1 || clocks>=24)$fatal(1,"FAIL status write framing");
            status_write={status_write[14:0],dq_o[0]};
        end else if(command==8'h6b)begin
            if(clocks<32)begin
                if(dq_oe!==1)$fatal(1,"FAIL QSPI serial address not driven");
                address={address[22:0],dq_o[0]};
                if(clocks==31)begin
                    if(address>=FLASH_BYTES || (FORBID_PROGRAM_READ && address<RESOURCE_BASE))
                        $fatal(1,"FAIL read outside resource partition: %h",address);
                    if(address<min_read_address)min_read_address=address;
                    if(address>max_read_address)max_read_address=address;
                end
            end else if(dq_oe!==0)$fatal(1,"FAIL QSPI dummy/data bus contention");
            if(clocks>=40)nibbles++;
        end else $fatal(1,"FAIL extra clocks after WREN");
        clocks++;
    end
    always @(posedge cs_n)begin
        if(command==8'h06)begin
            // An aborted short command has no effect on the device.
            if(clocks==8)wel=1;
        end else if(command==8'h01)begin
            // CS may rise early when the loader is explicitly aborted.
            if(clocks==24)begin
            if(!wel || status_write!==16'h0002)
                $fatal(1,"FAIL QE status write WEL=%b clocks=%d SR=%h",wel,clocks,status_write);
            wel=0;qe=1;qe_writes++;status_ready=$time+WRITE_NS;
            end
        end
    end
    always @(negedge sck) if(!cs_n && command==8'h6b && clocks>=40) begin
        byte_value=blank?8'd0:byte_at(address+nibbles/2);
        dq_i=nibbles%2 ? byte_value[3:0] : byte_value[7:4];
    end
endmodule
