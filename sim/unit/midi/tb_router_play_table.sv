`timescale 1ns/1ps
module tb_router_play_table #(parameter int MODES=64);
    import router_pkg::*;
    localparam int SLOTS=4, TBL_BYTES=SLOTS*MODES*64;
    localparam int MEM_BYTES=12*TBL_BYTES+4096;
    logic clk=0,rst_n=0,start=0,reload=0,sample_tick=0,maintenance=0;
    always #5 clk=~clk;
    instrument_e inst=INST_FLUTE;
    pad_driver_pkg::mat4x4 fmap='0;
    logic valid,ref_valid,error,ref_error,yv,ref_yv,done,ref_done;
    logic signed [63:0] y,ref_y;
    logic cs,sck,oe,ref_cs,ref_sck,ref_oe;
    logic [3:0] dqo,dqi,ref_dqo,ref_dqi;
    integer cycles=0,loads=0,publications=0,last_write=-1;
    integer cfg_tick_overlap=0,done_tick_overlap=0,invalid_ticks=0,driven_ticks=0;
    integer stage=0;
    logic [SLOTS-1:0] written=0;
    bit previous_valid=0;
    wire loading=dut.state.name()=="S_LOAD";

    voice_router #(.SLOTS(SLOTS),.N_MODES(MODES),.CLK_HZ(4_000_000),
        .EXTERNAL_SAMPLE_TICK(1),.MIDI_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.sample_tick(sample_tick),
        .fmap(fmap),.inst(inst),.reverb_preset(REVERB_NONE),.reload(reload),
        .record_snapshot_valid(),.record_snapshot_gate(),.record_snapshot_level(),.record_snapshot_notes(),
        .pad_keys_down(),.slot_note_map((SLOTS*7)'(router_pkg::default_note_map())),
        .table_valid(valid),.load_err(error),.done(done),.ready(),
        .y_valid(yv),.y_data(y),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_o(dqo),.qspi_dq_oe(oe),.qspi_dq_i(dqi),
        .maintenance_clear(maintenance),.map_reload(1'b0),.load_offsets('0),
        .midi_select(1'b0),.midi_valid(1'b0),.midi_ready(),.midi_gate('0),.midi_velocity('0),
        .midi_retrigger('0),.midi_hard_clear('0),
        .pitch_control_valid(1'b0),.pitch_control_cancel(1'b0),.pitch_control_source(1'b0),
        .pitch_control_data(32'd0),.pitch_slot_source('0),.pitch_cleanup(2'd0),
        .pitch_control_ready(),.pitch_control_rejected(),
        .maintenance_done(),.midi_inflight(),.load_complete(),.voice_idle(),
        .ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0));
    voice_router_reference #(.SLOTS(SLOTS),.N_MODES(MODES),.CLK_HZ(4_000_000),
        .EXTERNAL_SAMPLE_TICK(1),.MIDI_ENABLE(1)) reference(
        .clk(clk),.rst_n(rst_n),.start(start),.sample_tick(sample_tick),
        .fmap(fmap),.inst(inst),.reverb_preset(REVERB_NONE),.reload(reload),
        .record_snapshot_valid(),.record_snapshot_gate(),.record_snapshot_level(),.record_snapshot_notes(),
        .pad_keys_down(),.slot_note_map((SLOTS*7)'(router_pkg::default_note_map())),
        .table_valid(ref_valid),.load_err(ref_error),.done(ref_done),.ready(),
        .y_valid(ref_yv),.y_data(ref_y),
        .qspi_cs_n(ref_cs),.qspi_sck(ref_sck),.qspi_dq_o(ref_dqo),.qspi_dq_oe(ref_oe),.qspi_dq_i(ref_dqi),
        .maintenance_clear(maintenance),.map_reload(1'b0),.load_offsets('0),
        .midi_select(1'b0),.midi_valid(1'b0),.midi_ready(),.midi_gate('0),.midi_velocity('0),
        .midi_retrigger('0),.midi_hard_clear('0),
        .pitch_control_valid(1'b0),.pitch_control_cancel(1'b0),.pitch_control_source(1'b0),
        .pitch_control_data(32'd0),.pitch_slot_source('0),.pitch_cleanup(2'd0),
        .pitch_control_ready(),.pitch_control_rejected(),
        .maintenance_done(),.midi_inflight(),.load_complete(),.voice_idle(),
        .ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0));
    w25q64_read_model #(.N_MODES(MODES),.MEM_FILE("play_table.mem"),.MEM_BYTES(MEM_BYTES)) flash(
        .cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(1'b0),.dq_i(dqi));
    w25q64_read_model #(.N_MODES(MODES),.MEM_FILE("play_table.mem"),.MEM_BYTES(MEM_BYTES)) ref_flash(
        .cs_n(ref_cs),.sck(ref_sck),.dq_o(ref_dqo),.dq_oe(ref_oe),.blank(1'b0),.dq_i(ref_dqi));

    // An in-memory image still travels over the real QSPI protocol and decode.
    // Force parameter-write and publication boundaries to coincide with sample
    // snapshots as well as exercising ordinary spaced audio sample pulses.
    always @(negedge clk)
        sample_tick=rst_n && ((cycles%211==0) ||
            (dut.u_ld.st.name()=="W_WR" && !dut.u_ld.wr_sel && dut.u_ld.mode_i==2) ||
            dut.u_ld.st.name()=="W_END");

    always @(posedge clk) begin : monitor
        bit wrote;
        integer slot;
        sustain_cfg_t payload;
        cycles++;
        wrote=rst_n && loading && dut.ld_cfg_we;
        slot=int'(dut.ld_cfg_slot);payload=dut.ld_cfg_data;
        if(!rst_n)begin written=0;previous_valid=0;last_write=-1;end
        else begin
            if(dut.state.name()=="S_CFG")written=0;
            if(dut.ld_start)loads++;
            if(wrote)begin
                written[slot]=1;last_write=cycles;
                if(dut.smp_tick_q)cfg_tick_overlap++;
            end
            if(dut.ld_done && dut.smp_tick_q)done_tick_overlap++;
            if(dut.part_tick && (|dut.part_clear) && !valid)invalid_ticks++;
            if(valid && dut.part_tick && (|dut.xmap) && (|dut.emap))driven_ticks++;
        end
        #1;
        if(rst_n)begin
            if({valid,error,done,yv,dut.state,dut.part_tick,dut.part_clear,dut.part_gate} !==
               {ref_valid,ref_error,ref_done,ref_yv,reference.state,reference.part_tick,reference.part_clear,reference.part_gate})
                $fatal(1,"FAIL controller/publication mismatch cycle=%0d",cycles);
            if(dut.xmap!==reference.xmap || dut.emap!==reference.emap ||
               dut.env_dead!==reference.env_dead)
                $fatal(1,"FAIL parameter consumer mismatch cycle=%0d",cycles);
            if(y!==ref_y)$fatal(1,"FAIL audio data mismatch cycle=%0d",cycles);
            if(!valid && (yv || y!==0))$fatal(1,"FAIL partial table exposed audio");
            if(wrote && dut.active_play[slot]!==payload)
                $fatal(1,"FAIL direct parameter slot write");
            if(valid)begin
                for(int i=0;i<SLOTS;i++)
                    if(dut.active_play[i]!==reference.active_play[i])
                        $fatal(1,"FAIL published parameter mismatch slot=%0d",i);
                if(!previous_valid)begin
                    if(written!=='1 || last_write>=cycles)
                        $fatal(1,"FAIL publication before complete parameter writes");
                    publications++;
                end
            end
            previous_valid=valid;
        end
    end

    task automatic word(input integer address,input logic [31:0] value);
        for(int b=0;b<4;b++)begin
            flash.memory[address+b]=value[31-b*8 -:8];
            ref_flash.memory[address+b]=value[31-b*8 -:8];
        end
    endtask
    task automatic profiles(input integer version,input integer bad_slot);
        for(int instrument=2;instrument<=3;instrument++)
            for(int slot=0;slot<SLOTS;slot++)begin
                word(instrument*TBL_BYTES+slot*MODES*64+28,
                     32'h10000+32'(80+version*10+slot));
                word(instrument*TBL_BYTES+slot*MODES*64+64+28,32'd67108864);
                word(instrument*TBL_BYTES+slot*MODES*64+128+28,
                     slot==bad_slot ? 32'd0 : 32'd33554432);
            end
    endtask
    task automatic request_reload;
        @(negedge clk);reload=1;@(negedge clk);reload=0;
        while(valid || !loading)@(negedge clk);
    endtask
    task automatic successful;
        wait(valid);@(negedge clk);
        if(error)$fatal(1,"FAIL successful transaction flagged error");
        for(int i=0;i<SLOTS;i++)
            if(!dut.active_play[i].valid || dut.active_play[i].period<2 ||
               dut.active_play[i].r_step==0)$fatal(1,"FAIL incomplete published slot");
    endtask
    initial begin
        #1;
        // Stable synthetic eng1 coefficients plus deterministic global table.
        for(int a=0;a<MEM_BYTES;a++)begin flash.memory[a]=0;ref_flash.memory[a]=0;end
        for(int instrument=2;instrument<=3;instrument++)
            for(int slot=0;slot<SLOTS;slot++)
                for(int mode=0;mode<MODES;mode++)begin
                    word(instrument*TBL_BYTES+slot*MODES*64+mode*64,32'd16777216);
                    word(instrument*TBL_BYTES+slot*MODES*64+mode*64+4,-32'sd16752000);
                end
        profiles(0,-1);
        repeat(5)@(negedge clk);rst_n=1;start=1;
        successful();stage=1;
        // Hold through more than one complete 80-sample excitation period,
        // so a later impulse overlaps a nonzero envelope as well as onset.
        fmap.raw=250;repeat(30000)@(negedge clk);fmap='0;
        repeat(3000)@(negedge clk);

        // A bad final slot must poison the whole publication, not just itself.
        profiles(1,SLOTS-1);stage=2;request_reload();stage=3;
        wait(error && done);repeat(600)@(negedge clk);
        if(valid || dut.active_play[SLOTS-1].r_step!=0)
            $fatal(1,"FAIL invalid final slot published or not transported");
        begin
            integer old_loads;old_loads=loads;
            repeat(1000)@(negedge clk);
            if(valid || loads!=old_loads)$fatal(1,"FAIL failure auto-retry/validation");
        end
        profiles(2,-1);stage=4;request_reload();successful();stage=5;

        // Warm reset after several slots have overwritten the unpublished table.
        profiles(3,-1);stage=6;request_reload();
        wait(written[1]);@(negedge clk);rst_n=0;
        repeat(5)@(negedge clk);
        profiles(4,-1);rst_n=1;
        successful();stage=7;
        if(dut.active_play[0].period!=120)$fatal(1,"FAIL reset reused partial transaction");

        // Real loader abort after partial writes, then explicit recovery.
        profiles(5,-1);stage=8;request_reload();wait(written[1]);stage=9;
        @(negedge clk);maintenance=1;
        wait(error && done);@(negedge clk);maintenance=0;
        repeat(600)@(negedge clk);
        if(valid)$fatal(1,"FAIL aborted table published");
        profiles(6,-1);stage=10;request_reload();successful();stage=11;
        if(publications!=4 || cfg_tick_overlap<4 || done_tick_overlap<4 || invalid_ticks==0 || driven_ticks==0)
            $fatal(1,"FAIL missing transaction/boundary coverage %0d %0d %0d %0d",
                   publications,cfg_tick_overlap,done_tick_overlap,invalid_ticks);
        $display("PASS tb_router_play_table MODES=%0d publications=%0d cfg_tick=%0d done_tick=%0d invalid_ticks=%0d driven_ticks=%0d success_last_slot_failure_reset_abort_retry_cycle_equivalence",
                 MODES,publications,cfg_tick_overlap,done_tick_overlap,invalid_ticks,driven_ticks);
        $finish;
    end
    initial begin #100000000;$fatal(1,"FAIL single table watchdog stage=%0d state=%0d error=%b valid=%b loads=%0d pubs=%0d gate=%h",stage,dut.state,error,valid,loads,publications,dut.pad_note_on);end
endmodule
