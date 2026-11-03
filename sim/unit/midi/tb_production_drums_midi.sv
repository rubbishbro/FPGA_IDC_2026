`timescale 1ns/1ps
module tb_production_drums_midi;
    import router_pkg::*;import config_pkg::*;
    logic clk=0,rst_n=0;always #5 clk=~clk;
    logic backend_valid=0,backend_ready,backend_rsp_valid,audio_valid;
    cfg_request_t request='0;cfg_response_t response;audio_config_t audio_state;
    logic keymap_valid=0,keymap_ready,keymap_rsp_valid;logic[7:0] keymap_result;
    logic[255:0] keys='0;
    logic event_valid=0,event_ready,ops_idle;logic[31:0] event_data=0;
    logic[1:0] cleanup=0,cleanup_done;
    logic[3:0] flash_i;logic y_valid;logic signed[63:0] y;
    int outputs=0,nonzero=0,tag=0;
    pad_driver_pkg::mat4x4 fmap='0;
    midi_voice_top #(.SLOTS(16),.N_MODES(64),.CLK_HZ(100_000_000),.SR_HZ(48000),
        .NOTE_BANKS(1),.INSTRUMENT_NOTE_RANGES(1),.RESOURCE_MASK(12'hfff),.CONFIG_BACKEND(1),
        .FLASH_BASE(32'h800000),.FLASH_BYTES(16_777_216)) dut(
        .clk(clk),.rst_n(rst_n),.run(1'b1),.audio_clk(clk),.fmap(fmap),.pad_instrument(INST_PIANO),
        .reverb_preset(REVERB_NONE),.reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),
        .selected_channel(4'd1),.note_bank(1'b0),.first_midi_note(7'd44),.slot_note_map('0),
        .backend_valid(backend_valid),.backend_source(1'b0),.backend_source_valid(1'b1),.backend_request(request),
        .backend_ready(backend_ready),.backend_rsp_valid(backend_rsp_valid),.backend_rsp_ready(1'b1),.backend_response(response),
        .backend_audio_valid(audio_valid),.backend_audio_state(audio_state),
        .keymap_valid(keymap_valid),.keymap_ready(keymap_ready),.keymap_entries(keys),.keymap_rsp_valid(keymap_rsp_valid),
        .keymap_rsp_ready(1'b1),.keymap_cancel(1'b0),.keymap_result(keymap_result),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(1'b0),
        .source_cleanup_req(cleanup),.source_cleanup_done(cleanup_done),.midi_ops_idle(ops_idle),
        .control_ready(1'b0),.y_valid(y_valid),.y_data(y),.qspi_dq_i(flash_i));
    w25q64_read_model #(.N_MODES(64),.MEM_FILE("resources.mem"),.MEM_BYTES(1576960),
        .RESOURCE_BASE(32'h800000),.FLASH_BYTES(16_777_216),.FORBID_PROGRAM_READ(1)) flash(
        .cs_n(dut.qspi_cs_n),.sck(dut.qspi_sck),.dq_o(dut.qspi_dq_o),.dq_oe(dut.qspi_dq_oe),.blank(1'b0),.dq_i(flash_i));
    always @(posedge clk)if(rst_n && y_valid)begin outputs++;if(y!=0)nonzero++;end
    task automatic config_set(input int id,value);
        @(negedge clk);wait(backend_ready);tag++;request={16'(tag),16'(id),32'(value)};backend_valid=1;
        @(negedge clk);backend_valid=0;wait(backend_rsp_valid);#1;
        if(response.result!=0)$fatal(1,"FAIL config id=%0h result=%0d",id,response.result);
        @(negedge clk);wait(audio_valid);
    endtask
    task automatic frames(input int count);int target;target=outputs+count;wait(outputs>=target);@(negedge clk);endtask
    task automatic send(input int kind,note);
        @(negedge clk);event_data={4'(kind),4'd9,7'(note),7'd127,10'b0};event_valid=1;
        do @(posedge clk);while(!event_ready);
        @(negedge clk);event_valid=0;wait(ops_idle);@(negedge clk);
    endtask
    task automatic table_send(input int expected);
        @(negedge clk);wait(keymap_ready);keymap_valid=1;
        @(negedge clk);keymap_valid=0;wait(keymap_rsp_valid);#1;
        if(keymap_result!=expected)$fatal(1,"FAIL keymap result=%0d",keymap_result);
        @(negedge clk);wait(audio_valid);
    endtask
    initial begin
        repeat(8)@(negedge clk);rst_n=1;wait(audio_valid);
        config_set('h0100,7);
        for(int i=0;i<16;i++)begin
            if(dut.note_map[i*7 +:7]!=drum_note_of(3'(i%6)) || dut.offsets[i*32 +:32]!=(i%6)*4096)
                $fatal(1,"FAIL default GM offset");
            keys[i*16 +:16]={1'b0,drum_note_of(3'((15-i)%6)),8'd7};
        end
        // Invalid GM note must reject the entire table without changing the binding.
        keys[15:8]=8'd35;table_send(3);
        keys[15:8]={1'b0,drum_note_of(3'(15%6))};table_send(0);
        for(int i=0;i<16;i++)begin
            if(dut.note_map[i*7 +:7]!=drum_note_of(3'((15-i)%6)) || dut.offsets[i*32 +:32]!=((15-i)%6)*4096)
                $fatal(1,"FAIL custom GM offset");
        end
        config_set('h0501,10);config_set('h0500,1);
        if(audio_state.instrument!=7 || audio_state.channel!=10)$fatal(1,"FAIL drum channel commit");
        for(int i=0;i<6;i++)send(1,drum_note_of(3'(i)));
        frames(128);if(nonzero==0 || $countones(dut.gate)!=6)$fatal(1,"FAIL drums did not sound");
        for(int i=0;i<6;i++)send(0,drum_note_of(3'(i)));
        frames(16);
        if(dut.gate!=0 || dut.hard_clear!=0 || dut.u_voice.env_dead==16'hffff || dut.voice_idle==16'hffff)
            $fatal(1,"FAIL Note Off bypassed release");
        cleanup=1;wait(cleanup_done[0]);@(negedge clk);
        if(dut.voice_idle!=16'hffff)$fatal(1,"FAIL cleanup not retired");
        $display("PASS tb_production_drums_midi default/custom GM offsets, invalid rejection, channel10, 6 drums sound, Note Off release, cleanup");$finish;
    end
    initial begin #3000000000;$fatal(1,"FAIL MIDI drum timeout state=%0d",dut.cfg_state);end
endmodule
