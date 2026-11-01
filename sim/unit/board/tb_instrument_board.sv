`timescale 1ns/1ps
module tb_instrument_board #(parameter bit GUIDE_TEST=0, RECORD_TEST=0);
    logic pad_enabled=1;
    import config_pkg::*;
    logic clk=0,rst_n=0,key0=1,key1=1;
    always #10 clk=~clk;
    logic [1:0] rx=3;
    wire [1:0] tx;
    wire [3:0] pad_row;
    wire [2:0] pad_ch;
    wire led,cs,sck,bclk,ws,din,sd,lclk,de;
    wire db,dw,dd,pa;
    wire [5:0] r,g,b;
    tri [3:0] dq;
    logic blank=0;
    wire [3:0] flash_data;
    instrument_board_top #(.BAUD(1_562_500),.KEY_DEBOUNCE(2),.KEY_LONG(24)) dut(
        .clk(clk),.rst_n(rst_n),.key0(key0),.key1(key1),.uart_rx(rx),.uart_tx(tx),.bt_state(1'b0),
        .pad_row(pad_row),.pad_ch(pad_ch),.led_dat(led),.flash_cs_n(cs),.flash_sck(sck),.flash_dq(dq),
        .amp_bclk(bclk),.amp_ws(ws),.amp_din(din),.amp_sd(sd),.dac_bck(db),.dac_ws(dw),.dac_din(dd),.dac_pa_en(pa),.lcd_clk(lclk),.lcd_en(de),.lcd_r(r),.lcd_g(g),.lcd_b(b));
    initial if(dut.u_system.u_ui.u_joystick.SWAP_XY!=1 || dut.u_system.u_ui.u_joystick.INVERT_X!=1 || dut.u_system.u_ui.u_joystick.INVERT_Y!=0)
        $fatal(1,"FAIL board joystick XY orientation not connected");
    initial if(dut.u_system.u_sound.PCM_HEADROOM_BITS!=3 || dut.u_system.u_timing.ROTATE_180!=1)
        $fatal(1,"FAIL board six-timbre PCM/rotated LCD profile not connected");
    w25q64_read_model #(.N_MODES(64),.RESOURCE_BASE(32'h0080_0000),.FLASH_BYTES(16_777_216),.FORBID_PROGRAM_READ(1),.WRITE_NS(20_000_000),.MEM_FILE("performance_resources.mem"),.MEM_BYTES(786432)) flash(
        .cs_n(cs),.sck(sck),.dq_o(dq),.dq_oe(dut.u_system.flash_oe),.blank(blank),.dq_i(flash_data));
    assign dq=(!cs && !dut.u_system.flash_oe) ? flash_data : 4'bzzzz;
    integer pt_frames,pt_nonzero,pt_different;
    pt8211_scoreboard pt_wire(dut.clk_audio,dut.u_system.u_sound.g_audio.u_audio.arst_n,
        db,dw,dd,dut.u_system.u_sound.g_audio.u_audio.rready,
        dut.u_system.u_sound.g_audio.u_audio.rvalid?dut.u_system.u_sound.g_audio.u_audio.rdata:32'd0,
        pt_frames,pt_nonzero,pt_different);
    always @(negedge dut.clk_core)if(pa!==sd)$fatal(1,"FAIL headphone enable/mute connection");
    integer recording_wire_file;
    initial if(RECORD_TEST)recording_wire_file=$fopen("recording_uart.hex","w");
    integer perf_starts=0,perf_ons=0,perf_offs=0,perf_ends=0;
    logic [31:0] perf_first_on_tick=0;
    integer replies[2],nb[2],cfg_commits=0,nonzero=0,samples=0,display_frames=0;
    longint unsigned sample_peak=0;
    logic [7:0] reply_bytes[2][40],last_result[2];
    logic [15:0] last_seq[2];
    logic started[2],escaped[2];
    logic pcm_pending=0;
    logic [15:0] last_pcm=0;
    wire active=dut.u_system.audio_valid && !dut.u_system.u_sound.maintain_req;
    wire sample_tick=dut.u_system.u_sound.audio_sample_tick;
    wire [15:0] expected_pcm=active && pcm_pending ? last_pcm : 16'd0;
    integer pcm_frames,pcm_nonzero,checked_pcm_frames,checked_pcm_nonzero;
    i2s_scoreboard wire_check(dut.clk_core,dut.u_system.core_n,bclk,ws,din,sample_tick,expected_pcm,pcm_frames,pcm_nonzero);
    always @(posedge dut.clk_core)begin
        logic signed [99:0] scaled;
        if(!dut.u_system.core_n || !active)begin pcm_pending<=0;last_pcm<=0;end
        else begin
            if(dut.u_system.sample_valid)begin
                // Independent centered Q8 gain, then a SINGLE rounding to PCM16.
                scaled=(100'($signed(dut.u_system.sample_value))*100'sd256+
                        (100'sd1<<(16+dut.PCM_HEADROOM_BITS)))>>>(17+dut.PCM_HEADROOM_BITS);
                last_pcm<=scaled>32767 ? 16'h7fff : scaled< -32768 ? 16'h8000 : 16'(scaled);pcm_pending<=1;
            end
            if(sample_tick)pcm_pending<=0;
        end
    end
    wire [1:0] byte_valid;
    wire [15:0] byte_data;
    function automatic logic [15:0] crc(input logic [15:0] old,input logic [7:0] val);
        logic [15:0] c;
        c=old^{val,8'b0};for(int j=0;j<8;j++)c=c[15]?(c<<1)^16'h1021:c<<1;
        return c;
    endfunction
    for(genvar source=0;source<2;source++)begin:g_decode
        comm_uart_rx #(.CLK_HZ(50_000_000),.BAUD(1_562_500),.OVERSAMPLE(16)) decoder(
            .clk(dut.clk_core),.rst_n(dut.u_system.core_n),.rx_i(tx[source]),.rx_stb(byte_valid[source]),
            .rx_data(byte_data[source*8 +:8]),.framing_err(),.break_detect(),.false_start());
        always @(posedge dut.clk_core)if(dut.u_system.core_n && byte_valid[source])begin
            logic [7:0] val;
            logic [15:0] checksum;
            val=byte_data[source*8 +:8];
            if(RECORD_TEST && source==0)$fdisplay(recording_wire_file,"%02x",val);
            if(val==8'hc0)begin
                if(started[source] && nb[source]>0)begin
                    if(RECORD_TEST && reply_bytes[source][1]==8'h82)begin
                        checksum=16'hffff;for(int j=0;j<30;j++)checksum=crc(checksum,reply_bytes[source][j]);
                        if(source!=0 || nb[source]!=32 || checksum!={reply_bytes[source][31],reply_bytes[source][30]})$fatal(1,"FAIL recorded frame CRC/length");
                        if({reply_bytes[source][13],reply_bytes[source][12],reply_bytes[source][11],reply_bytes[source][10]}!=32'hdbc01234)$fatal(1,"FAIL take ID");
                        case(reply_bytes[source][6])
                          0:perf_starts++;
                          1:begin perf_ons++;if(perf_ons==1)perf_first_on_tick={reply_bytes[source][21],reply_bytes[source][20],reply_bytes[source][19],reply_bytes[source][18]};if(reply_bytes[source][22]!=40 || reply_bytes[source][23]!=64)$fatal(1,"FAIL PAD recorded pitch/velocity %d/%d",reply_bytes[source][22],reply_bytes[source][23]);end
                          2:begin perf_offs++;
                            if(({reply_bytes[source][21],reply_bytes[source][20],reply_bytes[source][19],reply_bytes[source][18]}-perf_first_on_tick)<190)$fatal(1,"FAIL device record timestamp/held duration");
                          end
                          3:begin perf_ends++;if(reply_bytes[source][7]!=0)$fatal(1,"FAIL take incomplete");end
                        endcase
                    end else begin
                    checksum=16'hffff;for(int j=0;j<9;j++)checksum=crc(checksum,reply_bytes[source][j]);
                    if(nb[source]!=11 || reply_bytes[source][0]!=1 || reply_bytes[source][1]!=8'h80 ||
                       reply_bytes[source][4]!=3 || reply_bytes[source][6]!=2 ||
                       checksum!={reply_bytes[source][10],reply_bytes[source][9]})$fatal(1,"FAIL board UART reply/CRC");
                    last_result[source]=reply_bytes[source][8];last_seq[source]={reply_bytes[source][3],reply_bytes[source][2]};
                    replies[source]++;
                    end
                end
                started[source]=1;escaped[source]=0;nb[source]=0;
            end else if(started[source])begin
                if(val==8'hdb)escaped[source]=1;
                else begin
                    if(escaped[source])begin val=val==8'hdc ? 8'hc0 : 8'hdb;escaped[source]=0;end
                    reply_bytes[source][nb[source]]=val;nb[source]++;
                end
            end
        end
    end
    always @(posedge dut.clk_core)if(dut.u_system.core_n)begin
        if(dut.u_system.backend_valid && dut.u_system.backend_ready)cfg_commits++;
        if(dut.u_system.sample_valid)begin
            samples++;if(dut.u_system.sample_value!=0)nonzero++;
            if((dut.u_system.sample_value<0 ? -dut.u_system.sample_value : dut.u_system.sample_value)>sample_peak)
                sample_peak=dut.u_system.sample_value<0 ? -dut.u_system.sample_value : dut.u_system.sample_value;
        end
        if(dut.u_system.audio_diagnostics!=0)$fatal(1,"FAIL board audio diagnostics %b",dut.u_system.audio_diagnostics);
        if(dut.u_system.cfg_done && dut.u_system.cfg_result==0 && dut.u_system.ctx_cmd==2 &&
           (!dut.u_system.audio_valid || dut.u_system.audio_state.reverb!=dut.u_system.ctx_shadow[15:8]))
            $fatal(1,"FAIL serial ACK before actual configuration");
    end
    always @(posedge lclk)if(dut.u_system.pix_n)begin
        if(dut.u_system.frame_pulse)display_frames++;
        if(de && (^({r,g,b})===1'bx))$fatal(1,"FAIL unknown LCD pixels");
    end
    task automatic clocks(input int n);repeat(n)@(negedge dut.clk_core);endtask
    task automatic key(input int event_id);
        if(event_id==1 || event_id==2)key0=0;else key1=0;
        clocks((event_id==2 || event_id==4)?40:12);
        key0=1;key1=1;clocks(16);
    endtask
    task automatic uart_byte(input int source,input logic [7:0] val);
        @(negedge dut.clk_core);rx[source]=0;clocks(32);
        for(int j=0;j<8;j++)begin rx[source]=val[j];clocks(32);end
        rx[source]=1;clocks(32);
    endtask
    task automatic escape_byte(input int source,input logic [7:0] val);
        if(val==8'hc0)begin uart_byte(source,8'hdb);uart_byte(source,8'hdc);end
        else if(val==8'hdb)begin uart_byte(source,8'hdb);uart_byte(source,8'hdd);end
        else uart_byte(source,val);
    endtask
    task automatic frame(input int source,kind,seq,len,input logic [127:0] payload,input bit corrupt=0);
        logic [7:0] bytes[24];logic [15:0] check;
        bytes[0]=1;bytes[1]=8'(kind);bytes[2]=8'(seq);bytes[3]=8'(seq>>8);bytes[4]=8'(len);bytes[5]=0;
        for(int j=0;j<len;j++)bytes[j+6]=payload[j*8 +:8];
        check=16'hffff;for(int j=0;j<len+6;j++)check=crc(check,bytes[j]);
        if(corrupt)check^=1;bytes[len+6]=check[7:0];bytes[len+7]=check[15:8];
        uart_byte(source,8'hc0);for(int j=0;j<len+8;j++)escape_byte(source,bytes[j]);uart_byte(source,8'hc0);
    endtask
    task automatic config_reply(input int source,seq,len,input logic [127:0] payload,input int result);
        int old;old=replies[source];frame(source,2,seq,len,payload);wait(replies[source]>old);
        if(last_seq[source]!=seq || last_result[source]!=result)$fatal(1,"FAIL config response seq=%d result=%d expected=%d",last_seq[source],last_result[source],result);
    endtask
    task automatic source_menu(input int target);
        // At communication category layer1 selection0 after the first call.
        key(2);for(int j=0;j<target;j++)key(1);key(2);
        wait(!dut.u_system.scene.busy);clocks(10);
        if(dut.u_system.scene.result!=CFG_OK)$fatal(1,"FAIL source menu commit");
    endtask
    integer before_cfg;
    initial if(!GUIDE_TEST && !RECORD_TEST)begin
        for(int s=0;s<2;s++)begin replies[s]=0;nb[s]=0;started[s]=0;escaped[s]=0;end
        #100;rst_n=1;
        wait(dut.u_system.audio_valid);wait(nonzero>600);clocks(10);
        $display("BOARD boot/PAD samples=%d t=%t",samples,$time);
        if(!sd || !pa || dut.u_system.pad.fmap.flat_d[0].val!=32 || dut.u_system.force_map.flat_d[0].val!=128 ||
           dut.u_system.u_sound.u_voice.note_on!=16'h0001)$fatal(1,"FAIL raw ADC/force/PAD connection");
        // The renderer now drives a full 8x8 background/ripple image.
        begin:check_pad_leds
            wait(dut.u_system.leds.wr && dut.u_system.u_pad_leds.fill_idx==0);
            wait(!dut.u_system.leds.wr);clocks(80);
            for(int x=0;x<8;x++)for(int y=0;y<8;y++)begin
                int physical_y;logic [23:0] expected,stored;
                physical_y=x%2 ? 7-y : y;
                expected=dut.u_system.u_pad_leds.framebuffer[y*8+x];
                stored=dut.u_system.u_pad.led_inst.gram.pixels[x][physical_y];
                for(int bit_id=0;bit_id<24;bit_id++)
                    if(stored[bit_id]!==expected[23-bit_id])
                        $fatal(1,"FAIL LED image/serpentine/wire mapping x=%d y=%d",x,y);
            end
        end
        key(2);repeat(4)key(1);key(2); // open communication category
        source_menu(1);wait(dut.u_system.values[11]==1);
        $display("BOARD MIDI source committed t=%t",$time);
        if(dut.u_system.values[12]!=2)$fatal(1,"FAIL piano/channel actual UI");
        frame(0,1,10,3,128'h643c91);wait(dut.u_system.u_sound.gate[10]);
        config_reply(0,1,2,128'h0002,0); // NONE: real reverb transaction and final ACK
        config_reply(0,2,10,128'h0100000003e800010001,6); // valid EQ, no DSP endpoint
         $display("BOARD UART config and EQ completed t=%t",$time);
        before_cfg=cfg_commits;config_reply(0,2,10,128'h0100000003e800010001,6);
        if(cfg_commits!=before_cfg)$fatal(1,"FAIL CONFIG retry committed twice");
        // Disable wired remote configuration through the real menu/backend.
        key(1);key(1);key(2);key(3);key(2);wait(dut.u_system.values[13]==2);
        before_cfg=cfg_commits;config_reply(0,3,2,128'h0102,6);
        if(cfg_commits!=before_cfg || dut.u_system.audio_state.reverb!=0)$fatal(1,"FAIL remote permission bypass");
        key(3);key(3);source_menu(2); // draft1 -> two downs clamps2
        wait(dut.u_system.values[11]==2);
        $display("BOARD BT source committed t=%t",$time);
        frame(1,1,11,3,128'h643e91);wait(dut.u_system.u_sound.gate[11]);
        frame(0,1,12,3,128'h644091);clocks(2000);
        if(dut.u_system.u_sound.gate[12])$fatal(1,"FAIL unselected wired MIDI entered synth");
         $display("BOARD source filtering verified t=%t",$time);
        blank=1;config_reply(1,4,2,128'h0102,6);
        if(sd || !dut.u_system.audio_fault || dut.u_system.values[2]!=0)$fatal(1,"FAIL bad load/UI/amplifier mute");
        // Fault holds the MIDI barrier; recover through the local clear action.
        blank=0;key(4);key(1);key(2);repeat(3)key(1);key(2);key(2);
        wait(!dut.u_system.scene.busy);wait(dut.u_system.audio_valid);
        config_reply(1,5,2,128'h0002,0);
        if(!sd || dut.u_system.audio_fault)$fatal(1,"FAIL explicit menu recovery");
        frame(1,1,13,3,128'h643e91);wait(dut.u_system.u_sound.gate[11]);
        frame(1,1,14,3,128'h003e81,1);
        wait(dut.u_system.quarantine[1]);wait(dut.u_system.cleanup_done[1]);
        if(dut.u_system.u_sound.u_notes.slot_owned!=0)$fatal(1,"FAIL communication fault did not retire voices");
         $display("BOARD faults and recovery verified t=%t",$time);
        wait(display_frames>=2);wait(dut.u_system.u_ui.pixel_view.values[11]==2);
         $display("BOARD PCM frames=%d nonzero=%d raw_peak=%d",pcm_frames,pcm_nonzero,sample_peak);
        if(pcm_nonzero<100)$fatal(1,"FAIL no I2S payload frames=%d raw_peak=%d",pcm_frames,sample_peak);
        if(flash.min_read_address!=32'h0080_0000 || flash.qe_writes<1)
            $fatal(1,"FAIL board Flash base/QE propagation");
        $display("BOARD Flash resource reads min=%h max=%h",flash.min_read_address,flash.max_read_address);
        checked_pcm_frames=pcm_frames;checked_pcm_nonzero=pcm_nonzero;
        if(pt_frames<100 || pt_nonzero<20)$fatal(1,"FAIL board PT8211 no nonzero audio");
        $display("BOARD PT8211 frames=%0d nonzero=%0d",pt_frames,pt_nonzero);

        // Loss of the system PLL asynchronously mutes and resets all consumers.
        force dut.u_clocks.core_lock=0;#1;
        if(sd || pa || dut.u_system.core_reset!=0 || dut.u_system.audio_reset!=0 || dut.u_system.pix_reset!=0)
            $fatal(1,"FAIL lock-loss reset assertion");
        clocks(5);release dut.u_clocks.core_lock;
        wait(dut.u_system.audio_valid);clocks(10);
        if(dut.u_system.audio_state.source!=0 || dut.u_system.remote_permission!=3 || dut.u_system.quarantine!=0)
            $fatal(1,"FAIL reset/reload recovery");
        rst_n=0;#1;if(sd || pa)$fatal(1,"FAIL button reset mute");
        $display("PASS tb_instrument_board samples=%d nonzero=%d I2S=%d/%d replies=%d/%d menu_uart_pad_audio_lcd_fault_reset",samples,nonzero,checked_pcm_frames,checked_pcm_nonzero,replies[0],replies[1]);$finish;
    end
    // End-to-end guide variant: real UART framing, menu, ADC, Flash, synth and LCD CDC.
    initial if(GUIDE_TEST)begin
        pad_enabled=0;
        for(int s=0;s<2;s++)begin replies[s]=0;nb[s]=0;started[s]=0;escaped[s]=0;end
        #100;rst_n=1;wait(dut.u_system.audio_valid);
        key(2);repeat(4)key(1);key(2);source_menu(1);
        repeat(3)key(1);key(2);key(1);key(2);wait(!dut.u_system.scene.busy);
        wait(dut.u_system.guide_display.enabled);
        if(dut.u_system.values[20]!=1 || dut.u_system.u_sound.synth_midi)
            $fatal(1,"FAIL board guide menu/synth route");
        frame(0,1,20,3,128'h642891);wait(dut.u_system.guide_display.target[0]);
        repeat(20)begin @(posedge sample_tick);clocks(5);end
        if(nonzero!=0 || dut.u_system.u_sound.u_voice.note_on!=0 || dut.u_system.u_sound.gate!=0)
            $fatal(1,"FAIL UART guide automatically played");
        wait(dut.u_system.u_ui.pixel_guide.target[0]);
        if(!dut.u_system.u_ui.pixel_guide.enabled || dut.u_system.u_ui.pixel_guide.note_map[6:0]!=40)
            $fatal(1,"FAIL board guide snapshot wiring");
        pad_enabled=1;wait(dut.u_system.guide_display.pressed[0]);wait(nonzero>20);
        frame(0,1,21,3,128'h0078b1);clocks(2000);
        if(dut.u_system.guide_display.target!=0 || !dut.u_system.u_sound.u_voice.note_on[0])
            $fatal(1,"FAIL UART CC120 cleared user PAD");
        pad_enabled=0;wait(!dut.u_system.guide_display.pressed[0]);
        repeat(3)key(3);source_menu(2);
        if(dut.u_system.values[20]!=0)$fatal(1,"FAIL board source change retained guide");
        repeat(3)key(1);key(2);key(1);key(2);wait(!dut.u_system.scene.busy);
        wait(dut.u_system.guide_display.enabled);
        frame(0,1,22,3,128'h642a91);clocks(1000);
        if(dut.u_system.guide_display.target!=0)$fatal(1,"FAIL UART lit Bluetooth guide");
        frame(1,1,23,3,128'h642891);wait(dut.u_system.guide_display.target[0]);
        pad_enabled=1;wait(dut.u_system.guide_display.pressed[0]);
        frame(1,1,24,3,128'h002881,1);
        wait(dut.u_system.quarantine[1]);wait(dut.u_system.cleanup_done[1]);
        if(dut.u_system.guide_display.target!=0 || !dut.u_system.u_sound.u_voice.note_on[0] || dut.u_system.audio_fault)
            $fatal(1,"FAIL Bluetooth quarantine interrupted manual guide performance");
        $display("PASS tb_instrument_board GUIDE UART/BT/menu/ADC/LCD/engine samples=%0d nonzero=%0d",samples,nonzero);$finish;
    end
    initial if(RECORD_TEST)begin
        for(int i=0;i<2;i++)begin replies[i]=0;nb[i]=0;started[i]=0;escaped[i]=0;end
        pad_enabled=0;#100;rst_n=1;wait(dut.u_system.audio_valid);clocks(2000);
        // Unsupported source/profile and permission are checked by the real bridge.
        config_reply(0,30,5,128'hdbc0123412,0);
        wait(perf_starts==1);pad_enabled=1;wait(perf_ons==1);clocks(200000);
        pad_enabled=0;wait(perf_offs==1);clocks(100000);
        pad_enabled=1;wait(perf_ons==2);clocks(400000);
        // Stop while still holding a key: take must finish without stopping PAD audio.
        config_reply(0,31,5,128'hdbc0123413,0);
        if(perf_ends!=1 || dut.u_system.u_sound.u_voice.note_on[0]!=1)$fatal(1,"FAIL END-before-ACK or STOP muted PAD");
        if(perf_ons!=2 || perf_offs!=1 || dut.u_system.rec_active)$fatal(1,"FAIL recorded events");
        // Cached START and STOP are not allowed to create another take.
        config_reply(0,31,5,128'hdbc0123413,0);
        if(perf_starts!=1)$fatal(1,"FAIL STOP retry restarted capture");
        $fclose(recording_wire_file);
        $display("PASS tb_instrument_board RECORD real_ADC_router_UART on=%0d off=%0d END_before_ACK",perf_ons,perf_offs);$finish;
    end
    initial begin #400000000;$fatal(1,"FAIL board watchdog menu=%d/%d/%d cfg=%d bridge=%d source=%d replies=%d/%d",dut.u_system.scene.layer,dut.u_system.scene.category,dut.u_system.scene.selection,dut.u_system.u_sound.cfg_state,dut.u_system.bridge_state,dut.u_system.audio_state.source,replies[0],replies[1]);end
    initial begin #40000000;if(!GUIDE_TEST && nonzero==0)$fatal(1,"FAIL ADC/PAD boot watchdog raw=%h normalized=%h",dut.u_system.pad.fmap.raw,dut.u_system.force_map.raw);end
endmodule
