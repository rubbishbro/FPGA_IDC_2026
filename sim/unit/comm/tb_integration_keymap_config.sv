`timescale 1ns/1ps
// Board-level integration TB: keymap (0x20) <-> scalar config (0x02) handoff.
//
// Drives the production board top (real comm_top, bridge, router, UART, flash
// loader) at 115200 wired v1. The host-side CRC/SLIP/UART frame builder and the
// DUT-TX frame receiver are implemented here, not borrowed from RTL. All checks
// use board ports or named internal status; no production RTL is modified.
//
// Sequence:
//   boot -> keymap A 00 -> reverb config 00 (immediately) -> keymap B 00
//   -> config cache conflict 05 -> keymap cache conflict 05
//   -> cached keymap replay 00 with no flash reload -> fresh config 00
//   -> optional held-pad keymap 04 followed by a config 00.
module tb_integration_keymap_config;
    localparam int  SYS_CLK_HZ   = 50_000_000;
    localparam real WIRED_BIT_NS = 1.0e9 / 115200.0;
    localparam int  MAX_FRAMES   = 64;
    localparam int  FRAME_BYTES  = 96;
    localparam logic [7:0] C0=8'hc0, DB=8'hdb, DC=8'hdc, DD=8'hdd;
    localparam logic [7:0] TYPE_CFG=8'h02, TYPE_REPLY=8'h80, TYPE_PERF=8'h82;
    localparam int PIN_BRIDGE_BUSY_NS = 20_000_000;

    logic clk=0,rst_n=0;
    always #10 clk=~clk;                    // 50 MHz board input (PLL model -> 50 MHz core)
    logic [1:0] rx=2'b11;
    wire  [1:0] tx;
    wire  [3:0] pad_row;
    wire  [2:0] pad_ch;
    wire led,cs,sck,bclk,ws,din,sd,lclk,de,db,dw,dd,pa;
    wire [5:0] lr,lg,lb;
    tri   [3:0] dq;
    logic blank=0;
    wire  [3:0] flash_data;
    logic pad_enabled=0;                    // drives the test ADC model only

    instrument_board_top #(.BAUD(115200),.BT_BAUD(9600),.KEY_DEBOUNCE(2),.KEY_LONG(24)) dut(
        .clk(clk),.rst_n(rst_n),.key0(1'b1),.key1(1'b1),.uart_rx(rx),.uart_tx(tx),.bt_state(1'b0),
        .pad_row(pad_row),.pad_ch(pad_ch),.led_dat(led),.flash_cs_n(cs),.flash_sck(sck),.flash_dq(dq),
        .amp_bclk(bclk),.amp_ws(ws),.amp_din(din),.amp_sd(sd),.dac_bck(db),.dac_ws(dw),.dac_din(dd),.dac_pa_en(pa),
        .lcd_clk(lclk),.lcd_en(de),.lcd_r(lr),.lcd_g(lg),.lcd_b(lb));

    w25q64_read_model #(.N_MODES(64),.RESOURCE_BASE(32'h0080_0000),.FLASH_BYTES(16_777_216),
        .FORBID_PROGRAM_READ(1),.WRITE_NS(20_000_000),.MEM_FILE("performance_resources.mem"),
        .MEM_BYTES(1576960)) flash(
        .cs_n(cs),.sck(sck),.dq_o(dq),.dq_oe(dut.u_system.flash_oe),.blank(blank),.dq_i(flash_data));
    assign dq=(!cs && !dut.u_system.flash_oe) ? flash_data : 4'bzzzz;

    // ------------------------------------------------------------------
    // Independent CRC-16/CCITT-FALSE + SLIP frame generator (host -> DUT)
    // ------------------------------------------------------------------
    logic [7:0] out_body [0:95];
    longint last_tx_end;
    int req_frame_base;
    int run_checks=0, run_fails=0;

    task automatic pass_fail(input string name, input bit ok, input string detail);
        run_checks=run_checks+1;
        if(ok) $display("CHECK PASS %s", name);
        else begin
            run_fails=run_fails+1;
            $display("CHECK FAIL %s : %s", name, detail);
        end
    endtask

    function automatic logic [15:0] crc16_body(input int n);
        logic [15:0] c;
        begin
            c=16'hffff;
            for(int i=0;i<n;i++) begin
                c = c ^ {out_body[i],8'h00};
                for(int b=0;b<8;b++) c = c[15] ? (c<<1)^16'h1021 : c<<1;
            end
            return c;
        end
    endfunction

    function automatic logic [15:0] crc16_mem(input int idx);
        logic [15:0] c; int n;
        begin
            c=16'hffff; n=frm_len[idx]-2;
            for(int i=0;i<n;i++) begin
                c = c ^ {frm_mem[idx*FRAME_BYTES+i],8'h00};
                for(int b=0;b<8;b++) c = c[15] ? (c<<1)^16'h1021 : c<<1;
            end
            return c;
        end
    endfunction

    task automatic uart_byte(input logic [7:0] b);
        begin
            @(negedge clk);
            rx[0]=1'b0; #(WIRED_BIT_NS);
            for(int i=0;i<8;i++) begin rx[0]=b[i]; #(WIRED_BIT_NS); end
            rx[0]=1'b1; #(WIRED_BIT_NS);
        end
    endtask

    task automatic slip_byte(input logic [7:0] b);
        if(b==C0) begin uart_byte(DB); uart_byte(DC); end
        else if(b==DB) begin uart_byte(DB); uart_byte(DD); end
        else uart_byte(b);
    endtask

    task automatic send_body(input int n, input bit corrupt);
        logic [15:0] c;
        begin
            req_frame_base=frm_total;
            c=crc16_body(n);
            if(corrupt) c=c^16'h0001;
            uart_byte(C0);
            for(int i=0;i<n;i++) slip_byte(out_body[i]);
            slip_byte(c[7:0]);
            slip_byte(c[15:8]);
            uart_byte(C0);
            last_tx_end=$time;
        end
    endtask

    task automatic send_frame(input logic [7:0] typ, input logic [7:0] seq,
                              input logic [7:0] len, input logic [511:0] payload, input bit corrupt);
        begin
            out_body[0]=typ; out_body[1]=seq; out_body[2]=len;
            for(int i=0;i<len;i++) out_body[3+i]=payload[i*8 +:8];
            send_body(3+len,corrupt);
        end
    endtask

    // ------------------------------------------------------------------
    // Independent DUT-TX UART receiver and SLIP frame history (wired only)
    // ------------------------------------------------------------------
    longint tx_start [0:255];
    int tx_start_total=0;
    logic [7:0] mon_body [0:95];
    int frm_total=0;
    int frm_len [0:MAX_FRAMES-1];
    longint frm_t0 [0:MAX_FRAMES-1];
    longint frm_t1 [0:MAX_FRAMES-1];
    logic [7:0] frm_mem [0:MAX_FRAMES*FRAME_BYTES-1];

    task automatic publish_frame(input int n, input longint t0);
        int idx;
        begin
            idx=frm_total%MAX_FRAMES;
            frm_len[idx]=n;
            for(int i=0;i<n;i++) frm_mem[idx*FRAME_BYTES+i]=mon_body[i];
            frm_t0[idx]=t0;
            frm_t1[idx]=$time;
            frm_total=frm_total+1;
            if(frm_total<=14)
                $display("RXFRAME n=%0d t0=%0t t1=%0t len=%0d type=%02x seq=%02x",
                         frm_total,t0,$time,n,
                         (n>0)?mon_body[0]:8'h00,(n>1)?mon_body[1]:8'h00);
        end
    endtask

    task automatic rx_byte(output logic [7:0] b);
        begin
            @(negedge tx[0]);
            tx_start[tx_start_total%256]=$time;
            tx_start_total=tx_start_total+1;
            #(WIRED_BIT_NS*1.5);
            for(int i=0;i<8;i++) begin b[i]=tx[0]; #(WIRED_BIT_NS); end
            #(WIRED_BIT_NS*0.4);
        end
    endtask

    initial begin : monitor_wired
        logic [7:0] b; int n; logic in_frame,esc; longint t0;
        in_frame=0; n=0; esc=0; t0=0;
        @(posedge rst_n); #(WIRED_BIT_NS*2.0);
        forever begin
            rx_byte(b);
            if(!in_frame) begin
                if(b==C0) begin in_frame=1; n=0; esc=0; t0=$time; end
            end else if(b==C0) begin
                if(n>0) publish_frame(n,t0);
                in_frame=0;
            end else if(esc) begin
                if(n<96) begin mon_body[n]=(b==DC)?C0:(b==DD)?DB:b; n=n+1; end
                esc=0;
            end else if(b==DB) esc=1;
            else if(n<96) begin mon_body[n]=b; n=n+1; end
        end
    end

    function automatic logic [7:0] fbyte(input int idx, input int off);
        return frm_mem[idx*FRAME_BYTES+off];
    endfunction

    // Check a TYPE=80 reply with command echo, SEQ and result. Latency is measured
    // from the last host request stop bit to the first DUT start edge.
    task automatic check_reply(input logic [7:0] exp_cmd, input logic [7:0] exp_res,
                               input logic [7:0] exp_seq, input string name, input int n0,
                               input longint timeout_ns, output int ok);
        int old,idx,found,len; logic good; logic [15:0] c; longint deadline;
        begin
            old=req_frame_base; ok=0; found=-1;
            // Replies can complete before this task is entered. Keep scanning
            // until the matching reply appears (or the timeout expires).
            deadline=$time+((timeout_ns<150_000_000)?150_000_000:timeout_ns);
            while($time<deadline) begin
                for(int f=old;f<frm_total;f++) begin
                    if(frm_len[f%MAX_FRAMES]==7 &&
                       fbyte(f%MAX_FRAMES,0)==TYPE_REPLY &&
                       fbyte(f%MAX_FRAMES,1)==exp_seq) found=f%MAX_FRAMES;
                end
                if(found>=0) break;
                #(5000);
            end
            if(found<0) begin
                pass_fail(name,0,$sformatf(
                    "no matching TYPE=80 SEQ=%02x reply among %0d frame(s) captured since request",
                    exp_seq,frm_total-old));
                return;
            end
            idx=found;
            len=frm_len[idx];
            good=(len==7) && (fbyte(idx,0)==TYPE_REPLY) && (fbyte(idx,1)==exp_seq) &&
                 (fbyte(idx,2)==2) && (fbyte(idx,3)==exp_cmd) && (fbyte(idx,4)==exp_res);
            if(good) begin
                c=crc16_mem(idx);
                good = ({fbyte(idx,6),fbyte(idx,5)}==c);
            end
            if(!good) begin
                pass_fail(name,0,$sformatf(
                    "expected TYPE=80 SEQ=%02x LEN=02 CMD=%02x RES=%02x; actual len=%0d TYPE=%02x SEQ=%02x LEN=%02x CMD=%02x RES=%02x CRCok=%0b",
                    exp_seq,exp_cmd,exp_res,len,fbyte(idx,0),fbyte(idx,1),fbyte(idx,2),
                    fbyte(idx,3),fbyte(idx,4),
                    (len>=7)?({fbyte(idx,6),fbyte(idx,5)}==crc16_mem(idx)):1'b0));
                return;
            end
            ok=1;
            pass_fail(name,1,"");
        end
    endtask

    // Fail if any new TYPE=80 reply appears in the window. Other frame types are
    // reported but not counted as a stale config reply.
    task automatic expect_no_new_reply(input longint duration_ns, input string name);
        int n0,extra,other;
        begin
            n0=frm_total;
            #(duration_ns);
            extra=0; other=0;
            for(int f=n0;f<frm_total;f++) begin
                if(fbyte(f%MAX_FRAMES,0)==TYPE_REPLY) extra=extra+1;
                else other=other+1;
            end
            pass_fail(name,extra==0,
                $sformatf("received %0d extra TYPE=80 reply frame(s) (+%0d other) within %0t; stale replies must not replay",
                          extra,other,duration_ns));
        end
    endtask

    // ------------------------------------------------------------------
    // Test helpers
    // ------------------------------------------------------------------
    task automatic wait_core(input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while(!dut.u_system.core_n && (($time-t0)<timeout_ns)) #(1000);
        end
    endtask

    task automatic wait_audio_valid(input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while(!dut.u_system.audio_valid && (($time-t0)<timeout_ns)) #(1000);
        end
    endtask

    task automatic wait_level(input longint timeout_ns, input int which);
        longint t0; begin
            t0=$time;
            while(($time-t0)<timeout_ns) begin
                if(which==0 && dut.u_system.u_sound.have_commit) return;
                if(which==1 && dut.u_system.bridge_state==0) return;
                #(10_000);
            end
        end
    endtask

    task automatic reboot_and_wait;
        begin
            pad_enabled=1'b0;
            rst_n=1'b0;
            #(2_000_000);
            rst_n=1'b1;
            wait_core(200_000_000);
            if(!dut.u_system.core_n) $fatal(1,"FAIL core reset never released");
            wait_audio_valid(500_000_000);
            if(!dut.u_system.audio_valid) $fatal(1,"FAIL audio_valid never asserted");
            wait_level(500_000_000,0);
            if(!dut.u_system.u_sound.have_commit) $fatal(1,"FAIL backend never committed at boot");
            wait_level(200_000_000,1);
            if(dut.u_system.bridge_state!=0) $fatal(1,"FAIL bridge never idle at boot");
            #(10_000_000);
            if(dut.u_system.u_sound.keymap_inflight) $fatal(1,"FAIL stale keymap at boot");
        end
    endtask

    task automatic wait_keymap_admitted(input string name, input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while(!dut.u_system.u_sound.keymap_inflight && (($time-t0)<timeout_ns)) #(10_000);
            pass_fail(name, dut.u_system.u_sound.keymap_inflight,
                $sformatf("keymap request not admitted within %0t: bridge=%0d cfg_state=%0d frames=%0d",
                          timeout_ns,dut.u_system.bridge_state,dut.u_system.u_sound.cfg_state,frm_total));
        end
    endtask

    task automatic wait_config_admitted(input string name, input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while(!(dut.u_system.bridge_state!=0) && (($time-t0)<timeout_ns)) #(10_000);
            pass_fail(name, dut.u_system.bridge_state!=0,
                $sformatf("config request not admitted within %0t: bridge=%0d keymap_inflight=%0b frames=%0d",
                          timeout_ns,dut.u_system.bridge_state,dut.u_system.u_sound.keymap_inflight,frm_total));
        end
    endtask

    task automatic wait_release_wait(input string name, input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while(!dut.u_system.u_sound.keymap_waiting_release && (($time-t0)<timeout_ns)) #(10_000);
            pass_fail(name, dut.u_system.u_sound.keymap_waiting_release,
                $sformatf("keymap never entered release-wait within %0t: cfg_state=%0d bridge=%0d",
                          timeout_ns,dut.u_system.u_sound.cfg_state,dut.u_system.bridge_state));
        end
    endtask

    task automatic wait_idle(input string name, input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while((dut.u_system.bridge_state!=0 || dut.u_system.u_sound.keymap_inflight) &&
                  (($time-t0)<timeout_ns)) #(10_000);
            pass_fail(name, (dut.u_system.bridge_state==0 && !dut.u_system.u_sound.keymap_inflight),
                $sformatf("bridge/keymap not idle within %0t: bridge=%0d cfg_state=%0d keymap_inflight=%0b",
                          timeout_ns,dut.u_system.bridge_state,dut.u_system.u_sound.cfg_state,
                          dut.u_system.u_sound.keymap_inflight));
        end
    endtask

    task automatic build_keymap(input logic [7:0] inst, input logic [7:0] base_note,
                                output logic [511:0] p);
        begin
            p='0; p[7:0]=8'h20;
            for(int i=0;i<16;i++) begin
                p[(1+2*i)*8 +:8]=inst;
                p[(2+2*i)*8 +:8]=base_note+8'(i);
            end
        end
    endtask

    function automatic logic [111:0] map_expected(input logic [7:0] base_note);
        for(int i=0;i<16;i++) map_expected[i*7 +:7]=7'(base_note+8'(i));
    endfunction

    task automatic check_map(input string name, input logic [7:0] base_note);
        logic [111:0] exp;
        begin
            exp=map_expected(base_note);
            pass_fail(name, dut.u_system.u_sound.committed_map==exp,
                $sformatf("committed_map=%028x expected=%028x (base note %0d)",
                          dut.u_system.u_sound.committed_map,exp,base_note));
        end
    endtask

    task automatic wait_pad_seen;
        longint t0; begin
            t0=$time;
            while((dut.u_system.force_map.raw[7:0]<8'd64) && (($time-t0)<20_000_000)) #(10_000);
            if(dut.u_system.force_map.raw[7:0]<8'd64)
                $fatal(1,"FAIL pad fixture never asserted force_map.raw=%02x",dut.u_system.force_map.raw[7:0]);
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    logic [511:0] p, p2;
    logic [15:0] cself;
    logic [111:0] held_map;
    logic held_custom;
    int ok, b0;
    int replay_flash_before;
    int final_frames;

    initial begin : main
        // CRC-16/CCITT-FALSE self-check from docs §6.
        out_body[0]=8'h31; out_body[1]=8'h32; out_body[2]=8'h33; out_body[3]=8'h34;
        out_body[4]=8'h35; out_body[5]=8'h36; out_body[6]=8'h37; out_body[7]=8'h38; out_body[8]=8'h39;
        cself=crc16_body(9);
        pass_fail("crc16_ccitt_false_check_123456789", cself==16'h29b1,
                  $sformatf("expected 29B1, got %04x (docs §6)",cself));

        reboot_and_wait();
        pass_fail("boot_clean_have_commit_bridge_idle",
                  dut.u_system.audio_valid && !dut.u_system.audio_fault &&
                  dut.u_system.u_sound.have_commit && dut.u_system.bridge_state==0 &&
                  !dut.u_system.u_sound.keymap_inflight,
                  $sformatf("valid=%0b fault=%0b have_commit=%0b bridge=%0d keymap_inflight=%0b",
                            dut.u_system.audio_valid,dut.u_system.audio_fault,
                            dut.u_system.u_sound.have_commit,dut.u_system.bridge_state,
                            dut.u_system.u_sound.keymap_inflight));

        // =============================================================
        // Reject at the final slot too: a staged scan must not publish a
        // partially valid table. Exercise both bounds and the full-byte ID.
        for(int bad=0;bad<4;bad++)begin
            build_keymap(8'd0,8'd21,p);
            case(bad)
                0:p[(2+2*15)*8 +:8]=8'd20; // below piano lower bound
                1:p[(2+2*15)*8 +:8]=8'd53; // exclusive upper bound
                2:p[(1+2*15)*8 +:8]=8'd1;  // mixed instrument
                3:p[(1+2*15)*8 +:8]=8'h10; // same low nibble, invalid full ID
            endcase
            b0=tx_start_total;
            send_frame(TYPE_CFG,8'(8'h60+bad),8'd33,p,1'b0);
            check_reply(8'h20,8'h03,8'(8'h60+bad),$sformatf("invalid_last_slot_%0d_reply_03",bad),b0,500_000_000,ok);
            wait_idle($sformatf("invalid_last_slot_%0d_idle",bad),50_000_000);
            pass_fail($sformatf("invalid_last_slot_%0d_no_publish",bad),
                      !dut.u_system.audio_state.custom_keys && dut.u_system.audio_valid &&
                      !dut.u_system.u_sound.keymap_inflight,
                      "invalid table changed the committed configuration");
        end

        // 1) 0x20 keymap A over wired v1, then immediately a 0x02 config.
        // =============================================================
        build_keymap(8'h00,8'd21,p);
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h10,8'd33,p,1'b0);
        wait_keymap_admitted("keymap_A_request_admitted",100_000_000);
        check_reply(8'h20,8'h00,8'h10,"keymap_A_reply_00",b0,500_000_000,ok);
        if(ok) begin
            check_map("keymap_A_committed_table",8'd21);
            pass_fail("keymap_A_custom_keys",dut.u_system.audio_state.custom_keys==1'b1,
                      $sformatf("audio_state.custom_keys=%0b after 00",dut.u_system.audio_state.custom_keys));
        end
        wait_idle("keymap_A_bridge_returns_idle",50_000_000);

        // No artificial settle: send the scalar config as soon as 00 completes.
        p='0; p[7:0]=8'h02; p[15:8]=8'h01;
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h11,8'd2,p,1'b0);
        wait_config_admitted("config_after_keymap_request_admitted",20_000_000);
        check_reply(8'h02,8'h00,8'h11,"config_after_keymap_reply_00",b0,500_000_000,ok);
        if(ok) begin
            pass_fail("config_after_keymap_reverb_effective",dut.u_system.audio_state.reverb==1,
                      $sformatf("expected reverb=1 (HALL), got %0d",dut.u_system.audio_state.reverb));
            check_map("config_after_keymap_keeps_table",8'd21);
            pass_fail("config_after_keymap_keeps_custom_keys",dut.u_system.audio_state.custom_keys==1'b1,
                      $sformatf("custom_keys=%0b after scalar config",dut.u_system.audio_state.custom_keys));
        end
        wait_idle("config_after_keymap_bridge_returns_idle",50_000_000);

        // Cache integrity: same SEQ, different preset -> 05, reverb unchanged.
        p='0; p[7:0]=8'h02; p[15:8]=8'h03;
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h11,8'd2,p,1'b0);
        check_reply(8'h02,8'h05,8'h11,"config_same_seq_conflict_05",b0,50_000_000,ok);
        pass_fail("config_same_seq_conflict_keeps_reverb",dut.u_system.audio_state.reverb==1,
                  $sformatf("conflicting SEQ changed reverb from 1 to %0d",dut.u_system.audio_state.reverb));
        wait_idle("config_conflict_bridge_returns_idle",50_000_000);

        // 2) Second keymap with different notes, sent immediately after config.
        build_keymap(8'h00,8'd37,p);
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h12,8'd33,p,1'b0);
        wait_keymap_admitted("keymap_B_request_admitted",100_000_000);
        check_reply(8'h20,8'h00,8'h12,"keymap_B_reply_00",b0,500_000_000,ok);
        if(ok) begin
            check_map("keymap_B_committed_table",8'd37);
            pass_fail("keymap_B_custom_keys",dut.u_system.audio_state.custom_keys==1'b1,
                      $sformatf("audio_state.custom_keys=%0b after second 00",dut.u_system.audio_state.custom_keys));
            pass_fail("keymap_B_preserves_reverb",dut.u_system.audio_state.reverb==1,
                      $sformatf("keymap load changed reverb from 1 to %0d",dut.u_system.audio_state.reverb));
        end
        wait_idle("keymap_B_bridge_returns_idle",50_000_000);

        // Same SEQ, different table -> 05; committed table must not move.
        p2=p; p2[(2+2*0)*8 +:8]=8'd38;
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h12,8'd33,p2,1'b0);
        check_reply(8'h20,8'h05,8'h12,"keymap_same_seq_conflict_05",b0,50_000_000,ok);
        pass_fail("keymap_same_seq_conflict_keeps_table",
                  dut.u_system.u_sound.committed_map==map_expected(8'd37),
                  $sformatf("committed_map=%028x changed after SEQ conflict",
                            dut.u_system.u_sound.committed_map));
        wait_idle("keymap_conflict_bridge_returns_idle",50_000_000);

        // Exact replay of the cached request -> 00 with no flash reload.
        replay_flash_before=flash.transactions;
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h12,8'd33,p,1'b0);
        check_reply(8'h20,8'h00,8'h12,"keymap_cached_replay_00",b0,50_000_000,ok);
        pass_fail("keymap_cached_replay_no_flash_reload",
                  flash.transactions==replay_flash_before,
                  $sformatf("flash.transactions changed %0d -> %0d; cached replay must not re-execute",
                            replay_flash_before,flash.transactions));
        check_map("keymap_cached_replay_keeps_table",8'd37);
        wait_idle("keymap_replay_bridge_returns_idle",50_000_000);

        // A fresh scalar config after all keymap traffic must still commit.
        p='0; p[7:0]=8'h02; p[15:8]=8'h02;
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h13,8'd2,p,1'b0);
        wait_config_admitted("final_config_request_admitted",20_000_000);
        check_reply(8'h02,8'h00,8'h13,"final_config_reply_00",b0,500_000_000,ok);
        if(ok) begin
            pass_fail("final_config_reverb_effective",dut.u_system.audio_state.reverb==2,
                      $sformatf("expected reverb=2 (BATHROOM), got %0d",dut.u_system.audio_state.reverb));
            check_map("final_config_keeps_table",8'd37);
            pass_fail("final_config_keeps_custom_keys",dut.u_system.audio_state.custom_keys==1'b1,
                      $sformatf("custom_keys=%0b after final config",dut.u_system.audio_state.custom_keys));
        end
        // No late/stale reply after the last transaction.
        final_frames=frm_total;
        #(20_000_000);
        pass_fail("no_late_frame_after_final_reply",frm_total==final_frames,
                  $sformatf("received %0d frame(s) after the final reply; stale cache replay or duplicate reply",
                            frm_total-final_frames));

        // =================================================================
        // 3) Optional: held-pad keymap -> 04, then a config still succeeds.
        // =================================================================
        reboot_and_wait();
        held_map=dut.u_system.u_sound.committed_map;
        held_custom=dut.u_system.audio_state.custom_keys;
        pad_enabled=1'b1;
        wait_pad_seen();
        build_keymap(8'h00,8'd25,p);
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h20,8'd33,p,1'b0);
        wait_keymap_admitted("held_pad_keymap_request_admitted",100_000_000);
        wait_release_wait("held_pad_keymap_waits_for_release",50_000_000);
        check_reply(8'h20,8'h04,8'h20,"held_pad_keymap_timeout_04",b0,500_000_000,ok);
        if(ok) begin
            pass_fail("held_pad_keymap_table_unchanged",
                      dut.u_system.u_sound.committed_map==held_map &&
                      dut.u_system.audio_state.custom_keys==held_custom,
                      "04 timeout changed the committed table");
        end
        wait_idle("held_pad_04_bridge_returns_idle",50_000_000);
        // Keep the pad held: a scalar config must not be blocked by it.
        p='0; p[7:0]=8'h02; p[15:8]=8'h02;
        b0=tx_start_total;
        send_frame(TYPE_CFG,8'h21,8'd2,p,1'b0);
        wait_config_admitted("config_after_held_pad_04_request_admitted",20_000_000);
        check_reply(8'h02,8'h00,8'h21,"config_after_held_pad_04_reply_00",b0,500_000_000,ok);
        if(ok) begin
            pass_fail("config_after_held_pad_04_reverb_effective",dut.u_system.audio_state.reverb==2,
                      $sformatf("expected reverb=2, got %0d after keymap 04",dut.u_system.audio_state.reverb));
            pass_fail("config_after_held_pad_04_table_unchanged",
                      dut.u_system.u_sound.committed_map==held_map &&
                      dut.u_system.audio_state.custom_keys==held_custom,
                      "config after 04 changed the timed-out keymap table");
        end
        // Releasing the pad after the timeout must not resurrect the old table.
        pad_enabled=1'b0;
        #(200_000_000);
        pass_fail("held_pad_release_after_04_no_late_commit",
                  dut.u_system.u_sound.committed_map==held_map &&
                  dut.u_system.audio_state.custom_keys==held_custom &&
                  !dut.u_system.u_sound.keymap_inflight,
                  $sformatf("late release changed table or left keymap_inflight=%0b",
                            dut.u_system.u_sound.keymap_inflight));

        if(run_fails==0) $display("PASS tb_integration_keymap_config checks=%0d",run_checks);
        else $fatal(1,"FAIL tb_integration_keymap_config checks=%0d fails=%0d",run_checks,run_fails);
        $finish;
    end

    initial begin #(3_000_000_000); $fatal(1,"FAIL integration keymap/config watchdog"); end
endmodule
