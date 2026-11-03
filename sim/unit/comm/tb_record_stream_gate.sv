`timescale 1ns/1ps
module tb_record_stream_gate;
    logic clk=0,rst_n=0,trigger=0,permit=1;
    logic [15:0] seq=16'h0134;
    logic [191:0] payload;
    wire ready;wire [1:0] tx;
    record_stream_probe dut(.*);
    always #10 clk=~clk;
`ifdef GATE
    GSR GSR(1'b1);
`endif
    localparam integer BIT_NS=1000;
    logic [7:0] body[0:63];
    integer count=0,frames=0,wire_bytes=0,accepted=0;
    logic escaped=0;
    function automatic [15:0] crc_byte(input [15:0] c,input [7:0] b);
        logic [15:0] v;
        v=c^{b,8'b0};
        for(integer k=0;k<8;k++)v=v[15]?(v<<1)^16'h1021:v<<1;
        return v;
    endfunction
    task automatic byte_in(input logic [7:0] b);
        logic [15:0] crc;
        wire_bytes++;
        if(b==8'hc0)begin
            if(count!=0)begin
                if(escaped || count!=29 || body[0]!=8'h82 || body[1]!=seq[7:0] || body[2]!=24)
                    $fatal(1,"TYPE82 header/length invalid: count=%0d type=%h",count,body[0]);
                for(integer i=0;i<24;i++)if(body[3+i]!==payload[i*8 +:8])
                    $fatal(1,"payload byte %0d lost: got=%h expected=%h",i,body[3+i],payload[i*8 +:8]);
                crc=16'hffff;
                for(integer i=0;i<27;i++)crc=crc_byte(crc,body[i]);
                if({body[28],body[27]}!==crc)$fatal(1,"TYPE82 CRC mismatch");
                frames++;$display("TYPE82 seq=%h payload_bytes=24 CRC=OK escaped_payload=OK",body[1]);
            end
            count=0;escaped=0;
        end else if(b==8'hdb)begin
            if(escaped)$fatal(1,"invalid SLIP escape");
            escaped=1;
        end else begin
            if(count>=64)$fatal(1,"frame overflow");
            if(escaped && b!=8'hdc && b!=8'hdd)$fatal(1,"invalid escaped byte");
            body[count]=escaped ? (b==8'hdc ? 8'hc0 : 8'hdb) : b;
            count++;escaped=0;
        end
    endtask
    initial forever begin : rx
        logic [7:0] b;
        @(negedge tx[0]);#(BIT_NS+BIT_NS/2);
        for(integer i=0;i<8;i++)begin b[i]=tx[0];#BIT_NS;end
        if(tx[0]!==1)$fatal(1,"UART stop bit invalid");
        byte_in(b);
    end
    always @(posedge clk)if(rst_n && trigger && permit && ready)accepted++;
    always @(posedge clk)if(rst_n && tx[1]!==1'b1)$fatal(1,"record stream leaked to BT UART");
    initial begin
        for(integer i=0;i<24;i++)payload[i*8 +:8]=8'(i+1);
        payload[5*8 +:8]=8'hc0;payload[17*8 +:8]=8'hdb;
        #205;rst_n=1;
        wait(ready);@(negedge clk);trigger=1;
        do @(posedge clk);while(!ready);
        @(negedge clk);trigger=0;
        #500000;
        $display("OBSERVE accepted=%0d wire_bytes=%0d frames=%0d",accepted,wire_bytes,frames);
        if(accepted!=1 || frames!=1 || tx[1]!==1)
            $fatal(1,"descriptor accepted but complete wired TYPE82 missing or leaked to BT");
        $display("PASS tb_record_stream_gate");$finish;
    end
    initial begin #2000000;$fatal(1,"record stream watchdog");end
endmodule
