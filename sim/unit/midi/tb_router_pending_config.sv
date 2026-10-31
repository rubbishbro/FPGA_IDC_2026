`timescale 1ns/1ps
module tb_router_pending_config;
    import router_pkg::*;
    logic clk=0,rst_n=0,start=0,done,ready,reload=0,blank=0,load_err,table_valid,y_valid;
    logic cs,sck,oe;
    logic [3:0] dqo,dqi;
    integer loads=0;
    always #5 clk=~clk;
    pad_driver_pkg::mat4x4 fmap='0;
    instrument_e inst=INST_PIANO;
    voice_router #(.SLOTS(4),.N_MODES(64)) dut (
        .clk(clk),.rst_n(rst_n),.fmap(fmap),.inst(inst),.reverb_preset(REVERB_NONE),
        .reload(reload),.start(start),.done(done),.ready(ready),.load_err(load_err),.y_valid(y_valid),.y_data(),
        .table_valid(table_valid),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi),
        .maintenance_clear(1'b0),.map_reload(1'b0),.load_offsets('0),
        .maintenance_done(),.midi_inflight(),.voice_idle(),.load_complete(),
        .midi_select(1'b0),.midi_valid(1'b0),.midi_ready(),.midi_gate(4'd0),
        .midi_velocity(28'd0),.midi_retrigger(4'd0),.midi_hard_clear(4'd0),
        .ns_rd_en(1'b0),.ns_rd_addr(8'd0),.ns_rd_sel(1'b0),.ns_rd_data(),.ns_rd_valid()
    );
    w25q64_read_model #(.N_MODES(64)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(blank),.dq_i(dqi));
    // Cycle equivalence against the old g-update rules. This specifically
    // checks the newly unconditional DONE/LOAD clears across failure/retry.
    logic [1:0] reference_g=0;
    always @(posedge clk)begin
        if(!rst_n)reference_g<=0;
        else begin
            if(dut.g!==reference_g)$fatal(1,"FAIL voice-index cycle equivalence");
            case(dut.state)
                dut.S_DONE: if(start)begin
                    if((dut.ld_err || dut.cfg_error) && !dut.reload_pend && inst==dut.inst_lat)begin
                        if(dut.maintain_req && !dut.maintenance_completed)reference_g<=0;
                    end else reference_g<=0;
                end
                dut.S_LOAD: if(dut.ld_done && !dut.ld_err)reference_g<=0;
                dut.S_XS: reference_g<=0;
                dut.S_ADV: if(dut.pick_b)begin
                    if(reference_g+1'b1>=2'd2)begin
                        if(!dut.mix_v)reference_g<=0;
                    end else reference_g<=reference_g+1'b1;
                end
                default:;
            endcase
        end
    end
    always @(posedge clk) if(rst_n && dut.ld_start)loads++;
    task automatic sample;
        wait(done);@(negedge clk);start=1;@(negedge clk);start=0;
        wait(done);@(negedge clk);
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;sample();
        if(load_err || !table_valid)$fatal(1,"FAIL valid boot table");
        fmap.raw=250;sample();inst=INST_GUITAR;sample();
        if(ready || dut.inst_lat!=INST_PIANO || dut.nm_lat!=64)
            $fatal(1,"FAIL pending configuration altered active instrument/mode count");
        fmap='0;
        repeat(3)sample();
        if(dut.inst_prev!=INST_GUITAR || dut.nm_lat!=20 || !table_valid)
            $fatal(1,"FAIL released configuration not committed");
        // 坏表不能修改最近成功身份，持续start也不能无限重载。
        blank=1;inst=INST_PIANO;sample();
        if(!load_err || table_valid || dut.inst_prev!=INST_GUITAR)
            $fatal(1,"FAIL failed load published as successful");
        begin
            integer before_loads;before_loads=loads;
            repeat(4)begin sample();if(y_valid)$fatal(1,"FAIL audio after failed load");end
            if(loads!=before_loads)$fatal(1,"FAIL automatic retry loop");
        end
        blank=0;reload=1;@(negedge clk);reload=0;sample();
        if(load_err || !table_valid || dut.inst_prev!=INST_PIANO)
            $fatal(1,"FAIL explicit reload recovery");
        $display("PASS tb_router_pending_config pending modes, load failure, bounded retry and recovery");$finish;
    end
    initial begin #100000000;$fatal(1,"FAIL pending config timeout");end
endmodule

module tb_pad_load_failure #(parameter logic [31:0] FLASH_BASE=0, parameter int FLASH_BYTES=8_388_608, parameter bit RELOCATED=0);
    import router_pkg::*;
    logic clk=0,rst_n=0,reload=0,blank=1;
    always #5 clk=~clk;
    instrument_e inst=INST_PIANO;
    pad_driver_pkg::mat4x4 fmap='0;
    logic load_err,table_valid,y_valid,done,cs,sck,oe;
    logic [3:0] dqo,dqi;
    logic signed [63:0] y_data;
    integer loads=0;
    pad_voice_top #(.SLOTS(4),.USE_PAD_DRIVER(0),.FLASH_BASE(FLASH_BASE),.FLASH_BYTES(FLASH_BYTES)) dut(
        .clk(clk),.rst_n(rst_n),.inst(inst),.reverb_preset(REVERB_NONE),.reload(reload),.run(1'b1),
        .src_sel(1'b1),.fmap_ext(fmap),.pad_row_s(),.pad_ch_s(),.pad_fmap(),.pad_pos(),.led_dat(),
        .ready(),.busy(),.done(done),.load_err(load_err),.table_valid(table_valid),.y_valid(y_valid),.y_data(y_data),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi),
        .joy_sample_valid(),.joy_raw_x(),.joy_raw_y());
    w25q64_read_model #(.N_MODES(64),.RESOURCE_BASE(FLASH_BASE),.FLASH_BYTES(FLASH_BYTES),.FORBID_PROGRAM_READ(FLASH_BASE!=0)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(blank),.dq_i(dqi));
    always @(posedge clk) if(rst_n)begin
        if(dut.u_voice.ld_start)loads++;
        if(!table_valid && (y_valid || y_data!==64'd0))$fatal(1,"FAIL PAD invalid resource exposed audio");
    end
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        wait(load_err && done);repeat(5000)@(negedge clk);
        if(table_valid || loads!=1)$fatal(1,"FAIL PAD boot fault/retry loop");
        @(negedge clk);blank=0;reload=1;@(negedge clk);reload=0;wait(table_valid);wait(y_valid);
        if(load_err || dut.N_MODES!=64)$fatal(1,"FAIL PAD default depth or recovery");
        blank=1;inst=INST_GUITAR;wait(load_err && done);
        if(table_valid || dut.u_voice.inst_prev!=INST_PIANO)$fatal(1,"FAIL PAD failed switch committed guitar");
        @(negedge clk);blank=0;reload=1;@(negedge clk);reload=0;wait(table_valid);wait(y_valid);
        if(load_err || dut.u_voice.inst_prev!=INST_GUITAR)$fatal(1,"FAIL PAD explicit retry did not recover");
        if(RELOCATED)begin
            if(flash.min_read_address!=FLASH_BASE || flash.max_read_address<FLASH_BASE+16384)
                $fatal(1,"FAIL relocated PAD piano/guitar addresses");
            $display("PASS tb_pad_load_relocated piano/guitar failure/retry min=%h max=%h",flash.min_read_address,flash.max_read_address);
        end else $display("PASS tb_pad_load_failure default64, error exported, no false audio/commit, explicit retry");$finish;
    end
    initial begin #100000000;$fatal(1,"FAIL PAD failure watchdog state=%0d inst=%0d prev=%0d lat=%0d error=%b valid=%b loads=%0d gate=%h",dut.u_voice.state,inst,dut.u_voice.inst_prev,dut.u_voice.inst_lat,load_err,table_valid,loads,dut.u_voice.note_on);end
endmodule
