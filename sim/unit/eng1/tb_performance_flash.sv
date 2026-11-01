`timescale 1ns/1ps
// Real 16x64 loader/router, four exported ABC images, relocated board Flash.
module tb_performance_flash;
    import router_pkg::*;
    logic clk=0,rst_n=0,maintenance=0;
    always #10 clk=~clk;
    instrument_e inst=INST_PIANO;
    pad_driver_pkg::mat4x4 fmap='0;
    logic [3:0] flash_i;
    logic valid,done,err,maintenance_done;
    integer outputs=0,nonzero_outputs=0,loads=0,checked=0;
    voice_router #(.SLOTS(16),.N_MODES(64),.CLK_HZ(50_000_000),.SR_HZ(48_000),.MIDI_ENABLE(1),
        .PAD_NOTE_ON_TH(64),.PAD_NOTE_OFF_TH(48),.FLASH_BASE(32'h800000),.FLASH_BYTES(16_777_216)) dut(
        .clk(clk),.rst_n(rst_n),.fmap(fmap),.inst(inst),.reverb_preset(REVERB_NONE),
        .reload(1'b0),.start(1'b1),.sample_tick(1'b0),.slot_note_map(default_note_map()),
        .done(done),.ready(),.load_err(err),.table_valid(valid),.y_valid(),.y_data(),
        .qspi_cs_n(),.qspi_sck(),.qspi_dq_o(),.qspi_dq_oe(),.qspi_dq_i(flash_i),
        .midi_select(1'b0),.midi_valid(1'b0),.midi_gate('0),.midi_retrigger('0),
        .midi_hard_clear('0),.midi_velocity('0),.midi_ready(),
        .maintenance_clear(maintenance),.maintenance_done(maintenance_done),
        .map_reload(1'b0),.load_offsets('0),.midi_inflight(),.voice_idle(),.load_complete(),
        .ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0),.ns_rd_data(),.ns_rd_valid());
    w25q64_read_model #(.N_MODES(64),.MEM_FILE("resources.mem"),.MEM_BYTES(393216),
        .RESOURCE_BASE(32'h800000),.FLASH_BYTES(16_777_216),.FORBID_PROGRAM_READ(1),
        .WRITE_NS(20_000_000)) flash(.cs_n(dut.qspi_cs_n),.sck(dut.qspi_sck),
        .dq_o(dut.qspi_dq_o),.dq_oe(dut.qspi_dq_oe),.blank(1'b0),.dq_i(flash_i));
    always @(posedge clk)if(rst_n)begin
        if(dut.y_valid)begin
            outputs++;
            if($isunknown(dut.y_data))$fatal(1,"FAIL unknown output");
            if(dut.y_data!=0)nonzero_outputs++;
        end
        if(valid && (|dut.mod_co_we))$fatal(1,"FAIL matrix modulator wrote ABC coefficients");
        if(valid && (dut.u_era.e0_start || dut.u_erb.e0_start))$fatal(1,"FAIL wrong engine selected");
    end
    function automatic logic[31:0] word(input int ident,slot,mode,w);
        int addr;
        addr=ident*65536+slot*4096+mode*64+w*4;
        return {flash.memory[addr],flash.memory[addr+1],flash.memory[addr+2],flash.memory[addr+3]};
    endfunction
    task automatic verify_table(input instrument_e selected);
        logic[31:0] g,a1,a2;
        int addr;
        for(int slot=0;slot<16;slot++)for(int mode=0;mode<64;mode++)begin
            addr=(slot%8)*64+mode;
            g=slot<8 ? dut.ca_a11_a[addr] : dut.ca_a11_b[addr];
            a1=slot<8 ? dut.ca_a12_a[addr] : dut.ca_a12_b[addr];
            a2=slot<8 ? dut.ca_a21_a[addr] : dut.ca_a21_b[addr];
            if({g,a1,a2}!=={word(int'(selected),slot,mode,0),word(int'(selected),slot,mode,1),word(int'(selected),slot,mode,2)})
                $fatal(1,"FAIL coeff layout inst=%0d slot=%0d mode=%0d",selected,slot,mode);
            if(dut.pm_swo[slot*64+mode]!==32'h50315431)$fatal(1,"FAIL P1T1 metadata");
            checked++;
        end
    endtask
    task automatic frames(input int count);
        int target;
        target=outputs+count;wait(outputs>=target);@(negedge clk);
    endtask
    task automatic audition(input instrument_e selected);
        int before_nonzero;
        @(negedge clk);inst=selected;
        wait(dut.inst_prev==selected && valid && done);@(negedge clk);
        if(err || dut.nm_lat!=48 || !eng_sel(selected))$fatal(1,"FAIL selected profile");
        case(selected)
            INST_PIANO:if(dut.u_exc.rise_sh_r!=1 || dut.u_exc.pw_len_r!=2 ||
                dut.u_exc.gap_len_r!=478 || dut.u_env.r_step_r!=21845)$fatal(1,"FAIL piano frontend");
            INST_GUITAR:if(dut.u_env.a_step_r!=89478486 || dut.u_env.d_step_r!=0 ||
                dut.u_env.s_level_r!=32'h7fffffff || dut.u_env.r_step_r!=74566)$fatal(1,"FAIL guitar F frontend");
            INST_VIOLIN:if(dut.u_env.a_step_r!=2236963 || dut.u_env.d_step_r!=0 ||
                dut.u_env.s_level_r!=32'h7fffffff || dut.u_env.r_step_r!=559241 ||
                !dut.u_env.current_frame_r)$fatal(1,"FAIL violin frontend");
            default:;
        endcase
        verify_table(selected);loads++;
        before_nonzero=nonzero_outputs;
        fmap.raw[0*8 +:8]=180;fmap.raw[7*8 +:8]=180;
        fmap.raw[8*8 +:8]=180;fmap.raw[15*8 +:8]=180;
        frames(512);
        if(nonzero_outputs<=before_nonzero)$fatal(1,"FAIL no sound inst=%0d",selected);
        if(dut.part_gate!==16'h8181)$fatal(1,"FAIL gate map/bank");
        fmap.raw[0*8 +:8]=240;frames(16);
        if(dut.mod_req!=0)$fatal(1,"FAIL pressure invoked matrix modulation");
        fmap='0;frames(8);
        if(dut.voice_idle==16'hffff)$fatal(1,"FAIL release retired prematurely");
        maintenance=1;wait(maintenance_done);repeat(2)@(negedge clk);
        if(dut.voice_idle!==16'hffff)$fatal(1,"FAIL clear did not retire both banks");
        maintenance=0;frames(4);
        $display("PASS resource inst=%0d loaded, sounded, released and cleared",selected);
    endtask
    initial begin
        repeat(8)@(negedge clk);rst_n=1;
        audition(INST_PIANO);audition(INST_GUITAR);audition(INST_TRUMPET);audition(INST_VIOLIN);
        if(loads!=4 || checked!=4096)$fatal(1,"FAIL incomplete coverage");
        $display("PASS tb_performance_flash loads=%0d records=%0d outputs=%0d",loads,checked,outputs);
        $finish;
    end
    initial begin #500000000;$fatal(1,"FAIL timeout inst=%0d state=%0d loads=%0d",inst,dut.state,loads);end
endmodule
