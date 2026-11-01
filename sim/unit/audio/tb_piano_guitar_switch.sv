`timescale 1ns/1ps
// Actual two-instrument image -> vendor Flash -> production config/loader/eng0/I2S.
module tb_piano_guitar_switch;
    import router_pkg::*;
    import config_pkg::*;
    logic clk=0,audio_clk=0,rst_n=0;
    always #10 clk=~clk;
    always #40 audio_clk=~audio_clk;
    pad_driver_pkg::mat4x4 fmap='0;
    logic request_valid=0,request_ready,response_valid;
    cfg_request_t request='0;
    cfg_response_t response;
    audio_config_t audio_state;
    logic audio_valid,audio_fault,ready,busy,failed,load_err,y_valid;
    logic signed [63:0] y_data;
    logic event_valid=0,event_ready;
    logic [31:0] event_data=0;
    wire cs,sck,oe;
    wire [3:0] dqo,dq;
    wire deadline_miss,overflow,underflow;
    assign dq=oe?dqo:4'bzzzz;
    wire [3:0] flash_data;
    assign dq=oe?4'bzzzz:flash_data;
    w25q64_read_model #(.N_MODES(64),.RESOURCE_BASE(32'h0080_0000),
        .FLASH_BYTES(16777216),.FORBID_PROGRAM_READ(1),
        .MEM_FILE("piano_guitar_16.mem"),.MEM_BYTES(131072)) flash(
        .cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(1'b0),.dq_i(flash_data));
    midi_voice_top #(.CLK_HZ(50_000_000),.AUDIO_ENABLE(1),.CONFIG_BACKEND(1),
        .FLASH_BASE(32'h0080_0000),.FLASH_BYTES(16777216),.PCM_HEADROOM_BITS(0),
        .NOTE_BANKS(0),.RESOURCE_MASK(10'b0000000011),
        .PAD_NOTE_ON_TH(64),.PAD_NOTE_OFF_TH(48)) dut(
        .clk(clk),.audio_clk(audio_clk),.rst_n(rst_n),.run(1'b1),.fmap(fmap),
        .pad_instrument(INST_PIANO),.reverb_preset(REVERB_NONE),
        .reload(1'b0),.midi_select(1'b0),.midi_source_id(1'b0),.panic(1'b0),
        .selected_channel(4'd1),.note_bank(1'b0),.first_midi_note(7'd48),.slot_note_map(default_note_map()),
        .backend_valid(request_valid),.backend_source(1'b0),.backend_ready(request_ready),.backend_request(request),
        .backend_rsp_valid(response_valid),.backend_rsp_ready(1'b1),.backend_response(response),
        .backend_supported(),.backend_audio_valid(audio_valid),.backend_audio_fault(audio_fault),.backend_audio_state(audio_state),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(1'b0),
        .source_cleanup_req(2'b0),.source_cleanup_done(),.source_ops_idle(),.midi_ops_idle(),
        .control_valid(),.control_cancel(),.control_ready(1'b0),.control_data(),.control_source_id(),
        .channel_mapped(),.config_busy(busy),.config_failed(failed),.active_channel(),.active_bank(),
        .rejected_note_count(),.unsupported_count(),.control_timeout_count(),.dropped_count(),.error_sticky(),
        .ready(ready),.done(),.load_err(load_err),.y_valid(y_valid),.y_data(y_data),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_oe(oe),.qspi_dq_o(dqo),.qspi_dq_i(dq),
        .amp_bclk(),.amp_ws(),.amp_din(),.audio_sample_tick(),
        .audio_deadline_miss(deadline_miss),.audio_overflow(overflow),.audio_underflow(underflow));
    byte unsigned golden[0:131071];
    integer loaded=0,checks=0,samples=0,nonzero=0,fd;
    function automatic logic [31:0] word_at(input integer off);
        return {golden[off],golden[off+1],golden[off+2],golden[off+3]};
    endfunction
    task automatic ck(input logic ok,input string msg);
        checks++; if(ok!==1)$fatal(1,"FAIL %s",msg);
    endtask
    // Compare every loaded coefficient AND modulation record against the BIN bytes.
    always @(posedge clk) if(rst_n && dut.u_voice.u_ld.ld_we && !dut.u_voice.u_ld.failed)begin
        integer off;
        off=int'(dut.u_voice.u_ld.inst_r)*65536+int'(dut.u_voice.u_ld.ld_addr[9:0])*64;
        if(!dut.u_voice.u_ld.ld_addr[10])begin
            ck(dut.u_voice.u_ld.ld_co=={word_at(off),word_at(off+4),word_at(off+8),word_at(off+12),word_at(off+16),word_at(off+20),word_at(off+24)},"coefficient bytes match image");
        end else begin
            ck(dut.u_voice.u_ld.ld_pm=={word_at(off+32),word_at(off+36),word_at(off+40),word_at(off+44),word_at(off+48),word_at(off+52),word_at(off+56),word_at(off+60)},"modulation bytes match image");
        end
        loaded++;
    end
    always @(posedge clk) if(rst_n && y_valid)begin
        if($isunknown(y_data))$fatal(1,"FAIL unknown PCM");
        samples++;if(y_data!=0)nonzero++;
        if(fd)$fdisplay(fd,"%0d",y_data);
    end
    task automatic config_set(input logic [15:0] id,input integer value,input logic [7:0] result);
        @(negedge clk);request.tag++;request.id=id;request.value=value;request_valid=1;
        do @(posedge clk);while(!request_ready);
        @(negedge clk);request_valid=0;
        do @(posedge clk);while(!response_valid);
        ck(response.result==result,$sformatf("config %h=%0d result=%0d expected=%0d",id,value,response.result,result));
        @(negedge clk);
    endtask
    task automatic render(input string path,input bit all16);
        integer start_samples,start_nonzero;
        fd=$fopen(path,"w");ck(fd!=0,"open PCM dump");
        start_samples=samples;start_nonzero=nonzero;
        @(negedge clk);
        for(integer i=0;i<16;i++)fmap.raw[i*8+:8]=(all16 || i==4)?8'd255:0;
        wait(samples>=start_samples+256);
        @(negedge clk);fmap='0;
        wait(samples>=start_samples+768);
        ck(nonzero>start_nonzero,"real instrument produces PCM");
        ck(!failed && !load_err && !audio_fault,"no config/load fault");
        ck(!deadline_miss && !overflow && !underflow,"I2S real-time diagnostics clear");
        $fclose(fd);fd=0;
    endtask
    initial begin
        fd=0;$readmemh("piano_guitar_16.mem",golden);
        repeat(10)@(negedge clk);rst_n=1;
        wait(audio_valid && ready);ck(audio_state.instrument==0,"boot piano");
        ck(loaded==2048,"all piano records loaded");
        render("piano_pcm.txt",0);
        render("piano_all16_pcm.txt",1);
        config_set(16'h0100,1,CFG_OK);ck(audio_state.instrument==1,"PAD switched to guitar");
        render("guitar_pcm.txt",0);
        render("guitar_all16_pcm.txt",1);
        config_set(16'h0100,2,CFG_UNSUPPORTED);ck(audio_state.instrument==1 && audio_valid,"unsupported instrument preserves guitar");
        config_set(16'h0300,1,CFG_UNSUPPORTED);ck(audio_state.bank==0,"legacy bank remains zero");
        config_set(16'h0100,0,CFG_OK);ck(audio_state.instrument==0,"PAD back to piano");
        config_set(16'h0500,1,CFG_OK);ck(audio_state.instrument==0 && audio_state.channel==2,"wired source keeps piano channel2");
        config_set(16'h0100,1,CFG_OK);ck(audio_state.instrument==1 && audio_state.channel==1,"MIDI guitar maps channel1");
        @(negedge clk);event_data={4'd1,4'd0,7'd48,7'd100,10'd0};event_valid=1;
        do @(posedge clk);while(!event_ready);
        @(negedge clk);event_valid=0;
        begin integer before_nonzero,before_samples;
            before_nonzero=nonzero;before_samples=samples;wait(samples>=before_samples+512);
            ck(nonzero>before_nonzero,"MIDI guitar produces PCM");
        end
        config_set(16'h0100,0,CFG_OK);ck(audio_state.channel==2,"MIDI piano maps channel2");
        config_set(16'h0500,0,CFG_OK);ck(audio_state.instrument==0,"return PAD piano");
        // Simulate an erased guitar record without changing the DUT or loader.
        for(integer i=65536;i<65600;i++)flash.memory[i]=8'hff;
        config_set(16'h0100,1,CFG_FAILED);
        ck(audio_fault && !audio_valid && failed,"blank Flash faults instead of committing guitar");
        repeat(100)begin @(posedge clk);ck(!y_valid || y_data==0,"fault output silent");end
        for(integer i=65536;i<65600;i++)flash.memory[i]=golden[i];
        config_set(16'h8001,0,CFG_OK);
        ck(audio_valid && !audio_fault && audio_state.instrument==0,"clear recovers last committed piano");
        ck(!deadline_miss && !overflow && !underflow,"final audio diagnostics clear");
        $display("PASS tb_piano_guitar_switch checks=%0d loaded=%0d samples=%0d",checks,loaded,samples);$finish;
    end
    initial begin #1_500_000_000;$fatal(1,"FAIL phase1 watchdog state=%0d",dut.cfg_state);end
endmodule
