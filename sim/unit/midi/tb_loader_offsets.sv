`timescale 1ns/1ps
// 16 destination slots, 32 source pitches, non-power-of-two mode stride.
module tb_loader_offsets #(parameter logic [31:0] FLASH_BASE=0, parameter int FLASH_BYTES=8_388_608, parameter bit RELOCATED=0);
    logic clk=0,rst_n=0,start=0,abort=0;
    always #5 clk=~clk;
    logic [3:0] inst=1;
    logic [511:0] slot_offsets;
    logic [15:0] update_mask;
    logic busy,done,err,ld_we,cs,sck,oe,blank=0;
    logic [2:0] error_code;
    logic [6:0] ld_addr;
    logic [3:0] dq_o,dq_i;
    modal_step_pkg::coeff_t ld_co;
    router_pkg::mod_par_t ld_pm;
    integer expected_note[0:15],expected_inst=1,writes=0,checks=0;
    logic [15:0] expected_mask;
    logic expect_zero=0;
    weight_loader #(.SLOTS(16),.N_MODES(3),.FLASH_NOTES(32),.USE_OFFSETS(1),
                    .FLASH_BASE(FLASH_BASE),.FLASH_BYTES(FLASH_BYTES),.CLK_HZ(1_000_000),.SUPPORT_ABORT(1),.BLANK_WAIT(2),.TIMEOUT_CYCLES(100000)) dut(
        .clk(clk),.rst_n(rst_n),.inst(inst),.start(start),.slot_offsets(slot_offsets),
        .update_mask(update_mask),.abort(abort),.busy(busy),.done(done),.err(err),.error_code(error_code),
        .ld_we(ld_we),.ld_addr(ld_addr),.ld_co(ld_co),.ld_pm(ld_pm),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dq_o),.qspi_dq_oe(oe),.qspi_dq_i(dq_i));
    w25q64_read_model #(.N_MODES(3),.RESOURCE_BASE(FLASH_BASE),.FLASH_BYTES(FLASH_BYTES),.FORBID_PROGRAM_READ(FLASH_BASE!=0)) flash(.cs_n(cs),.sck(sck),.dq_o(dq_o),.dq_oe(oe),.blank(blank),.dq_i(dq_i));
    function automatic logic [31:0] expected(input integer slot,mode,word_number);
        expected=expect_zero?0:{8'h10,8'(expected_inst*32+expected_note[slot]),8'(mode),8'(word_number)};
    endfunction
    always @(posedge clk) if(rst_n && ld_we) begin : monitor
        integer s,m;
        logic [223:0] want;
        logic [255:0] want_pm;
        s=ld_addr[5:2];m=ld_addr[1:0];writes++;
        if(!expected_mask[s] || m>=3) $fatal(1,"FAIL loader destination outside mask/mode");
        if(!ld_addr[6]) begin
            want={expected(s,m,0),expected(s,m,1),expected(s,m,2),expected(s,m,3),
                  expected(s,m,4),expected(s,m,5),expected(s,m,6)};
            if(ld_co!==want) $fatal(1,"FAIL coefficient s=%0d m=%0d got=%h expected=%h",s,m,ld_co,want);
        end else begin
            // 参数半区现在是 8 个字：a11_0 a12_0 a22_0 wo_0 s11 s12 s22 swo
            want_pm={expected(s,m,8),expected(s,m,9),expected(s,m,10),expected(s,m,11),
                     expected(s,m,12),expected(s,m,13),expected(s,m,14),expected(s,m,15)};
            if(ld_pm!==want_pm) $fatal(1,"FAIL modulation record s=%0d m=%0d",s,m);
        end
        checks++;
    end
    task automatic begin_load;
        writes=0;
        @(negedge clk);start=1;@(negedge clk);start=0;
    endtask
    task automatic finish_load(input integer n,input integer code);
        wait(done);@(negedge clk);
        if(busy || writes!=n || err!=(code!=0) || error_code!=code)
            $fatal(1,"FAIL load completion writes=%0d expected=%0d err=%0d code=%0d expected=%0d",writes,n,err,error_code,code);
    endtask
    integer before_reads;
    initial begin
        update_mask='1;expected_mask='1;
        for(integer i=0;i<16;i++) begin expected_note[i]=i;slot_offsets[i*32 +: 32]=i*192;end
        repeat(4) @(negedge clk);rst_n=1;begin_load();
        // Mutations after acceptance must not affect this transaction.
        inst=7;slot_offsets='0;update_mask=0;
        finish_load(96,0);
        inst=1;update_mask='1;
        for(integer i=0;i<16;i++) begin expected_note[i]=16+i;slot_offsets[i*32 +: 32]=(16+i)*192;end
        begin_load();finish_load(96,0);
        // Arbitrary order and duplicate source offsets remain legal.
        update_mask=16'h8003;expected_mask=update_mask;
        expected_note[0]=31;expected_note[1]=3;expected_note[15]=3;
        slot_offsets[31:0]=31*192;slot_offsets[63:32]=3*192;slot_offsets[511:480]=3*192;
        begin_load();finish_load(18,0);
        expected_mask=0;update_mask=0;before_reads=flash.transactions;
        begin_load();finish_load(0,0);
        if(flash.transactions!=before_reads) $fatal(1,"FAIL zero mask started Flash read");
        expected_mask=1;update_mask=1;slot_offsets[31:0]=32*192;expect_zero=1;
        before_reads=flash.transactions;begin_load();finish_load(6,1);
        if(flash.transactions!=before_reads) $fatal(1,"FAIL invalid offset started Flash read");
        slot_offsets[31:0]=0;blank=1;begin_load();finish_load(6,2);blank=0;
        update_mask=3;expected_mask=3;slot_offsets[63:32]=192;
        begin_load();repeat(80) @(negedge clk);abort=1;finish_load(12,3);abort=0;
        if(RELOCATED)begin
            if(flash.min_read_address<FLASH_BASE)$fatal(1,"FAIL relocated load read program");
            $display("PASS tb_loader_relocated checked_records=%0d base=%h",checks,FLASH_BASE);
        end else $display("PASS tb_loader_offsets checked_records=%0d QE_writes=%0d",checks,flash.qe_writes);
        if(flash.qe_writes!=6)$fatal(1,"FAIL QE initialization/repeated load/aborted write count");$finish;
    end
    initial begin #5000000;$fatal(1,"FAIL loader offset timeout");end
endmodule

module tb_loader_timeout;
    logic clk=0,rst_n=0,start=0,busy,done,err,ld_we,cs,sck,oe;
    always #5 clk=~clk;
    logic [2:0] code;
    logic [3:0] dqo,dqi;
    logic [6:0] addr;
    modal_step_pkg::coeff_t co;
    router_pkg::mod_par_t pm;
    integer writes=0;
    weight_loader #(.SLOTS(16),.N_MODES(3),.FLASH_NOTES(32),.USE_OFFSETS(1),
                    .TIMEOUT_CYCLES(200),.BLANK_WAIT(2)) dut(
        .clk(clk),.rst_n(rst_n),.inst(4'd0),.start(start),.slot_offsets(512'd0),.update_mask(16'd1),
        .abort(1'b0),.busy(busy),.done(done),.err(err),.error_code(code),.ld_we(ld_we),.ld_addr(addr),
        .ld_co(co),.ld_pm(pm),.qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi));
    w25q64_read_model #(.N_MODES(3)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(1'b0),.dq_i(dqi));
    always @(posedge clk) if(rst_n && ld_we) begin
        writes++;
        if(co!==0 || pm!==0 || addr[5:2]!=0) $fatal(1,"FAIL timeout published partial data");
    end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;start=1;@(negedge clk);start=0;
        wait(done);@(negedge clk);
        if(!err || code!=4 || busy || !cs || writes!=6) $fatal(1,"FAIL loader timeout not retired");
        $display("PASS tb_loader_timeout cleared_records=%0d",writes);$finish;
    end
    initial begin #100000;$fatal(1,"FAIL loader timeout fixture hung");end
endmodule
