`timescale 1ns/1ps
// Board-level integration TB: Bluetooth framing fault -> idle recovery ->
// business continuity, plus BT/wired isolation.
//
// Drives the production board top (real comm_top, bridge, router, UARTs) at
// 9600 BT and 115200 wired v1. Host CRC/SLIP/UART framing and the DUT-TX frame
// receiver are independent. No production RTL is modified.
//
// Sequence:
//   boot -> BT reverb config 00
//   -> real BT framing fault on an idle line; assert quarantine, >=32 BT bit
//      times of idle before reopen, no stale reply
//   -> real BT framing fault while a BT config is in flight; assert no stale
//      reply, recovery, table/config state intact
//   -> BT config 00 + BT keymap 00 after recovery
//   -> wired config 00 with no BT reply; BT config 00 with no wired reply.
module tb_integration_bt_recovery_business;
    localparam int  SYS_CLK_HZ   = 50_000_000;
    localparam real WIRED_BIT_NS = 1.0e9 / 115200.0;
    localparam real BT_BIT_NS    = 1.0e9 / 9600.0;
    // comm_top BT_IDLE_CYCLES = ceil(CLK_HZ/BT_BAUD)*32 = 166688 cycles.
    localparam real BT_IDLE_NS   = 32.0 * BT_BIT_NS;
    localparam int  MAX_FRAMES   = 64;
    localparam int  FRAME_BYTES  = 96;
    localparam logic [7:0] C0=8'hc0, DB=8'hdb, DC=8'hdc, DD=8'hdd;
    localparam logic [7:0] TYPE_CFG=8'h02, TYPE_REPLY=8'h80, TYPE_PERF=8'h82;

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
    longint last_tx_end [0:1];
    int req_frame_base [0:1];
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

    function automatic logic [15:0] crc16_mem(input int src, input int idx);
        logic [15:0] c; int n;
        begin
            c=16'hffff; n=frm_len[src][idx]-2;
            for(int i=0;i<n;i++) begin
                c = c ^ {frm_mem[src][idx*FRAME_BYTES+i],8'h00};
                for(int b=0;b<8;b++) c = c[15] ? (c<<1)^16'h1021 : c<<1;
            end
            return c;
        end
    endfunction

    task automatic uart_byte(input int src, input logic [7:0] b, input real bit_ns);
        begin
            @(negedge clk);
            rx[src]=1'b0; #(bit_ns);
            for(int i=0;i<8;i++) begin rx[src]=b[i]; #(bit_ns); end
            rx[src]=1'b1; #(bit_ns);
        end
    endtask

    task automatic slip_byte(input int src, input logic [7:0] b, input real bit_ns);
        if(b==C0) begin uart_byte(src,DB,bit_ns); uart_byte(src,DC,bit_ns); end
        else if(b==DB) begin uart_byte(src,DB,bit_ns); uart_byte(src,DD,bit_ns); end
        else uart_byte(src,b,bit_ns);
    endtask

    task automatic send_body(input int src, input int n, input real bit_ns, input bit corrupt);
        logic [15:0] c;
        begin
            req_frame_base[src]=frm_total[src];
            c=crc16_body(n);
            if(corrupt) c=c^16'h0001;
            uart_byte(src,C0,bit_ns);
            for(int i=0;i<n;i++) slip_byte(src,out_body[i],bit_ns);
            slip_byte(src,c[7:0],bit_ns);
            slip_byte(src,c[15:8],bit_ns);
            uart_byte(src,C0,bit_ns);
            last_tx_end[src]=$time;
        end
    endtask

    task automatic send_frame(input int src, input logic [7:0] typ, input logic [7:0] seq,
                              input logic [7:0] len, input logic [511:0] payload, input bit corrupt);
        real bit_ns;
        begin
            bit_ns=(src==0)?WIRED_BIT_NS:BT_BIT_NS;
            out_body[0]=typ; out_body[1]=seq; out_body[2]=len;
            for(int i=0;i<len;i++) out_body[3+i]=payload[i*8 +:8];
            send_body(src,3+len,bit_ns,corrupt);
        end
    endtask

    // ------------------------------------------------------------------
    // Independent DUT-TX UART receiver and SLIP frame history per source
    // ------------------------------------------------------------------
    longint tx_start [0:1][0:255];
    int tx_start_total [0:1];
    longint fault_high_time;                // set by bt_bad_stop_fault()

    logic [7:0] mon_body [0:1][0:95];
    int frm_total [0:1];
    int frm_len [0:1][0:MAX_FRAMES-1];
    longint frm_t0 [0:1][0:MAX_FRAMES-1];
    longint frm_t1 [0:1][0:MAX_FRAMES-1];
    logic [7:0] frm_mem [0:1][0:MAX_FRAMES*FRAME_BYTES-1];

    task automatic publish_frame(input int src, input int n, input longint t0);
        int idx;
        begin
            idx=frm_total[src]%MAX_FRAMES;
            frm_len[src][idx]=n;
            for(int i=0;i<n;i++) frm_mem[src][idx*FRAME_BYTES+i]=mon_body[src][i];
            frm_t0[src][idx]=t0;
            frm_t1[src][idx]=$time;
            frm_total[src]=frm_total[src]+1;
            if(frm_total[src]<=14)
                $display("RXFRAME src=%0d n=%0d t0=%0t t1=%0t len=%0d type=%02x seq=%02x",
                         src,frm_total[src],t0,$time,n,
                         (n>0)?mon_body[src][0]:8'h00,(n>1)?mon_body[src][1]:8'h00);
        end
    endtask

    task automatic rx_byte(input int src, output logic [7:0] b, input real bit_ns);
        begin
            @(negedge tx[src]);
            tx_start[src][tx_start_total[src]%256]=$time;
            tx_start_total[src]=tx_start_total[src]+1;
            #(bit_ns*1.5);
            for(int i=0;i<8;i++) begin b[i]=tx[src]; #(bit_ns); end
            #(bit_ns*0.4);
        end
    endtask

    initial begin : monitor_wired
        logic [7:0] b; int n; logic in_frame,esc; longint t0;
        in_frame=0; n=0; esc=0; t0=0;
        @(posedge rst_n); #(WIRED_BIT_NS*2.0);
        forever begin
            rx_byte(0,b,WIRED_BIT_NS);
            if(!in_frame) begin
                if(b==C0) begin in_frame=1; n=0; esc=0; t0=$time; end
            end else if(b==C0) begin
                if(n>0) publish_frame(0,n,t0);
                in_frame=0;
            end else if(esc) begin
                if(n<96) begin mon_body[0][n]=(b==DC)?C0:(b==DD)?DB:b; n=n+1; end
                esc=0;
            end else if(b==DB) esc=1;
            else if(n<96) begin mon_body[0][n]=b; n=n+1; end
        end
    end

    initial begin : monitor_bt
        logic [7:0] b; int n; logic in_frame,esc; longint t0;
        in_frame=0; n=0; esc=0; t0=0;
        @(posedge rst_n); #(BT_BIT_NS*2.0);
        forever begin
            rx_byte(1,b,BT_BIT_NS);
            if(!in_frame) begin
                if(b==C0) begin in_frame=1; n=0; esc=0; t0=$time; end
            end else if(b==C0) begin
                if(n>0) publish_frame(1,n,t0);
                in_frame=0;
            end else if(esc) begin
                if(n<96) begin mon_body[1][n]=(b==DC)?C0:(b==DD)?DB:b; n=n+1; end
                esc=0;
            end else if(b==DB) esc=1;
            else if(n<96) begin mon_body[1][n]=b; n=n+1; end
        end
    end

    function automatic logic [7:0] fbyte(input int src, input int idx, input int off);
        return frm_mem[src][idx*FRAME_BYTES+off];
    endfunction

    // Check a TYPE=80 reply with command echo, SEQ and result. Latency is measured
    // from the last host request stop bit to the first DUT start edge.
    task automatic check_reply(input int src, input logic [7:0] exp_cmd, input logic [7:0] exp_res,
                               input logic [7:0] exp_seq, input string name, input int n0,
                               input longint timeout_ns, output int ok);
        int old,idx,found,len; logic good; logic [15:0] c; longint deadline;
        begin
            old=req_frame_base[src]; ok=0; found=-1;
            deadline=$time+((timeout_ns<150_000_000)?150_000_000:timeout_ns);
            while($time<deadline) begin
                for(int f=old;f<frm_total[src];f++) begin
                    if(frm_len[src][f%MAX_FRAMES]==7 &&
                       fbyte(src,f%MAX_FRAMES,0)==TYPE_REPLY &&
                       fbyte(src,f%MAX_FRAMES,1)==exp_seq) found=f%MAX_FRAMES;
                end
                if(found>=0) break;
                #(5000);
            end
            if(found<0) begin
                pass_fail(name,0,$sformatf(
                    "no matching TYPE=80 SEQ=%02x reply among %0d frame(s) captured since request",
                    exp_seq,frm_total[src]-old));
                return;
            end
            idx=found;
            len=frm_len[src][idx];
            good=(len==7) && (fbyte(src,idx,0)==TYPE_REPLY) && (fbyte(src,idx,1)==exp_seq) &&
                 (fbyte(src,idx,2)==2) && (fbyte(src,idx,3)==exp_cmd) && (fbyte(src,idx,4)==exp_res);
            if(good) begin
                c=crc16_mem(src,idx);
                good = ({fbyte(src,idx,6),fbyte(src,idx,5)}==c);
            end
            if(!good) begin
                pass_fail(name,0,$sformatf(
                    "expected TYPE=80 SEQ=%02x LEN=02 CMD=%02x RES=%02x; actual len=%0d TYPE=%02x SEQ=%02x LEN=%02x CMD=%02x RES=%02x CRCok=%0b",
                    exp_seq,exp_cmd,exp_res,len,fbyte(src,idx,0),fbyte(src,idx,1),fbyte(src,idx,2),
                    fbyte(src,idx,3),fbyte(src,idx,4),
                    (len>=7)?({fbyte(src,idx,6),fbyte(src,idx,5)}==crc16_mem(src,idx)):1'b0));
                return;
            end
            ok=1;
            pass_fail(name,1,"");
        end
    endtask

    // Count TYPE=80 replies captured since a marker (no wait).
    function automatic int reply_count_since(input int src, input int marker);
        int n;
        begin
            n=0;
            for(int f=marker;f<frm_total[src];f++)
                if(frm_len[src][f%MAX_FRAMES]>=1 && fbyte(src,f%MAX_FRAMES,0)==TYPE_REPLY) n=n+1;
            return n;
        end
    endfunction

    // True if this source ever received a TYPE=80 reply carrying SEQ.
    function automatic bit seq_replied(input int src, input int seq);
        begin
            seq_replied=0;
            for(int f=0;f<frm_total[src];f++)
                if(frm_len[src][f%MAX_FRAMES]>=2 &&
                   fbyte(src,f%MAX_FRAMES,0)==TYPE_REPLY &&
                   fbyte(src,f%MAX_FRAMES,1)==8'(seq)) seq_replied=1;
        end
    endfunction

    task automatic expect_no_new_reply(input int src, input int marker, input longint wait_ns,
                                       input string name);
        int extra;
        begin
            #(wait_ns);
            extra=reply_count_since(src,marker);
            pass_fail(name,extra==0,
                $sformatf("received %0d TYPE=80 reply frame(s) after the fault without a new request; stale reply not flushed",
                          extra));
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
            begin : wait_commit
                longint t0; t0=$time;
                while(!dut.u_system.u_sound.have_commit && (($time-t0)<500_000_000)) #(10_000);
            end
            if(!dut.u_system.u_sound.have_commit) $fatal(1,"FAIL backend never committed at boot");
            begin : wait_idle0
                longint t0; t0=$time;
                while(dut.u_system.bridge_state!=0 && (($time-t0)<200_000_000)) #(10_000);
            end
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
                          timeout_ns,dut.u_system.bridge_state,dut.u_system.u_sound.cfg_state,frm_total[1]));
        end
    endtask

    task automatic wait_config_admitted(input string name, input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while(!(dut.u_system.bridge_state!=0) && (($time-t0)<timeout_ns)) #(10_000);
            pass_fail(name, dut.u_system.bridge_state!=0,
                $sformatf("config request not admitted within %0t: bridge=%0d keymap_inflight=%0b",
                          timeout_ns,dut.u_system.bridge_state,dut.u_system.u_sound.keymap_inflight));
        end
    endtask

    task automatic wait_idle(input string name, input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while((dut.u_system.bridge_state!=0 || dut.u_system.u_sound.keymap_inflight) &&
                  (($time-t0)<timeout_ns)) #(10_000);
            pass_fail(name, (dut.u_system.bridge_state==0 && !dut.u_system.u_sound.keymap_inflight),
                $sformatf("bridge/keymap not idle within %0t: bridge=%0d keymap_inflight=%0b",
                          timeout_ns,dut.u_system.bridge_state,dut.u_system.u_sound.keymap_inflight));
        end
    endtask

    task automatic wait_source_clean(input string name, input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while((dut.u_system.bridge_state!=0 || dut.u_system.u_sound.keymap_inflight ||
                   !dut.u_system.u_sound.ready) && (($time-t0)<timeout_ns)) #(10_000);
            pass_fail(name, (dut.u_system.bridge_state==0 && !dut.u_system.u_sound.keymap_inflight &&
                             dut.u_system.u_sound.ready),
                $sformatf("source cleanup not complete within %0t: bridge=%0d cfg_state=%0d keymap_inflight=%0b ready=%0b",
                          timeout_ns,dut.u_system.bridge_state,dut.u_system.u_sound.cfg_state,
                          dut.u_system.u_sound.keymap_inflight,dut.u_system.u_sound.ready));
        end
    endtask

    task automatic wait_quarantine_assert(input int src, input string name, input longint timeout_ns);
        longint t0; begin
            t0=$time;
            while(!dut.u_system.quarantine[src] && (($time-t0)<timeout_ns)) #(1000);
            pass_fail(name, dut.u_system.quarantine[src],
                $sformatf("quarantine[%0d]=%0b after real BT framing fault",src,dut.u_system.quarantine[src]));
        end
    endtask

    task automatic wait_quarantine_release(input int src, input string name, input longint timeout_ns,
                                           output longint t_release);
        longint t0; logic saw;
        begin
            saw=dut.u_system.quarantine[src];
            t0=$time;
            while(dut.u_system.quarantine[src] && (($time-t0)<timeout_ns)) begin
                saw=1;
                #(10_000);
            end
            t_release=$time;
            pass_fail(name, saw && !dut.u_system.quarantine[src],
                $sformatf("quarantine[%0d] did not assert-and-release within %0t (saw=%0b now=%0b)",
                          src,timeout_ns,saw,dut.u_system.quarantine[src]));
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

    // Real 8N1 framing fault: 0xFF with the stop bit driven low. The receiver
    // samples the invalid stop bit and pulses framing_err; the following idle
    // high releases S_HOLD so no break is reported. No valid byte is produced.
    task automatic bt_bad_stop_fault;
        begin
            @(negedge clk);
            rx[1]=1'b0; #(BT_BIT_NS);
            for(int i=0;i<8;i++) begin rx[1]=1'b1; #(BT_BIT_NS); end
            rx[1]=1'b0; #(BT_BIT_NS);       // stop bit low -> framing error
            rx[1]=1'b1;
            fault_high_time=$time;          // idle interval starts here
            #(BT_BIT_NS*2.0);
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    logic [511:0] p;
    logic [15:0] cself;
    logic [111:0] saved_map;
    logic saved_custom;
    int ok, b0, marker, bt_frames, wired_frames, reverb_after_fault, reverb_before_fault;
    longint t_release, recovery_ns;

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
                  !dut.u_system.u_sound.keymap_inflight && dut.u_system.quarantine==2'b00,
                  $sformatf("valid=%0b fault=%0b have_commit=%0b bridge=%0d keymap_inflight=%0b q=%b",
                            dut.u_system.audio_valid,dut.u_system.audio_fault,
                            dut.u_system.u_sound.have_commit,dut.u_system.bridge_state,
                            dut.u_system.u_sound.keymap_inflight,dut.u_system.quarantine));
        saved_map=dut.u_system.u_sound.committed_map;
        saved_custom=dut.u_system.audio_state.custom_keys;

        // =============================================================
        // 1) BT reverb config succeeds before any fault.
        // =============================================================
        p='0; p[7:0]=8'h02; p[15:8]=8'h01;
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h30,8'd2,p,1'b0);
        wait_config_admitted("bt_cfg_before_fault_request_admitted",50_000_000);
        check_reply(1,8'h02,8'h00,8'h30,"bt_cfg_before_fault_reply_00",b0,500_000_000,ok);
        if(ok) pass_fail("bt_cfg_before_fault_reverb_effective",dut.u_system.audio_state.reverb==1,
                         $sformatf("expected reverb=1, got %0d",dut.u_system.audio_state.reverb));
        wait_idle("bt_cfg_before_fault_bridge_idle",50_000_000);

        // =============================================================
        // 2) Real framing fault on an idle BT line: must quarantine, wait
        //    >=32 BT bit times of idle, then reopen with no stale reply.
        // =============================================================
        marker=frm_total[1];
        bt_bad_stop_fault();
        wait_quarantine_assert(1,"bt_idle_framing_fault_quarantines",2_000_000);
        pass_fail("bt_idle_framing_fault_counted",
                  dut.u_system.u_comm.error_sticky[13]==1'b1,
                  $sformatf("BT framing sticky (error_sticky[13]) not set: %04x",
                            dut.u_system.u_comm.error_sticky));
        pass_fail("wired_not_quarantined_by_bt_framing_fault",
                  dut.u_system.quarantine[0]==1'b0,
                  $sformatf("wired quarantine[0]=%0b during a BT-only fault",dut.u_system.quarantine[0]));
        wait_quarantine_release(1,"bt_idle_framing_fault_reopens_link",100_000_000,t_release);
        recovery_ns=t_release-fault_high_time;
        pass_fail("bt_idle_recovery_waits_32_bit_times",
                  real'(recovery_ns) >= BT_IDLE_NS*0.95,
                  $sformatf("reopened after %0t, expected >= 32 BT bit times = %0.0f ns at 9600 (recovered early)",
                            recovery_ns,BT_IDLE_NS));
        $display("INFO bt_idle_framing_recovery=%0t ns (32 bit times=%0.0f ns)",recovery_ns,BT_IDLE_NS);
        wait_source_clean("bt_idle_fault_source_clean",100_000_000);
        expect_no_new_reply(1,marker,20_000_000,"bt_idle_fault_no_stale_reply");

        // =============================================================
        // 3) Real framing fault while a BT config request is in flight.
        //    The queued/canceled reply must be flushed, never replayed.
        //    A different preset from the pre-fault config makes any residual
        //    side effect of the canceled request visible in the INFO line.
        // =============================================================
        reverb_before_fault=dut.u_system.audio_state.reverb;
        p='0; p[7:0]=8'h02; p[15:8]=8'h03;
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h32,8'd2,p,1'b0);
        wait_config_admitted("bt_inflight_fault_request_admitted",50_000_000);
        // Wait until the backend has accepted the request (B_WAIT = 3). This is
        // the narrow window where B_SEND's quarantine check has already passed.
        begin : wait_b_wait
            longint t0; t0=$time;
            while(dut.u_system.bridge_state!=3 && (($time-t0)<20_000_000)) #(10_000);
        end
        pass_fail("bt_inflight_fault_request_hits_b_wait",
                  dut.u_system.bridge_state==3,
                  $sformatf("bridge=%0d at fault; expected B_WAIT (3) so the fault hits an accepted in-flight request",
                            dut.u_system.bridge_state));
        pass_fail("bt_inflight_fault_no_reply_yet", !seq_replied(1,8'h32),
                  "SEQ=32 reply already captured before the fault; cannot judge stale-reply suppression");
        marker=frm_total[1];
        bt_bad_stop_fault();
        wait_quarantine_assert(1,"bt_inflight_framing_fault_quarantines",2_000_000);
        reverb_after_fault=dut.u_system.audio_state.reverb;
        $display("INFO bt_inflight_fault reverb_after_fault=%0d bridge=%0d cfg_state=%0d",
                 reverb_after_fault,dut.u_system.bridge_state,dut.u_system.u_sound.cfg_state);
        wait_quarantine_release(1,"bt_inflight_framing_fault_reopens_link",800_000_000,t_release);
        recovery_ns=t_release-fault_high_time;
        pass_fail("bt_inflight_recovery_waits_32_bit_times",
                  real'(recovery_ns) >= BT_IDLE_NS*0.95,
                  $sformatf("reopened after %0t, expected >= 32 BT bit times = %0.0f ns at 9600",
                            recovery_ns,BT_IDLE_NS));
        $display("INFO bt_inflight_framing_recovery=%0t ns",recovery_ns);
        wait_source_clean("bt_inflight_fault_source_clean",800_000_000);
        // docs §5.1: a lost/timeout reply does not prove the board did not
        // execute. A scalar config is atomic and idempotent, and only the
        // keymap path needs rollback, so a post-quarantine side effect is
        // reported as an observation, not a hard failure. The important
        // contract (no stale reply / no replayed SEQ) is asserted below.
        pass_fail("bt_inflight_fault_no_config_side_effect",
                  dut.u_system.audio_state.reverb==reverb_before_fault,
                  $sformatf("reverb changed %0d -> %0d after canceled BT config; source isolation must not commit the request",
                            reverb_before_fault,dut.u_system.audio_state.reverb));
        $display("INFO bt_inflight_fault reverb before=%0d at_quarantine=%0d after_cleanup=%0d",
                 reverb_before_fault,reverb_after_fault,dut.u_system.audio_state.reverb);
        expect_no_new_reply(1,marker,50_000_000,"bt_inflight_fault_no_stale_reply");
        pass_fail("bt_inflight_fault_seq_never_replied", !seq_replied(1,8'h32),
                  "canceled BT request SEQ=32 produced a reply after recovery");
        pass_fail("bt_inflight_fault_table_untouched",
                  dut.u_system.u_sound.committed_map==saved_map &&
                  dut.u_system.audio_state.custom_keys==saved_custom,
                  $sformatf("committed_map=%028x (was %028x) custom_keys=%0b (was %0b) after canceled BT config",
                            dut.u_system.u_sound.committed_map,saved_map,
                            dut.u_system.audio_state.custom_keys,saved_custom));

        // =============================================================
        // 4) Business continuity after recovery: BT config then BT keymap.
        // The canceled scalar request now rolls back/reloads; wait for the
        // backend to return to C_RUN before issuing a new config.
        // =============================================================
        begin : wait_post_cancel_backend
            longint t0; t0=$time;
            while(((dut.u_system.u_sound.cfg_state!=5) ||
                   dut.u_system.bridge_state!=0 ||
                   !dut.u_system.u_sound.midi_ops_idle ||
                   dut.u_system.u_comm.ev_level!=0) &&
                  (($time-t0)<800_000_000)) #(10_000);
            pass_fail("post_cancel_backend_ready",
                      dut.u_system.u_sound.cfg_state==5 && dut.u_system.bridge_state==0 &&
                      dut.u_system.u_sound.midi_ops_idle && dut.u_system.u_comm.ev_level==0,
                      $sformatf("backend cfg_state=%0d bridge=%0d midi_idle=%0b after cancel rollback",
                                dut.u_system.u_sound.cfg_state,dut.u_system.bridge_state,
                                dut.u_system.u_sound.midi_ops_idle));
            $display("DBG backend_ready=%b inflight=%b stage=%0d rsp=%b keymap=%b/%b cfg=%0d bridge=%0d",
                     dut.u_system.u_sound.backend_ready,dut.u_system.u_sound.backend_inflight,
                     dut.u_system.u_sound.backend_stage,dut.u_system.u_sound.backend_rsp_valid,
                     dut.u_system.u_sound.keymap_inflight,dut.u_system.u_sound.keymap_rsp_valid,
                     dut.u_system.u_sound.cfg_state,dut.u_system.bridge_state);
        end
        $display("DBG2 analyzer_state=%0d barrier=%b cfg_ready=%b cfg_valid=%b midi_idle=%b ev=%0d bridge=%0d",
                 dut.u_system.u_comm.u_dispatch.u_config.state,
                 dut.u_system.u_comm.u_dispatch.u_config.barrier_ready,
                 dut.u_system.u_comm.u_dispatch.u_config.cfg_ready,
                 dut.u_system.u_comm.u_dispatch.u_config.cfg_valid,
                 dut.u_system.u_sound.midi_ops_idle,dut.u_system.u_comm.ev_level,
                 dut.u_system.bridge_state);
        p='0; p[7:0]=8'h02; p[15:8]=8'h02;
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h33,8'd2,p,1'b0);
        wait_config_admitted("bt_cfg_after_recovery_request_admitted",50_000_000);
        check_reply(1,8'h02,8'h00,8'h33,"bt_cfg_after_recovery_reply_00",b0,500_000_000,ok);
        if(ok) pass_fail("bt_cfg_after_recovery_reverb_effective",dut.u_system.audio_state.reverb==2,
                         $sformatf("expected reverb=2, got %0d after recovery",dut.u_system.audio_state.reverb));
        wait_idle("bt_cfg_after_recovery_bridge_idle",50_000_000);

        build_keymap(8'h00,8'd37,p);
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h34,8'd33,p,1'b0);
        wait_keymap_admitted("bt_keymap_after_recovery_request_admitted",200_000_000);
        check_reply(1,8'h20,8'h00,8'h34,"bt_keymap_after_recovery_reply_00",b0,500_000_000,ok);
        if(ok) begin
            check_map("bt_keymap_after_recovery_committed_table",8'd37);
            pass_fail("bt_keymap_after_recovery_custom_keys",dut.u_system.audio_state.custom_keys==1'b1,
                      $sformatf("custom_keys=%0b after BT keymap success",dut.u_system.audio_state.custom_keys));
            pass_fail("bt_keymap_after_recovery_preserves_reverb",dut.u_system.audio_state.reverb==2,
                      $sformatf("BT keymap changed reverb from 2 to %0d",dut.u_system.audio_state.reverb));
        end
        wait_idle("bt_keymap_after_recovery_bridge_idle",50_000_000);

        // =============================================================
        // 5) BT/wired isolation: each request only replies on its own link.
        // =============================================================
        bt_frames=frm_total[1];
        p='0; p[7:0]=8'h02; p[15:8]=8'h03;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h35,8'd2,p,1'b0);
        wait_config_admitted("wired_cfg_after_bt_recovery_request_admitted",20_000_000);
        check_reply(0,8'h02,8'h00,8'h35,"wired_cfg_after_bt_recovery_reply_00",b0,500_000_000,ok);
        if(ok) pass_fail("wired_cfg_after_bt_recovery_reverb_effective",dut.u_system.audio_state.reverb==3,
                         $sformatf("expected reverb=3, got %0d",dut.u_system.audio_state.reverb));
        pass_fail("wired_request_no_bt_reply",frm_total[1]==bt_frames,
                  $sformatf("BT emitted %0d reply frame(s) for a wired request; links must be isolated",
                            frm_total[1]-bt_frames));
        wait_idle("wired_cfg_after_bt_recovery_bridge_idle",50_000_000);

        wired_frames=frm_total[0];
        p='0; p[7:0]=8'h02; p[15:8]=8'h00;
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h36,8'd2,p,1'b0);
        wait_config_admitted("bt_cfg_isolation_request_admitted",50_000_000);
        check_reply(1,8'h02,8'h00,8'h36,"bt_cfg_isolation_reply_00",b0,500_000_000,ok);
        if(ok) pass_fail("bt_cfg_isolation_reverb_effective",dut.u_system.audio_state.reverb==0,
                         $sformatf("expected reverb=0, got %0d",dut.u_system.audio_state.reverb));
        pass_fail("bt_request_no_wired_reply",frm_total[0]==wired_frames,
                  $sformatf("wired emitted %0d reply frame(s) for a BT request; links must be isolated",
                            frm_total[0]-wired_frames));
        wait_idle("bt_cfg_isolation_bridge_idle",50_000_000);

        // No late/stale frame on either link after the final transaction.
        bt_frames=frm_total[1]; wired_frames=frm_total[0];
        #(20_000_000);
        pass_fail("no_late_frame_after_final_reply",
                  frm_total[0]==wired_frames && frm_total[1]==bt_frames,
                  $sformatf("late frames wired +%0d BT +%0d; stale reply or duplicate replay",
                            frm_total[0]-wired_frames,frm_total[1]-bt_frames));

        if(run_fails==0) $display("PASS tb_integration_bt_recovery_business checks=%0d",run_checks);
        else $fatal(1,"FAIL tb_integration_bt_recovery_business checks=%0d fails=%0d",run_checks,run_fails);
        $finish;
    end

    initial begin #(4_000_000_000); $fatal(1,"FAIL integration BT recovery/business watchdog"); end
endmodule
