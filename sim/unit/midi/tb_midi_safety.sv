`timescale 1ns/1ps
// Production top, 16 slots, 32 pitches. Exercise the previously reproduced stalls.
module tb_midi_safety;
    import router_pkg::*;
    logic clk=0,rst_n=0,run=1,reload=0,midi_select=1,midi_source_id=0,panic=0,note_bank=0;
    always #5 clk=~clk;
    pad_driver_pkg::mat4x4 fmap='0;
    logic [3:0] selected_channel=1;
    logic [6:0] first_midi_note=48;
    logic [111:0] slot_note_map=0;
    logic event_valid=0,event_ready,event_source_id=0;
    logic [31:0] event_data=0;
    logic [1:0] source_cleanup_req=0,source_cleanup_done,source_ops_idle;
    logic midi_ops_idle,control_valid,control_cancel,control_ready=0,control_source_id;
    logic [31:0] control_data,rejected_note_count,unsupported_count,control_timeout_count,dropped_count;
    logic [3:0] error_sticky,active_channel;
    logic channel_mapped,config_busy,config_failed,active_bank,ready,done,load_err,y_valid;
    logic signed [63:0] y_data;
    logic cs,sck,oe,blank=0;
    logic [3:0] dqo,dqi;
    integer checks=0,cancelled=0;
    midi_voice_top #(.SLOTS(16),.N_MODES(4),.CLK_HZ(10_000_000),.SR_HZ(10_000),
        .NOTE_BANKS(1),.CONTROL_SUPPORTED(5'b10000),.CONTROL_TIMEOUT_CYCLES(64),
        .OP_TIMEOUT_CYCLES(5000),.CONFIG_TIMEOUT_CYCLES(100000)) dut (
        .clk(clk),.rst_n(rst_n),.run(run),.reload(reload),.midi_select(midi_select),
        .midi_source_id(midi_source_id),.panic(panic),.note_bank(note_bank),.first_midi_note(first_midi_note),
        .fmap(fmap),.pad_instrument(INST_PIANO),.reverb_preset(REVERB_NONE),
        .backend_valid(1'b0),.backend_source(1'b0),.backend_ready(),.backend_request('0),
        .backend_rsp_valid(),.backend_rsp_ready(1'b1),.backend_response(),.backend_supported(),
        .backend_audio_valid(),.backend_audio_fault(),.backend_audio_state(),
        .selected_channel(selected_channel),.slot_note_map(slot_note_map),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.event_source_id(event_source_id),
        .source_cleanup_req(source_cleanup_req),.source_cleanup_done(source_cleanup_done),.source_ops_idle(source_ops_idle),
        .midi_ops_idle(midi_ops_idle),.control_valid(control_valid),.control_cancel(control_cancel),.control_ready(control_ready),
        .control_data(control_data),.control_source_id(control_source_id),.channel_mapped(channel_mapped),
        .config_busy(config_busy),.config_failed(config_failed),.active_channel(active_channel),.active_bank(active_bank),
        .rejected_note_count(rejected_note_count),.unsupported_count(unsupported_count),
        .control_timeout_count(control_timeout_count),.dropped_count(dropped_count),.error_sticky(error_sticky),
        .ready(ready),.done(done),.load_err(load_err),.y_valid(y_valid),.y_data(y_data),
        .qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_oe(oe),.qspi_dq_o(dqo),.qspi_dq_i(dqi)
    );
    w25q64_read_model #(.N_MODES(4)) flash(.cs_n(cs),.sck(sck),.dq_o(dqo),.dq_oe(oe),.blank(blank),.dq_i(dqi));
    always @(posedge clk) if(rst_n && control_cancel) cancelled++;
    task automatic ck(input logic ok,input string msg);
        checks++;if(ok!==1'b1) $fatal(1,"FAIL %s checks=%0d cfg=%0d voice=%0d load_err=%0b clear=%0b/%0b notes_done=%b",
            msg,checks,dut.cfg_state,dut.u_voice.state,load_err,dut.maint_seen,dut.maintenance_done,dut.state_cleanup_done);
    endtask
    task automatic configured;
        while(config_busy) @(negedge clk);
        ck(!config_failed,"configuration completed successfully");
        while(!midi_ops_idle) @(negedge clk);
    endtask
    task automatic send(input bit source,input integer kind,ch,d1,d2);
        @(negedge clk);event_source_id=source;event_data={kind[3:0],ch[3:0],d1[6:0],d2[6:0],10'b0};event_valid=1;
        while(!event_ready) @(negedge clk);
        @(negedge clk);event_valid=0;
    endtask
    task automatic drained;
        while(!midi_ops_idle) @(negedge clk);
        @(negedge clk);
    endtask
    task automatic retry;
        @(negedge clk);reload=1;@(negedge clk);reload=0;
        wait(config_busy);configured();
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;configured();
        ck(active_channel==1 && active_bank==0,"only commit loaded bank/channel");
        ck(dut.u_voice.ca_a11_b[0]==32'h10080000,"lower bank Flash source at slot8");
        // Stable numerical fixture; coefficient RAM itself is still checked above/below.
        force dut.u_voice.co_ra={32'd268435456,32'd0,32'd0,32'd268435456,32'd1073741824,32'd0,32'd32768};
        force dut.u_voice.co_rb={32'd268435456,32'd0,32'd0,32'd268435456,32'd1073741824,32'd0,32'd32768};
        send(0,4,2,0,64);drained();
        ck(!control_valid && control_timeout_count==0,"unselected channel control cannot reach global backend");
        send(0,1,1,60,80);drained();
        send(0,2,1,7,100);send(0,0,1,60,0);drained();
        ck(unsupported_count==1 && !dut.u_notes.slot_gate[12],"unsupported CC7 cannot block following Off");
        send(0,1,1,60,80);drained();send(0,4,1,0,64);
        wait(control_valid);repeat(80) @(negedge clk);
        ck(control_timeout_count==1 && cancelled>0,"supported unresponsive control times out and cancels");
        send(0,0,1,60,0);drained();
        ck(!dut.u_notes.slot_gate[12],"Off after timeout is consumed");
        // Cleanup preempts a control before its normal timeout, even with run=0.
        send(0,1,1,60,80);drained();send(0,4,1,0,64);wait(control_valid);
        @(negedge clk);source_cleanup_req=1;run=0;
        wait(source_cleanup_done[0]);@(negedge clk);
        ck(control_timeout_count==1 && !control_valid,"cleanup cancelled pending control without timeout");
        for(integer m=0;m<4;m++) ck(dut.u_voice.q_ram_b[16+m]==0,"cleanup ack waits for actual target state zero");
        ck(dut.u_notes.slot_owned==0,"cleanup removed ownership");
        ck(midi_ops_idle,"already cleaned quarantined source does not block peer CONFIG barrier");
        run=1;retry();
        ck(!load_err && source_cleanup_done[0],"held cleaned quarantine does not abort recovery reload");
        source_cleanup_req=0;run=1;repeat(4) @(negedge clk);
        send(1,1,1,60,80);drained();
        ck(dut.u_notes.slot_gate==0 && dropped_count>0,"unselected physical MIDI source drained");
        // Holding a key while switching groups must not replay the old note.
        send(0,1,1,60,100);drained();note_bank=1;
        wait(config_busy);
        ck(active_bank==0,"active bank stays old until loading succeeds");
        configured();
        ck(active_bank==1 && dut.u_notes.slot_owned==0,"upper bank committed after old notes clear");
        ck(dut.u_voice.ca_a11_b[0]==32'h10180000,"upper bank uses pitches16..31 without changing destination slots");
        send(0,1,1,60,80);drained();
        ck(rejected_note_count==1,"note from nonloaded half rejected");
        send(0,1,1,76,80);drained();
        ck(dut.u_notes.slot_gate[12],"upper-half note uses same slot12");
        // Panic must make progress while ordinary run is stopped.
        run=0;panic=1;@(negedge clk);panic=0;wait(config_busy);configured();
        ck(dut.u_notes.slot_owned==0,"panic with run=0 retired");run=1;
        midi_select=0;wait(config_busy);configured();
        send(0,1,1,76,80);drained();
        ck(event_ready && dut.u_notes.slot_owned==0,"PAD mode drains MIDI head");
        midi_select=1;wait(config_busy);configured();
        // Broken Flash must not publish a new bank as active or report success.
        blank=1;note_bank=0;wait(config_busy);wait(!config_busy);
        ck(config_failed && active_bank==1 && load_err && event_ready,"load failure leaves old active identity and drains input");
        blank=0;retry();ck(active_bank==0,"explicit retry recovers failed bank load");
        // A missing sample boundary is finite failure, not an eternal hidden stall.
        send(0,1,1,60,80);force dut.u_voice.smp_tick=0;
        wait(config_failed);
        ck(error_sticky[2] && error_sticky[3] && source_cleanup_done==0,"stalled execution faults without false cleanup ack");
        release dut.u_voice.smp_tick;retry();
        ck(dut.u_notes.slot_owned==0,"late cancelled On not replayed after recovery");
        send(0,1,1,60,80);drained();
        force dut.u_voice.smp_tick=0;source_cleanup_req=1;run=0;
        wait(config_failed);
        ck(source_cleanup_done==0,"stalled cleanup reports fault, never success");
        release dut.u_voice.smp_tick;source_cleanup_req=0;retry();run=1;
        $display("PASS tb_midi_safety checks=%0d unsupported=%0d timeouts=%0d dropped=%0d",checks,unsupported_count,control_timeout_count,dropped_count);$finish;
    end
    initial begin #20000000;$fatal(1,"FAIL safety watchdog cfg=%0d voice=%0d op=%0d",dut.cfg_state,dut.u_voice.state,dut.op_valid);end
endmodule
