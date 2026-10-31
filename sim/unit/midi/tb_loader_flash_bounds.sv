`timescale 1ns/1ps
module flash_bounds_case #(
    parameter logic [31:0] BASE=32'h0080_0000,
    parameter int CAPACITY=16_777_216, OFFSET=0, INST=0,
    parameter bit BAD=0
)(output logic finished=0);
    logic clk=0,rst_n=0,start=0;
    always #5 clk=~clk;
    wire done,err,we,cs,sck,oe;
    wire [2:0] code;
    wire [4:0] addr;
    wire [3:0] dqo,dqi;
    modal_step_pkg::coeff_t co;
    router_pkg::mod_par_t pm;
    logic [127:0] offsets=0;
    integer writes=0;
    weight_loader #(.SLOTS(4),.N_MODES(4),.FLASH_NOTES(4),.USE_OFFSETS(1),
        .CLK_HZ(1_000_000),.FLASH_BASE(BASE),.FLASH_BYTES(CAPACITY),.BLANK_WAIT(2)) dut(
        .clk(clk),.rst_n(rst_n),.inst(4'(INST)),.start(start),.slot_offsets(offsets),.update_mask(4'b0001),
        .abort(1'b0),.done(done),.err(err),.error_code(code),.busy(),.ld_we(we),.ld_addr(addr),.ld_co(co),.ld_pm(pm),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi));
    w25q64_read_model #(.N_MODES(4),.RESOURCE_BASE(BASE),.FLASH_BYTES(CAPACITY),.FORBID_PROGRAM_READ(1)) flash(
        .cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(1'b0),.dq_i(dqi));
    always @(posedge clk)if(rst_n && we)begin
        writes++;
        if(BAD && (co!==0 || pm!==0))$fatal(1,"FAIL invalid Flash range published data");
    end
    initial begin
        offsets[31:0]=32'(OFFSET);
        repeat(4)@(negedge clk);rst_n=1;start=1;@(negedge clk);start=0;
        wait(done);@(negedge clk);
        if(err!=BAD || code!=(BAD?1:0) || writes!=8)$fatal(1,"FAIL Flash range completion base=%h",BASE);
        if(BAD && flash.transactions!=0)$fatal(1,"FAIL rejected range issued quad read");
        if(!BAD && (flash.transactions!=1 || flash.min_read_address!=BASE+INST*1024+OFFSET))
            $fatal(1,"FAIL actual relocated serial address base=%h addr=%h",BASE,flash.min_read_address);
        finished=1;
    end
endmodule
module tb_loader_flash_bounds;
    wire [6:0] done;
    flash_bounds_case a(done[0]);
    flash_bounds_case #(.BASE(32'h00ff_fc00),.OFFSET(768)) last_note(done[1]);
    flash_bounds_case #(.BASE(32'h00ff_fc00),.INST(1),.BAD(1)) chip_end(done[2]);
    flash_bounds_case #(.CAPACITY(8_388_608),.BAD(1)) physical_limit(done[3]);
    flash_bounds_case #(.BASE(32'h0080_0001),.BAD(1)) unaligned(done[4]);
    flash_bounds_case #(.BASE(32'h0100_0000),.CAPACITY(33_554_432),.BAD(1)) addr24_limit(done[5]);
    flash_bounds_case #(.OFFSET(1024),.BAD(1)) instrument_limit(done[6]);
    initial begin wait(&done);$display("PASS tb_loader_flash_bounds 7 cases relocated/exact-end/physical/24bit/alignment/instrument");$finish;end
    initial begin #2000000;$fatal(1,"FAIL Flash bounds timeout");end
endmodule
