`timescale 1ns/1ps
// Independent self-checking v1 protocol testbench for docs/通信协议约定.md.
// Drives the production board top (real comm_top, bridge, router, UARTs) at
// 115200 wired and 9600 Bluetooth 8N1. The host-side CRC/SLIP/frame generator
// and the DUT-TX byte/frame receiver are implemented here, not borrowed from RTL.
// All observations are made through the board top ports or named internal
// status signals; no production RTL is modified.
module tb_keymap_held_only;
    localparam int  SYS_CLK_HZ   = 50_000_000;
    localparam real WIRED_BIT_NS = 1.0e9 / 115200.0;
    localparam real BT_BIT_NS    = 1.0e9 / 9600.0;
    localparam int  MAX_FRAMES   = 64;
    localparam int  FRAME_BYTES  = 96;
    localparam logic [7:0] C0=8'hc0, DB=8'hdb, DC=8'hdc, DD=8'hdd;
    localparam logic [7:0] TYPE_MIDI=8'h01, TYPE_CFG=8'h02, TYPE_REPLY=8'h80, TYPE_PERF=8'h82;

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
        @(negedge clk);
        rx[src]=1'b0; #(bit_ns);
        for(int i=0;i<8;i++) begin rx[src]=b[i]; #(bit_ns); end
        rx[src]=1'b1; #(bit_ns);
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

    // A real v2 body: version=02, type, seq:u16le, len:u16le, session:u32le, payload, crc16.
    task automatic send_v2(input int src, input logic [7:0] v2_type, input logic [15:0] seq16,
                           input logic [31:0] session, input logic [7:0] len,
                           input logic [511:0] payload);
        real bit_ns;
        begin
            bit_ns=(src==0)?WIRED_BIT_NS:BT_BIT_NS;
            out_body[0]=8'h02; out_body[1]=v2_type;
            out_body[2]=seq16[7:0]; out_body[3]=seq16[15:8];
            out_body[4]=len; out_body[5]=8'h00;
            out_body[6]=session[7:0]; out_body[7]=session[15:8];
            out_body[8]=session[23:16]; out_body[9]=session[31:24];
            for(int i=0;i<len;i++) out_body[10+i]=payload[i*8 +:8];
            send_body(src,10+len,bit_ns,1'b0);
        end
    endtask

    task automatic send_raw(input int src, input int n, input real bit_ns);
        begin
            req_frame_base[src]=frm_total[src];
            for(int i=0;i<n;i++) uart_byte(src,raw_buf[i],bit_ns);
            last_tx_end[src]=$time;
        end
    endtask
    logic [7:0] raw_buf [0:255];

    // ------------------------------------------------------------------
    // Independent DUT-TX UART receiver and SLIP frame history per source
    // ------------------------------------------------------------------
    longint tx_start [0:1][0:255];
    int tx_start_total [0:1];

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
            // The for-loop's final #(bit_ns) already placed us at 9.5 bit
            // times, i.e. the stop-bit centre. Move to just before the next
            // possible start edge.
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

    task automatic await_frame(input int src, input int old_total, input longint timeout_ns, output int got);
        longint t0;
        begin
            got=0; t0=$time;
            while((frm_total[src]==old_total) && (($time-t0)<timeout_ns)) #(5000);
            if(frm_total[src]>old_total) got=1;
        end
    endtask

    // Check a TYPE=80 reply with command echo, SEQ and result. Latency is measured
    // from the last host request stop bit to the first DUT start edge.
    task automatic check_reply(input int src, input logic [7:0] exp_cmd, input logic [7:0] exp_res,
                               input logic [7:0] exp_seq, input string name, input int n0,
                               input longint timeout_ns, output int ok);
        int old,got,idx,found,len; logic good; logic [15:0] c; longint lat,deadline;
        begin
            old=req_frame_base[src]; ok=0; found=-1;
            // The reply can complete before this task is entered, and TYPE=82
            // descriptors may precede the TYPE=80 reply. Keep scanning until the
            // matching reply appears (or the timeout expires).
            // The production bridge/backend reply latency measured on this
            // worktree is ~32 ms (UI/audio transaction). Keep the self-check
            // timeout above that so only the 500 ms contract is judged.
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
                pass_fail(name,0,$sformatf("no matching TYPE=80 SEQ=%02x reply among %0d frame(s) captured since request (docs §4, §5.1)",
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
            if(tx_start_total[src]>n0) lat=tx_start[src][n0%256]-last_tx_end[src]; else lat=-1;
            if(!good) begin
                pass_fail(name,0,$sformatf(
                    "expected TYPE=80 SEQ=%02x LEN=02 CMD=%02x RES=%02x; actual len=%0d TYPE=%02x SEQ=%02x LEN=%02x CMD=%02x RES=%02x CRCok=%0b lat=%0t (docs §4)",
                    exp_seq,exp_cmd,exp_res,len,fbyte(src,idx,0),fbyte(src,idx,1),fbyte(src,idx,2),
                    fbyte(src,idx,3),fbyte(src,idx,4),
                    (len>=7)?({fbyte(src,idx,6),fbyte(src,idx,5)}==crc16_mem(src,idx)):1'b0,lat));
                return;
            end
            ok=1;
            pass_fail(name,1,"");
        end
    endtask

    task automatic expect_no_reply(input int src, input longint duration_ns, input string name);
        int old;
        begin
            old=frm_total[src];
            #(duration_ns);
            if(frm_total[src]!=old)
                pass_fail(name,0,$sformatf("received %0d frame(s); invalid/direction frames must be dropped without reply (docs §7, §4)",
                    frm_total[src]-old));
            else pass_fail(name,1,"");
        end
    endtask

    task automatic check_baud(input int src, input real bit_ns, input int n0, input string name);
        int cnt; int bad; real exp,avg; longint d,sum; longint lat;
        begin
            cnt=tx_start_total[src]-n0;
            exp=10.0*bit_ns; bad=0; sum=0;
            if(cnt<2) begin
                pass_fail(name,0,$sformatf("only %0d DUT start edges, cannot measure bit period",cnt));
                return;
            end
            for(int k=0;k<cnt-1;k++) begin
                d=tx_start[src][(n0+k+1)%256]-tx_start[src][(n0+k)%256];
                sum=sum+d;
                if((d < 0.97*exp) || (d > 1.03*exp+50.0)) bad=bad+1;
            end
            avg=real'(sum)/real'(cnt-1)/10.0;
            lat=tx_start[src][n0%256]-last_tx_end[src];
            if(bad!=0)
                pass_fail(name,0,$sformatf(
                    "measured bit=%0.1f ns expected=%0.1f ns over %0d byte intervals, %0d out of tolerance; latency=%0t (docs §1, §3.3; 9600/115200 8N1)",
                    avg,bit_ns,cnt-1,bad,lat));
            else
                pass_fail(name,1,$sformatf("measured bit=%0.1f ns expected=%0.1f ns edges=%0d latency=%0t",avg,bit_ns,cnt,lat));
        end
    endtask

    // ------------------------------------------------------------------
    // Test helpers
    // ------------------------------------------------------------------
    task automatic wait_level_core(input longint timeout_ns, input int which);
        longint t0; begin
            t0=$time;
            while(($time-t0)<timeout_ns) begin
                if(which==0 && dut.u_system.core_n) return;
                if(which==1 && dut.u_system.audio_valid) return;
                #(1000);
            end
        end
    endtask

    task automatic uart_line_fault(input int src, input real bit_ns);
        begin
            @(negedge clk);
            rx[src]=1'b0;
            #(bit_ns*14.0);
            rx[src]=1'b1;
            #(bit_ns*2.0);
        end
    endtask

    task automatic build_keymap(input logic [7:0] inst, input logic [7:0] base_note,
                                input bit mixed_other, input logic [4:0] other_slot,
                                input logic [7:0] other_inst, input logic [7:0] other_note,
                                output logic [511:0] p);
        begin
            p='0; p[7:0]=8'h20;
            for(int i=0;i<16;i++) begin
                p[(1+2*i)*8 +:8]=(mixed_other && (i==other_slot)) ? other_inst : inst;
                p[(2+2*i)*8 +:8]=(mixed_other && (i==other_slot)) ? other_note : (base_note+8'(i));
            end
        end
    endtask

    // Iterate the TYPE=82 frames captured since a marker and validate the take.
    task automatic check_perf_take(input int src, input int marker, input logic [31:0] exp_id,
                                   input string name, output int starts, output int ends);
        int idx,len,kind; logic ok; longint t0;
        begin
            starts=0; ends=0; ok=1; t0=$time;
            // Wait up to 50 ms for both START and END descriptors to be captured.
            while((($time-t0)<50_000_000)) begin
                starts=0; ends=0;
                for(int f=marker;f<frm_total[src];f++) begin
                    idx=f%MAX_FRAMES;
                    if(frm_len[src][idx]==29 && fbyte(src,idx,0)==TYPE_PERF) begin
                        kind=fbyte(src,idx,3);
                        if(kind==0) starts=starts+1;
                        else if(kind==3) ends=ends+1;
                    end
                end
                if(starts>=1 && ends>=1) break;
                #(10_000);
            end
            starts=0; ends=0;
            for(int f=marker;f<frm_total[src];f++) begin
                idx=f%MAX_FRAMES; len=frm_len[src][idx];
                if(fbyte(src,idx,0)==TYPE_PERF) begin
                    if(len!=29) ok=0;
                    else if({fbyte(src,idx,6),fbyte(src,idx,5)}!=crc16_mem(src,idx)) ok=0;
                    else if(fbyte(src,idx,2)!=24) ok=0;
                    else begin
                        kind=fbyte(src,idx,3);
                        if({fbyte(src,idx,10),fbyte(src,idx,9),fbyte(src,idx,8),fbyte(src,idx,7)}!=exp_id) ok=0;
                        if(kind==0) begin
                            starts=starts+1;
                            if({fbyte(src,idx,22),fbyte(src,idx,21),fbyte(src,idx,20),fbyte(src,idx,19)}!=32'd12500000) ok=0;
                            if({fbyte(src,idx,26),fbyte(src,idx,25),fbyte(src,idx,24),fbyte(src,idx,23)}!=32'd256) ok=0;
                        end else if(kind==3) begin
                            ends=ends+1;
                            if(fbyte(src,idx,4)!=0) ok=0; // flags=0 for normal take
                        end
                    end
                end
            end
            if((starts!=1)||(ends!=1)) ok=0;
            pass_fail(name,ok,$sformatf(
                "expected exactly one TYPE=82 start(kind00) and one end(kind03), id=%08x, LEN=24, CRCok; got starts=%0d ends=%0d over %0d frames (docs §3.3.1)",
                exp_id,starts,ends,frm_total[src]-marker));
        end
    endtask

    int cat_baud,cat_frame,cat_cfg,cat_reverb,cat_record,cat_keymap,cat_dir,cat_recovery;
    int cat_baud_f,cat_frame_f,cat_cfg_f,cat_reverb_f,cat_record_f,cat_keymap_f,cat_dir_f,cat_recovery_f;

    task automatic mark(input int which);
        begin
            case(which)
                0:cat_baud=run_fails; 1:cat_frame=run_fails; 2:cat_cfg=run_fails;
                3:cat_reverb=run_fails; 4:cat_record=run_fails; 5:cat_keymap=run_fails;
                6:cat_dir=run_fails; 7:cat_recovery=run_fails;
            endcase
        end
    endtask
    task automatic mark_end(input int which);
        begin
            case(which)
                0:cat_baud_f=run_fails-cat_baud; 1:cat_frame_f=run_fails-cat_frame;
                2:cat_cfg_f=run_fails-cat_cfg; 3:cat_reverb_f=run_fails-cat_reverb;
                4:cat_record_f=run_fails-cat_record; 5:cat_keymap_f=run_fails-cat_keymap;
                6:cat_dir_f=run_fails-cat_dir; 7:cat_recovery_f=run_fails-cat_recovery;
            endcase
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    logic [511:0] p;
    logic [511:0] p2;
    logic [15:0] cself;
    int ok, sr, en, marker, n0, b0;
    longint t_req, t_reply, lat;
    logic [31:0] rid;
    int fails_before;


    // Focused held-pad keymap test: no prior keymap/config/record transaction.
    // The request must be admitted before the 400 ms release-wait timer is judged.
    logic [111:0] saved_map;
    logic         saved_custom;
    int           before_frames;

    task automatic reboot_and_wait;
        begin
            pad_enabled=1'b0;
            rst_n=1'b0;
            #(2_000_000);
            rst_n=1'b1;
            wait_level_core(200_000_000,0);
            if(!dut.u_system.core_n) $fatal(1,"FAIL core reset never released");
            wait_level_core(500_000_000,1);
            if(!dut.u_system.audio_valid) $fatal(1,"FAIL audio_valid never asserted");
            wait(dut.u_system.u_sound.have_commit);
            wait(dut.u_system.bridge_state==0);
            #(10_000_000);
            if(dut.u_system.u_sound.keymap_inflight) $fatal(1,"FAIL stale keymap at boot");
        end
    endtask

    task automatic wait_keymap_admitted;
        longint t0;
        begin
            t0=$time;
            while(!dut.u_system.u_sound.keymap_inflight && (($time-t0)<20_000_000)) #(10_000);
            if(!dut.u_system.u_sound.keymap_inflight)
                $fatal(1,"FAIL keymap request not admitted: bridge=%0d cfg=%0d frames=%0d",
                       dut.u_system.bridge_state,dut.u_system.u_sound.cfg_state,frm_total[0]);
        end
    endtask

    initial begin : main
        // Held-pad timeout: request is admitted, table is NOT updated, 04 within 500 ms.
        reboot_and_wait();
        saved_map=dut.u_system.u_sound.committed_map;
        saved_custom=dut.u_system.audio_state.custom_keys;
        pad_enabled=1'b1;
        begin : wait_pad_held
            longint t0; t0=$time;
            while((dut.u_system.force_map.raw[7:0]<8'd64) && (($time-t0)<20_000_000)) #(10_000);
        end
        build_keymap(8'h00,8'd21,1'b0,5'd0,8'h00,8'd0,p);
        b0=tx_start_total[0];
        send_frame(0,8'h02,8'h70,8'd33,p,1'b0);
        wait_keymap_admitted();
        check_reply(0,8'h20,8'h04,8'h70,"held_pad_timeout_04",b0,500_000_000,ok);
        if(ok) begin
            pass_fail("held_pad_timeout_table_unchanged",
                      dut.u_system.u_sound.committed_map==saved_map &&
                      dut.u_system.audio_state.custom_keys==saved_custom,
                      "timeout updated the committed keymap");
            before_frames=frm_total[0];
            pad_enabled=1'b0;
            #(200_000_000);
            pass_fail("held_pad_timeout_no_late_commit",
                      frm_total[0]==before_frames &&
                      dut.u_system.u_sound.committed_map==saved_map &&
                      dut.u_system.audio_state.custom_keys==saved_custom,
                      "late release after 04 changed the table or emitted a second reply");
        end

        // Release-before-timeout: normal 00 and table update.
        reboot_and_wait();
        saved_map=dut.u_system.u_sound.committed_map;
        pad_enabled=1'b1;
        begin : wait_pad_held2
            longint t0; t0=$time;
            while((dut.u_system.force_map.raw[7:0]<8'd64) && (($time-t0)<20_000_000)) #(10_000);
        end
        build_keymap(8'h00,8'd21,1'b0,5'd0,8'h00,8'd0,p);
        b0=tx_start_total[0];
        send_frame(0,8'h02,8'h71,8'd33,p,1'b0);
        wait_keymap_admitted();
        #(100_000_000);
        pad_enabled=1'b0;
        check_reply(0,8'h20,8'h00,8'h71,"held_pad_release_00",b0,500_000_000,ok);
        if(ok)
            pass_fail("held_pad_release_commits",
                      dut.u_system.u_sound.committed_map!=saved_map &&
                      dut.u_system.audio_state.custom_keys==1'b1,
                      "release-before-timeout did not commit the keymap");

        if(run_fails==0) $display("PASS tb_keymap_held_only checks=%0d",run_checks);
        else $fatal(1,"FAIL tb_keymap_held_only checks=%0d fails=%0d",run_checks,run_fails);
        $finish;
    end
    initial begin #2000000000; $fatal(1,"FAIL keymap held-only watchdog"); end
endmodule
