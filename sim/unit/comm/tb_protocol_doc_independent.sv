`timescale 1ns/1ps
// Independent self-checking v1 protocol testbench for docs/通信协议约定.md.
// Drives the production board top (real comm_top, bridge, router, UARTs) at
// 115200 wired and 9600 Bluetooth 8N1. The host-side CRC/SLIP/frame generator
// and the DUT-TX byte/frame receiver are implemented here, not borrowed from RTL.
// All observations are made through the board top ports or named internal
// status signals; no production RTL is modified.
module tb_protocol_doc_independent;
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

    initial begin : main
        // CRC-16/CCITT-FALSE self-check from docs §6.
        out_body[0]=8'h31; out_body[1]=8'h32; out_body[2]=8'h33; out_body[3]=8'h34;
        out_body[4]=8'h35; out_body[5]=8'h36; out_body[6]=8'h37; out_body[7]=8'h38; out_body[8]=8'h39;
        cself=crc16_body(9);
        pass_fail("crc16_ccitt_false_check_123456789", cself==16'h29b1,
                  $sformatf("expected 29B1, got %04x (docs §6)",cself));

        #100; rst_n=1;
        wait_level_core(200_000_000,0);
        if(!dut.u_system.core_n) $fatal(1,"FATAL core reset never released");
        wait_level_core(500_000_000,1);
        pass_fail("boot_audio_backend_valid", dut.u_system.audio_valid && !dut.u_system.audio_fault,
                  $sformatf("audio_valid=%0b fault=%0b after 500 ms (docs §3.3, REC requires backend ready)",
                            dut.u_system.audio_valid,dut.u_system.audio_fault));
        $display("INFO boot core_n=%0b audio_valid=%0b reverb=%0d source=%0d custom=%0b t=%0t",
                 dut.u_system.core_n,dut.u_system.audio_valid,dut.u_system.audio_state.reverb,
                 dut.u_system.audio_state.source,dut.u_system.audio_state.custom_keys,$time);
        // Let the boot-time loader/config owner reach C_RUN and let any power-up
        // UART edge settle before the first scored request.
        begin : settle_after_boot
            longint t0; t0=$time;
            while((!dut.u_system.u_sound.ready || dut.u_system.quarantine!=0) &&
                  (($time-t0)<200_000_000)) #(10_000);
        end
        #(20_000_000);
        $display("INFO settled ready=%0b cfg_state=%0d quarantine=%b t=%0t",
                 dut.u_system.u_sound.ready,dut.u_system.u_sound.cfg_state,
                 dut.u_system.quarantine,$time);
        $display("INFO pre_warmup bridge=%0d cfg=%0d q=%b perm=%b tx0=%b rx0=%b",
                 dut.u_system.bridge_state,dut.u_system.u_sound.cfg_state,dut.u_system.quarantine,
                 dut.u_system.remote_permission,tx[0],rx[0]);
        // Warm-up: a first valid wired request that is not scored. If the link
        // is healthy this also proves the first-frame path after boot.
        p='0; p[7:0]=8'h02; p[15:8]=8'h00;
        send_frame(0,TYPE_CFG,8'h0f,8'd2,p,1'b0);
        check_reply(0,8'h02,8'h00,8'h0f,"wired_first_frame_after_boot",0,20_000_000,ok);
        if(!ok) $display("INFO warm-up first wired request failed");

        // =================================================================
        // 8) UART baud: 115200 wired and 9600 Bluetooth, back-to-back bytes.
        // =================================================================
        mark(0);
        // Wired 115200: reverb HALL.
        p='0; p[7:0]=8'h02; p[15:8]=8'h01;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h10,8'd2,p,1'b0);
        t_req=last_tx_end[0];
        check_reply(0,8'h02,8'h00,8'h10,"cfg_reverb_hall_wired",b0,20_000_000,ok);
        check_baud(0,WIRED_BIT_NS,b0,"baud_wired_115200_back_to_back");
        pass_fail("reverb_hall_effective", dut.u_system.audio_state.reverb==1,
                  $sformatf("expected audio_state.reverb=1, got %0d (docs §3.1)",dut.u_system.audio_state.reverb));

        // Bluetooth 9600: reverb BATHROOM.
        p='0; p[7:0]=8'h02; p[15:8]=8'h02;
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h11,8'd2,p,1'b0);
        t_req=last_tx_end[1];
        check_reply(1,8'h02,8'h00,8'h11,"cfg_reverb_bathroom_bt",b0,50_000_000,ok);
        check_baud(1,BT_BIT_NS,b0,"baud_BT_9600_back_to_back");
        pass_fail("reverb_bathroom_effective", dut.u_system.audio_state.reverb==2,
                  $sformatf("expected audio_state.reverb=2, got %0d (docs §3.1)",dut.u_system.audio_state.reverb));
        mark_end(0);

        // =================================================================
        // 1) SLIP framing / CRC; invalid frames dropped with no reply.
        // =================================================================
        mark(1);
        // Bad CRC (reverb CHAMBER payload) -> drop, no reply, state unchanged.
        p='0; p[7:0]=8'h02; p[15:8]=8'h03;
        send_frame(0,TYPE_CFG,8'h12,8'd2,p,1'b1);
        expect_no_reply(0,20_000_000,"invalid_bad_crc_dropped_no_reply");
        pass_fail("invalid_bad_crc_preserves_config", dut.u_system.audio_state.reverb==2,
                  $sformatf("reverb changed to %0d after bad-CRC frame (docs §7)",dut.u_system.audio_state.reverb));
        pass_fail("invalid_bad_crc_counted", dut.u_system.u_comm.error_sticky[2]==1'b1,
                  $sformatf("CRC error bit not set: error_sticky=%04x (docs §7)",dut.u_system.u_comm.error_sticky));

        // Illegal SLIP escape DB 00 -> discard until C0.
        raw_buf[0]=C0; raw_buf[1]=TYPE_CFG; raw_buf[2]=8'h13; raw_buf[3]=8'h02;
        raw_buf[4]=8'h02; raw_buf[5]=8'h03; raw_buf[6]=DB; raw_buf[7]=8'h00; raw_buf[8]=C0;
        send_raw(0,9,WIRED_BIT_NS);
        expect_no_reply(0,20_000_000,"invalid_illegal_escape_dropped_no_reply");

        // Declared LEN=3 but only two payload bytes supplied -> length error.
        out_body[0]=TYPE_CFG; out_body[1]=8'h14; out_body[2]=8'h03;
        out_body[3]=8'h02; out_body[4]=8'h03;
        send_body(0,5,WIRED_BIT_NS,1'b0);
        expect_no_reply(0,20_000_000,"invalid_len_mismatch_dropped_no_reply");

        // LEN=65 (>64) and LEN=0 are invalid at the header.
        raw_buf[0]=C0; raw_buf[1]=TYPE_CFG; raw_buf[2]=8'h15; raw_buf[3]=8'h41; raw_buf[4]=C0;
        send_raw(0,5,WIRED_BIT_NS);
        expect_no_reply(0,20_000_000,"invalid_len_65_dropped_no_reply");
        raw_buf[0]=C0; raw_buf[1]=TYPE_CFG; raw_buf[2]=8'h16; raw_buf[3]=8'h00; raw_buf[4]=C0;
        send_raw(0,5,WIRED_BIT_NS);
        expect_no_reply(0,20_000_000,"invalid_len_0_dropped_no_reply");

        // Empty frames (back-to-back C0) are ignored; a valid frame still works.
        raw_buf[0]=C0; raw_buf[1]=C0; raw_buf[2]=C0;
        send_raw(0,3,WIRED_BIT_NS);
        p='0; p[7:0]=8'h02; p[15:8]=8'h00;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h17,8'd2,p,1'b0);
        check_reply(0,8'h02,8'h00,8'h17,"valid_after_invalid_frames",b0,20_000_000,ok);
        pass_fail("valid_after_invalid_effective", dut.u_system.audio_state.reverb==0,
                  $sformatf("expected reverb=0 after valid NONE, got %0d (docs §7)",dut.u_system.audio_state.reverb));
        mark_end(1);

        // =================================================================
        // 2) TYPE=02 CONFIG, TYPE=80 reply, command echo, result codes.
        // =================================================================
        mark(2);
        // 00 success: reverb NONE.
        p='0; p[7:0]=8'h02; p[15:8]=8'h00;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h20,8'd2,p,1'b0);
        check_reply(0,8'h02,8'h00,8'h20,"result_00_success",b0,20_000_000,ok);
        pass_fail("result_00_effective", dut.u_system.audio_state.reverb==0,
                  $sformatf("expected reverb=0, got %0d (docs §4)",dut.u_system.audio_state.reverb));

        // 01 unsupported command 0x55.
        p='0; p[7:0]=8'h55;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h21,8'd1,p,1'b0);
        check_reply(0,8'h55,8'h01,8'h21,"result_01_unsupported_command",b0,20_000_000,ok);

        // 02 command length error: reverb LEN=3.
        p='0; p[7:0]=8'h02; p[15:8]=8'h01; p[23:16]=8'h00;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h22,8'd3,p,1'b0);
        check_reply(0,8'h02,8'h02,8'h22,"result_02_bad_length",b0,20_000_000,ok);

        // 03 out-of-range reverb preset 4.
        p='0; p[7:0]=8'h02; p[15:8]=8'h04;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h23,8'd2,p,1'b0);
        check_reply(0,8'h02,8'h03,8'h23,"result_03_reverb_preset_out_of_range",b0,20_000_000,ok);
        pass_fail("result_03_preserves_config", dut.u_system.audio_state.reverb==0,
                  $sformatf("invalid preset changed reverb to %0d (docs §4, §7)",dut.u_system.audio_state.reverb));

        // 05 same SEQ with different content.
        p='0; p[7:0]=8'h02; p[15:8]=8'h01;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h24,8'd2,p,1'b0);
        check_reply(0,8'h02,8'h00,8'h24,"seq_cache_seed_success",b0,20_000_000,ok);
        p2='0; p2[7:0]=8'h02; p2[15:8]=8'h02;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h24,8'd2,p2,1'b0);
        check_reply(0,8'h02,8'h05,8'h24,"result_05_same_seq_different_content",b0,20_000_000,ok);
        pass_fail("result_05_no_side_effect", dut.u_system.audio_state.reverb==1,
                  $sformatf("expected HALL=1 retained, got %0d (docs §5)",dut.u_system.audio_state.reverb));
        mark_end(2);

        // =================================================================
        // 3) Reverb presets 00/01/02/03 succeed; invalid preset rejected.
        // =================================================================
        mark(3);
        for(int pres=0;pres<4;pres++) begin
            p='0; p[7:0]=8'h02; p[15:8]=8'(pres);
            b0=tx_start_total[0];
            send_frame(0,TYPE_CFG,8'(8'h30+pres),8'd2,p,1'b0);
            check_reply(0,8'h02,8'h00,8'(8'h30+pres),
                        $sformatf("reverb_preset_%0d_success",pres),b0,20_000_000,ok);
            pass_fail($sformatf("reverb_preset_%0d_effective",pres), dut.u_system.audio_state.reverb==pres,
                      $sformatf("expected reverb=%0d, got %0d (docs §3.1)",pres,dut.u_system.audio_state.reverb));
        end
        // Invalid preset plus a valid follow-up.
        p='0; p[7:0]=8'h02; p[15:8]=8'h7f;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h35,8'd2,p,1'b0);
        check_reply(0,8'h02,8'h03,8'h35,"reverb_invalid_preset_rejected",b0,20_000_000,ok);
        mark_end(3);

        // =================================================================
        // 6) Direction: TYPE=01 no reply; host TYPE=80/82 ignored; v2 not v1.
        // =================================================================
        mark(6);
        p='0; p[7:0]=8'h90; p[15:8]=8'h30; p[23:16]=8'h64;
        send_frame(0,TYPE_MIDI,8'h40,8'd3,p,1'b0);
        expect_no_reply(0,20_000_000,"type_01_midi_no_reply");
        p='0; p[7:0]=8'h02; p[15:8]=8'h00;
        send_frame(0,TYPE_REPLY,8'h41,8'd2,p,1'b0);
        expect_no_reply(0,20_000_000,"host_type_80_direction_ignored");
        p='0;
        send_frame(0,TYPE_PERF,8'h42,8'd24,p,1'b0);
        expect_no_reply(0,20_000_000,"host_type_82_direction_ignored");

        // Real v2 frame: version 02, type 02, seq 0009, session 0, payload 02 01.
        // From a v1 parser this looks like TYPE=02 SEQ=02 LEN=09 with a v2 CRC,
        // so the length happens to fit but the v1 CRC must fail.
        p='0; p[7:0]=8'h02; p[15:8]=8'h01;
        send_v2(0,TYPE_CFG,16'h0009,32'h00000000,8'd2,p);
        expect_no_reply(0,20_000_000,"v2_frame_not_accepted_as_v1");
        pass_fail("v2_frame_no_side_effect", dut.u_system.audio_state.reverb==3,
                  $sformatf("v2-looking frame changed reverb to %0d (docs §1: v1 has no VERSION)",dut.u_system.audio_state.reverb));

        // A valid v1 request still works afterwards.
        p='0; p[7:0]=8'h02; p[15:8]=8'h00;
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h43,8'd2,p,1'b0);
        check_reply(0,8'h02,8'h00,8'h43,"valid_v1_after_v2_frame",b0,20_000_000,ok);
        mark_end(6);

        // =================================================================
        // 4) Recording: BT returns 01; wired start/stop, ID mismatch,
        //    unknown/duplicate, 400 ms timeout, failed take -> 06.
        // =================================================================
        mark(4);
        begin : settle_before_record
            longint t0; t0=$time;
            while((!dut.u_system.audio_valid || dut.u_system.u_sound.cfg_state!=3) && (($time-t0)<50_000_000)) #(10_000);
        end
        pass_fail("record_source_eligible", dut.u_system.audio_state.source==0 && dut.u_system.audio_valid,
                  $sformatf("expected PAD source and valid audio for wired recording, source=%0d valid=%0b (docs §3.3)",
                            dut.u_system.audio_state.source,dut.u_system.audio_valid));

        // Unknown stop ID before any take -> 03.
        rid=32'hAABBCCDD;
        p='0; p[7:0]=8'h13; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h50,8'd5,p,1'b0);
        check_reply(0,8'h13,8'h03,8'h50,"record_stop_unknown_id_03",b0,20_000_000,ok);

        // Valid wired start -> 00; record take ID 0x11223344.
        rid=32'h11223344;
        p='0; p[7:0]=8'h12; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        marker=frm_total[0];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h51,8'd5,p,1'b0);
        check_reply(0,8'h12,8'h00,8'h51,"record_wired_start_00",b0,50_000_000,ok);
        begin : await_rec_active
            longint t0; t0=$time;
            while(!dut.u_system.rec_active && (($time-t0)<50_000_000)) #(10_000);
            pass_fail("record_entered_active", dut.u_system.rec_active,
                      $sformatf("rec_active=%0b draining=%0b completed=%0b (docs §3.3)",dut.u_system.rec_active,dut.u_system.rec_draining,dut.u_system.rec_completed));
        end

        // Second start while active, new SEQ -> 04 BUSY.
        rid=32'h55667788;
        p='0; p[7:0]=8'h12; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h52,8'd5,p,1'b0);
        check_reply(0,8'h12,8'h04,8'h52,"record_second_start_busy_04",b0,20_000_000,ok);
        pass_fail("record_busy_keeps_take", dut.u_system.rec_active && dut.u_system.rec_current_id==32'h11223344,
                  $sformatf("active=%0b current_id=%08x (docs §3.3, §4)",dut.u_system.rec_active,dut.u_system.rec_current_id));

        // Stop with a mismatched ID -> 03, take stays active.
        rid=32'hDEADBEEF;
        p='0; p[7:0]=8'h13; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h53,8'd5,p,1'b0);
        check_reply(0,8'h13,8'h03,8'h53,"record_stop_id_mismatch_03",b0,20_000_000,ok);
        pass_fail("record_mismatch_keeps_take", dut.u_system.rec_active,
                  $sformatf("take stopped by mismatched ID (docs §3.3)"));

        // Correct stop -> 00; take emits TYPE=82 start and end.
        rid=32'h11223344;
        p='0; p[7:0]=8'h13; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h54,8'd5,p,1'b0);
        check_reply(0,8'h13,8'h00,8'h54,"record_wired_stop_00",b0,50_000_000,ok);
        begin : await_rec_complete
            longint t0; t0=$time;
            while(!dut.u_system.rec_completed && (($time-t0)<50_000_000)) #(10_000);
            pass_fail("record_completed", dut.u_system.rec_completed && !dut.u_system.rec_failed,
                      $sformatf("completed=%0b failed=%0b (docs §3.3)",dut.u_system.rec_completed,dut.u_system.rec_failed));
        end
        check_perf_take(0,marker,32'h11223344,"record_type82_start_end",sr,en);

        // Duplicate STOP with same SEQ -> cached 00, no new take/events.
        fails_before=frm_total[0];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h54,8'd5,p,1'b0);
        check_reply(0,8'h13,8'h00,8'h54,"record_duplicate_stop_cached_00",b0,20_000_000,ok);
        expect_no_reply(0,1_000_000,"record_duplicate_stop_no_extra_reply");
        pass_fail("record_duplicate_stop_no_events", frm_total[0]==fails_before,
                  $sformatf("duplicate STOP emitted %0d extra frame(s); retry must only replay result (docs §5)",frm_total[0]-fails_before));

        // Duplicate START with old SEQ -> cached 00, must not start a new take.
        rid=32'h11223344;
        p='0; p[7:0]=8'h12; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        fails_before=frm_total[0];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h51,8'd5,p,1'b0);
        check_reply(0,8'h12,8'h00,8'h51,"record_duplicate_start_cached_00",b0,20_000_000,ok);
        pass_fail("record_duplicate_start_no_restart", !dut.u_system.rec_active && frm_total[0]==fails_before,
                  $sformatf("active=%0b extra_frames=%0d; cached reply must not re-execute (docs §5)",
                            dut.u_system.rec_active,frm_total[0]-fails_before));

        // BT recording request -> 01, no take.
        rid=32'hCAFEBABE;
        p='0; p[7:0]=8'h12; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h55,8'd5,p,1'b0);
        check_reply(1,8'h12,8'h01,8'h55,"record_bt_start_01",b0,50_000_000,ok);
        pass_fail("record_bt_start_no_take", !dut.u_system.rec_active,
                  $sformatf("BT start must not create a take, rec_active=%0b (docs §3.3)",dut.u_system.rec_active));
        p='0; p[7:0]=8'h13; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h56,8'd5,p,1'b0);
        check_reply(1,8'h13,8'h01,8'h56,"record_bt_stop_01",b0,50_000_000,ok);

        // Failed take: abort by a wired break, then STOP same ID -> 06.
        rid=32'h0BADF00D;
        p='0; p[7:0]=8'h12; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h57,8'd5,p,1'b0);
        check_reply(0,8'h12,8'h00,8'h57,"record_failed_take_start_00",b0,50_000_000,ok);
        begin : await_active2
            longint t0; t0=$time;
            while(!dut.u_system.rec_active && (($time-t0)<50_000_000)) #(10_000);
        end
        uart_line_fault(0,WIRED_BIT_NS);
        begin : await_abort
            longint t0; t0=$time;
            while((!dut.u_system.rec_completed || !dut.u_system.rec_failed) && (($time-t0)<100_000_000)) #(10_000);
        end
        // Wired idle recovery (32 bit times) plus cleanup.
        begin : await_wired_recovery1
            longint t0; t0=$time;
            while(dut.u_system.quarantine[0] && (($time-t0)<100_000_000)) #(10_000);
        end
        p='0; p[7:0]=8'h13; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h58,8'd5,p,1'b0);
        check_reply(0,8'h13,8'h06,8'h58,"record_failed_stop_06",b0,50_000_000,ok);

        // 400 ms start-completion timeout. Force the audio frame tick low so the
        // capture cannot enter active; the bridge must cancel and reply 06.
        force dut.u_system.spatial_frame_tick=1'b0;
        rid=32'h00C0FFEE;
        p='0; p[7:0]=8'h12; p[15:8]=rid[7:0]; p[23:16]=rid[15:8]; p[31:24]=rid[23:16]; p[39:32]=rid[31:24];
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h59,8'd5,p,1'b0);
        t_req=last_tx_end[0];
        check_reply(0,8'h12,8'h06,8'h59,"record_start_400ms_timeout_06",b0,600_000_000,ok);
        if(ok) begin
            lat=tx_start[0][b0%256]-t_req;
            pass_fail("record_400ms_timeout_latency", (lat>=350_000_000) && (lat<=500_000_000),
                      $sformatf("expected timeout reply 350..500 ms after request, got %0t (docs §3.3: 400 ms)",lat));
            $display("INFO record_400ms_timeout latency=%0t",lat);
        end
        release dut.u_system.spatial_frame_tick;
        #(5_000_000);
        pass_fail("record_timeout_no_active", !dut.u_system.rec_active,
                  $sformatf("rec_active=%0b after timeout (docs §3.3)",dut.u_system.rec_active));
        mark_end(4);

        // =================================================================
        // 5) Keymap: LEN 33/0x21, 16 pairs, mixed -> 03, invalid note/resource
        //    -> 03, success -> 00, same SEQ retry, held pad 500 ms boundary.
        // =================================================================
        mark(5);
        // Valid piano table, deliberately unordered/duplicate/cross-group.
        p='0; p[7:0]=8'h20;
        begin
            automatic logic [7:0] notes[0:15] = '{8'd52,8'd21,8'd22,8'd52,8'd23,8'd24,8'd25,8'd26,
                                                     8'd27,8'd28,8'd29,8'd30,8'd31,8'd32,8'd33,8'd34};
            for(int i=0;i<16;i++) begin
                p[(1+2*i)*8 +:8]=8'h00;
                p[(2+2*i)*8 +:8]=notes[i];
            end
        end
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h60,8'd33,p,1'b0);
        check_reply(0,8'h20,8'h00,8'h60,"keymap_valid_16_pairs_00",b0,50_000_000,ok);
        pass_fail("keymap_custom_committed", dut.u_system.audio_state.custom_keys==1'b1,
                  $sformatf("custom_keys=%0b (docs §3.2)",dut.u_system.audio_state.custom_keys));
        pass_fail("keymap_note_map_all_16", dut.u_system.u_sound.note_map[6:0]==7'd52 &&
                  dut.u_system.u_sound.note_map[13:7]==7'd21 &&
                  dut.u_system.u_sound.note_map[15*7 +:7]==7'd34,
                  $sformatf("note_map[0]=%0d [1]=%0d [15]=%0d expected 52/21/34 (docs §3.2)",
                            dut.u_system.u_sound.note_map[6:0],dut.u_system.u_sound.note_map[13:7],
                            dut.u_system.u_sound.note_map[15*7 +:7]));
        // Same SEQ/same payload retry -> cached 00 and no resource reload.
        begin
            int tx_before; longint t0; tx_before=flash.transactions;
            b0=tx_start_total[0];
            send_frame(0,TYPE_CFG,8'h60,8'd33,p,1'b0);
            check_reply(0,8'h20,8'h00,8'h60,"keymap_same_seq_retry_cached_00",b0,20_000_000,ok);
            t0=$time;
            pass_fail("keymap_retry_no_reload", flash.transactions==tx_before,
                      $sformatf("flash.transactions changed %0d -> %0d; retry must only replay result (docs §5)",
                                tx_before,flash.transactions));
        end
        // Same SEQ/different payload -> 05, table unchanged.
        p2=p; p2[(2+2*0)*8 +:8]=8'd25; // key0 note 52 -> 25
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h60,8'd33,p2,1'b0);
        check_reply(0,8'h20,8'h05,8'h60,"keymap_same_seq_conflict_05",b0,20_000_000,ok);
        pass_fail("keymap_conflict_no_partial_apply", dut.u_system.u_sound.note_map[6:0]==7'd52,
                  $sformatf("note_map[0]=%0d after SEQ conflict (docs §3.2)",dut.u_system.u_sound.note_map[6:0]));

        // Mixed instrument -> 03; no partial apply.
        build_keymap(8'h00,8'd21,1'b1,5'd7,8'h01,8'd41,p);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h61,8'd33,p,1'b0);
        check_reply(0,8'h20,8'h03,8'h61,"keymap_mixed_instrument_03",b0,50_000_000,ok);
        pass_fail("keymap_mixed_no_partial_apply",
                  dut.u_system.u_sound.note_map[6:0]==7'd52 && dut.u_system.u_sound.note_map[15*7 +:7]==7'd34,
                  $sformatf("table changed after mixed-instrument reject (docs §3.2)"));
        // Invalid note above piano range (53) -> 03.
        build_keymap(8'h00,8'd21,1'b1,5'd3,8'h00,8'd53,p);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h62,8'd33,p,1'b0);
        check_reply(0,8'h20,8'h03,8'h62,"keymap_invalid_note_above_range_03",b0,50_000_000,ok);
        // Invalid note below piano range (20) -> 03.
        build_keymap(8'h00,8'd21,1'b1,5'd3,8'h00,8'd20,p);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h63,8'd33,p,1'b0);
        check_reply(0,8'h20,8'h03,8'h63,"keymap_invalid_note_below_range_03",b0,50_000_000,ok);
        // Unsupported resource: flute range notes are legal but flute is not loaded -> 03.
        build_keymap(8'h02,8'd60,1'b0,5'd0,8'h02,8'd0,p);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h64,8'd33,p,1'b0);
        check_reply(0,8'h20,8'h03,8'h64,"keymap_unsupported_resource_03",b0,50_000_000,ok);
        // Invalid/undefined instrument 15 -> 03.
        build_keymap(8'h0f,8'd21,1'b0,5'd0,8'h0f,8'd0,p);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h65,8'd33,p,1'b0);
        check_reply(0,8'h20,8'h03,8'h65,"keymap_invalid_instrument_03",b0,50_000_000,ok);
        pass_fail("keymap_rejects_preserve_table", dut.u_system.u_sound.note_map[6:0]==7'd52,
                  $sformatf("note_map[0]=%0d after rejects (docs §3.2)",dut.u_system.u_sound.note_map[6:0]));

        // LEN 0x20 and 0x22 -> 02 (doc says 33 decimal = 0x21 online).
        build_keymap(8'h00,8'd21,1'b0,5'd0,8'h00,8'd0,p);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h66,8'd32,p,1'b0);
        check_reply(0,8'h20,8'h02,8'h66,"keymap_len_32_rejected_02",b0,50_000_000,ok);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h67,8'd34,p,1'b0);
        check_reply(0,8'h20,8'h02,8'h67,"keymap_len_34_rejected_02",b0,50_000_000,ok);

        // Held-pad control: release after 100 ms, expect 00 and <500 ms.
        // (This proves the test can reach the release path before the deadline.)
        pad_enabled=1'b1;
        begin : wait_pad_control
            longint t0; t0=$time;
            while((dut.u_system.force_map.raw[7:0] < 8'd64) && (($time-t0)<20_000_000)) #(10_000);
        end
        build_keymap(8'h00,8'd22,1'b0,5'd0,8'h00,8'd0,p);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h68,8'd33,p,1'b0);
        #(100_000_000);
        pad_enabled=1'b0;
        check_reply(0,8'h20,8'h00,8'h68,"keymap_held_pad_released_100ms_00",b0,400_000_000,ok);
        if(ok) begin
            lat=tx_start[0][b0%256]-last_tx_end[0];
            pass_fail("keymap_held_pad_released_100ms_within_500ms", lat<500_000_000,
                      $sformatf("reply latency %0t after request, deadline 500 ms (docs §5.1)",lat));
        end
        // Let the analyzer/bridge retire the previous request before sending
        // the next keymap frame; otherwise the next frame is simply dropped
        // by the busy parser and the held-pad case tests nothing.
        #(20_000_000);

        // Isolate the held-pad case from the previous keymap transaction.
        rst_n=1'b0; #(2_000_000); rst_n=1'b1;
        wait(dut.u_system.core_n); wait(dut.u_system.audio_valid);
        wait(dut.u_system.u_sound.have_commit); #(20_000_000);
        // Held-pad boundary: hold beyond 500 ms. docs §5.1 requires the board to
        // complete and reply within 500 ms or return 04 BUSY, and explicitly
        // forbids waiting indefinitely for key release.
        pad_enabled=1'b1;
        begin : wait_pad_long
            longint t0; t0=$time;
            while((dut.u_system.force_map.raw[7:0] < 8'd64) && (($time-t0)<20_000_000)) #(10_000);
        end
        build_keymap(8'h00,8'd23,1'b0,5'd0,8'h00,8'd0,p);
        b0=tx_start_total[0];
        send_frame(0,TYPE_CFG,8'h69,8'd33,p,1'b0);
        t_req=last_tx_end[0];
        begin : hold_500_boundary
            longint t0; int got500; longint t500;
            t0=$time; got500=0; t500=0;
            begin : held_loop
                logic printed450;
                printed450=0;
                while(($time-t0)<500_000_000) begin
                    if(!printed450 && (($time-t0)>=450_000_000)) begin
                        printed450=1;
                        $display("HELD450 cfg_state=%0d inflight=%b validating=%b waiting_release=%b arm_pad=%b pads_released=%b force_raw=%02x rsp_valid=%b bridge=%0d q=%b",
                            dut.u_system.u_sound.cfg_state,dut.u_system.u_sound.keymap_inflight,
                            dut.u_system.u_sound.keymap_validating,dut.u_system.u_sound.keymap_waiting_release,
                            dut.u_system.u_sound.arm_pad,dut.u_system.u_sound.pads_released,
                            dut.u_system.force_map.raw[7:0],dut.u_system.u_sound.keymap_rsp_valid,
                            dut.u_system.bridge_state,dut.u_system.quarantine);
                    end
                    if(frm_total[0]>b0) begin got500=1; t500=$time; break; end
                    #(10_000);
                end
            end
            if(!got500) begin
                // No reply by 500 ms while the pad is held: record the observed
                // release-dependent behaviour and then release to unblock it.
                lat=0;
                pass_fail("keymap_held_pad_500ms_deadline",0,
                    "no reply within 500 ms while pad held; docs §5.1 requires completion/BUSY within 500 ms and forbids waiting for key release");
                pad_enabled=1'b0;
                begin : release_after_500
                    longint tr; tr=$time;
                    while((frm_total[0]==b0) && (($time-tr)<200_000_000)) #(10_000);
                    $display("AFTER_RELEASE cfg_state=%0d inflight=%b validating=%b waiting_release=%b arm_pad=%b pads_released=%b force_raw=%02x rsp_valid=%b bridge=%0d q=%b",
                        dut.u_system.u_sound.cfg_state,dut.u_system.u_sound.keymap_inflight,
                        dut.u_system.u_sound.keymap_validating,dut.u_system.u_sound.keymap_waiting_release,
                        dut.u_system.u_sound.arm_pad,dut.u_system.u_sound.pads_released,
                        dut.u_system.force_map.raw[7:0],dut.u_system.u_sound.keymap_rsp_valid,
                        dut.u_system.bridge_state,dut.u_system.quarantine);
                end
                if(frm_total[0]>b0) begin
                    lat=$time-t_req;
                    pass_fail("keymap_held_pad_reply_after_release",0,
                        $sformatf("reply only after release at ~%0t (>500 ms), expected <=500 ms or 04 BUSY (docs §5.1)",lat));
                    check_reply(0,8'h20,8'h00,8'h69,"keymap_held_pad_eventual_00",b0,1_000_000,ok);
                end else begin
                    pass_fail("keymap_held_pad_reply_after_release",0,
                        "still no reply 200 ms after pad release (docs §3.2/§5.1)");
                end
            end else begin
                lat=t500-t_req;
                pass_fail("keymap_held_pad_500ms_deadline", lat<=500_000_000,
                    $sformatf("reply latency %0t while pad held, deadline 500 ms (docs §5.1)",lat));
                pad_enabled=1'b0;
            end
        end
        mark_end(5);
        if($test$plusargs("KEYMAP_ONLY")) begin
            if(cat_keymap_f!=0) $fatal(1,"FAIL keymap-only checks=%0d fails=%0d",run_checks,cat_keymap_f);
            $display("PASS keymap-only checks=%0d",run_checks);
            $finish;
        end

        // =================================================================
        // 7) BT quarantine recovery after a UART framing fault, no stale reply.
        // =================================================================
        mark(7);
        // Establish a known BT reply, then start another request and inject a
        // break while it is being processed/replied. Fault must quarantine BT,
        // flush the old reply, recover on line idle, and not replay it.
        p='0; p[7:0]=8'h02; p[15:8]=8'h01;
        b0=tx_start_total[1];
        send_frame(1,TYPE_CFG,8'h70,8'd2,p,1'b0);
        check_reply(1,8'h02,8'h00,8'h70,"bt_pre_fault_config_00",b0,50_000_000,ok);

        begin
            int pre_fault; pre_fault=frm_total[1];
            p='0; p[7:0]=8'h02; p[15:8]=8'h02;
            send_frame(1,TYPE_CFG,8'h71,8'd2,p,1'b0);
            // Break on BT RX immediately after the request (before the slow
            // 9600 reply can complete). The DUT must abort the queued reply.
            uart_line_fault(1,BT_BIT_NS);
            begin : wait_bt_quarantine
                longint t0; t0=$time;
                while(!dut.u_system.quarantine[1] && (($time-t0)<50_000_000)) #(10_000);
                pass_fail("bt_framing_fault_quarantines", dut.u_system.quarantine[1],
                          $sformatf("quarantine[1]=%0b after BT break (docs §7 / BT idle recovery)",dut.u_system.quarantine[1]));
            end
            begin : wait_bt_recovery
                longint t0; int qcount; t0=$time; qcount=frm_total[1];
                while(dut.u_system.quarantine[1] && (($time-t0)<200_000_000)) #(10_000);
                pass_fail("bt_idle_recovery_reopens_link", !dut.u_system.quarantine[1],
                          $sformatf("still quarantined 200 ms after idle (docs §7, 9600 BT idle recovery)"));
                // No stale reply from the canceled request may appear after recovery.
                #(50_000_000);
                pass_fail("bt_no_stale_reply_after_recovery", frm_total[1]==qcount,
                          $sformatf("received %0d frame(s) after recovery without a new request; stale reply not flushed (docs §5, §7)",
                                    frm_total[1]-qcount));
            end
            // BT must accept a fresh request and produce exactly one reply.
            p='0; p[7:0]=8'h02; p[15:8]=8'h00;
            b0=tx_start_total[1];
            send_frame(1,TYPE_CFG,8'h72,8'd2,p,1'b0);
            check_reply(1,8'h02,8'h00,8'h72,"bt_post_recovery_config_00",b0,50_000_000,ok);
            pass_fail("bt_recovery_effective_reverb", dut.u_system.audio_state.reverb==0,
                      $sformatf("expected reverb=0 after recovery command, got %0d (docs §3.1)",dut.u_system.audio_state.reverb));
            pass_fail("bt_break_error_counted", dut.u_system.u_comm.error_sticky[6]==1'b1,
                      $sformatf("break/error sticky not set: error_sticky=%04x (docs §7)",dut.u_system.u_comm.error_sticky));
            // Wired side must be independent of BT quarantine.
            p='0; p[7:0]=8'h02; p[15:8]=8'h01;
            b0=tx_start_total[0];
            send_frame(0,TYPE_CFG,8'h73,8'd2,p,1'b0);
            check_reply(0,8'h02,8'h00,8'h73,"wired_works_after_bt_recovery",b0,20_000_000,ok);
        end
        mark_end(7);

        // =================================================================
        // Summary / pass-fail table
        // =================================================================
        $display("SUMMARY_TABLE category|failures");
        $display("SUMMARY_TABLE baud_uart|%0d",cat_baud_f);
        $display("SUMMARY_TABLE framing_crc|%0d",cat_frame_f);
        $display("SUMMARY_TABLE config_result_codes|%0d",cat_cfg_f);
        $display("SUMMARY_TABLE reverb|%0d",cat_reverb_f);
        $display("SUMMARY_TABLE recording|%0d",cat_record_f);
        $display("SUMMARY_TABLE keymap|%0d",cat_keymap_f);
        $display("SUMMARY_TABLE direction_v2|%0d",cat_dir_f);
        $display("SUMMARY_TABLE bt_recovery|%0d",cat_recovery_f);
        $display("SUMMARY checks=%0d fails=%0d",run_checks,run_fails);
        if(run_fails==0) begin
            $display("PASS tb_protocol_doc_independent checks=%0d",run_checks);
            $finish;
        end else begin
            $display("FAIL tb_protocol_doc_independent total_fails=%0d",run_fails);
            $fatal(1,"FAIL tb_protocol_doc_independent total_fails=%0d",run_fails);
        end
    end

    initial begin
        #(5_000_000_000);
        $display("FATAL watchdog at %0t (bridge=%0d cfg=%0d quarantine=%b rec=%0b)",
                 $time,dut.u_system.bridge_state,dut.u_system.u_sound.cfg_state,
                 dut.u_system.quarantine,dut.u_system.rec_active);
        $fatal(1,"FATAL watchdog");
    end
endmodule
