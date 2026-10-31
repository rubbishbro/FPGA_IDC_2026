`timescale 1ns/1ps
module tb_midi_guide_state;
    logic clk=0,rst_n=0,tick_ms=0,clear=0,source_id=0,event_valid=0,event_ready,idle;
    always #5 clk=~clk;
    logic [31:0] event_data=0,outside_count;
    logic [111:0] note_map;
    logic [1:0] cleanup=0,cleanup_done;
    logic [15:0] target,glow;
    logic [6:0] last_outside;
    integer checks=0;
    midi_guide_state dut(.clk(clk),.rst_n(rst_n),.tick_ms(tick_ms),.clear(clear),.source_id(source_id),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.note_map(note_map),
        .source_cleanup_req(cleanup),.source_cleanup_done(cleanup_done),.idle(idle),
        .target(target),.glow(glow),.outside_count(outside_count),.last_outside(last_outside));
    task automatic ck(input logic ok,input string msg);
        checks++;if(ok!==1'b1)$fatal(1,"FAIL %s",msg);
    endtask
    task automatic send(input integer kind,note,velocity);
        @(negedge clk);event_data={4'(kind),4'd1,7'(note),7'(velocity),10'd0};event_valid=1;
        ck(event_ready,"display consumer ready");@(negedge clk);event_valid=0;
    endtask
    task automatic milliseconds(input integer count);
        for(integer i=0;i<count;i++)begin
            @(negedge clk);tick_ms=1;@(negedge clk);tick_ms=0;
        end
    endtask
    initial begin
        note_map=router_pkg::default_note_map();
        repeat(4)@(negedge clk);rst_n=1;
        for(integer i=0;i<16;i++)begin
            send(1,note_map[i*7 +:7],100);ck(target[i] && glow[i],"each loaded non-contiguous pitch lights correct slot");
            send(0,note_map[i*7 +:7],0);ck(!target[i] && glow[i],"short Off releases target but remains visible");
        end
        milliseconds(79);ck(glow==16'hffff,"minimum display hold survives 79ms");
        milliseconds(1);ck(glow==0,"hold expires at 80ms");
        send(1,60,1);send(1,64,127);ck(target==16'h1400,"chord with low/high velocity");
        send(2,64,127);send(1,60,0);ck(target==16'h1000,"sustain cannot keep target after zero-velocity On");
        send(1,64,99);send(0,64,0);ck(target==0,"repeated On follows one-Off policy");
        send(1,61,100);ck(outside_count==1 && last_outside==61 && target==0,"missing pitch reported, never rounded");
        send(1,60,100);send(2,123,0);ck(target==0 && glow==0,"all notes off clears prompt/hold");
        send(1,60,100);send(2,120,0);ck(target==0 && glow==0,"all sound off is display-only cleanup");
        send(1,60,100);cleanup=2;@(negedge clk);
        ck(target[10] && cleanup_done==2,"unrelated source cleanup cannot clear active source");
        cleanup=1;@(negedge clk);ck(target==0 && glow==0 && cleanup_done==1,"active source cleanup is acknowledged after clear");
        cleanup=0;source_id=1;@(negedge clk);send(1,60,100);
        cleanup=2;event_valid=1;event_data={4'd1,4'd1,7'd64,7'd100,10'd0};
        @(negedge clk);ck(target==0 && !event_ready,"cleanup wins over simultaneous event");
        event_valid=0;cleanup=0;clear=1;@(negedge clk);clear=0;
        ck(outside_count==0 && target==0 && idle,"configuration clear resets diagnostics and target");
        rst_n=0;@(negedge clk);ck(target==0 && glow==0 && !idle,"reset clears complete consumer");
        $display("PASS tb_midi_guide_state checks=%0d",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL guide state watchdog");end
endmodule
