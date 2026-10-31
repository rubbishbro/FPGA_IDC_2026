`timescale 1ns/1ps
// eng1 routing only: synthetic stable ABC coefficients, current default pulse.
module tb_router_midi_eng1;
    import router_pkg::*;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    pad_driver_pkg::mat4x4 fmap='0;
    logic midi_valid=0,midi_ready;
    logic [3:0] midi_gate=0,midi_retrigger=0,midi_hard_clear=0;
    logic [27:0] midi_velocity=0;
    logic done,y_valid;
    logic signed [63:0] y_data;
    logic [3:0] qspi_i;
    w25q64_read_model #(.N_MODES(4)) flash(.cs_n(dut.qspi_cs_n),.sck(dut.qspi_sck),
        .dq_o(dut.qspi_dq_o),.dq_oe(dut.qspi_dq_oe),.blank(1'b0),.dq_i(qspi_i));
    integer outputs=0,nonzero_outputs=0,checks=0;
    voice_router #(.SLOTS(4),.N_MODES(4),.CLK_HZ(10_000_000),.SR_HZ(10_000),.MIDI_ENABLE(1)) dut (
        .clk(clk),.rst_n(rst_n),.fmap(fmap),.inst(INST_FLUTE),.reverb_preset(REVERB_NONE),
        .reload(1'b0),.start(1'b1),.done(done),.ready(),.load_err(),.y_valid(y_valid),.y_data(y_data),
        .qspi_cs_n(),.qspi_sck(),.qspi_dq_o(),.qspi_dq_oe(),.qspi_dq_i(qspi_i),
        .maintenance_clear(1'b0),.map_reload(1'b0),.load_offsets('0),
        .maintenance_done(),.midi_inflight(),.voice_idle(),.load_complete(),.table_valid(),
        .midi_select(1'b1),.midi_valid(midi_valid),.midi_ready(midi_ready),.midi_gate(midi_gate),
        .midi_velocity(midi_velocity),.midi_retrigger(midi_retrigger),.midi_hard_clear(midi_hard_clear),
        .ns_rd_en(1'b0),.ns_rd_addr(4'd0),.ns_rd_sel(1'b0),.ns_rd_data(),.ns_rd_valid()
    );
    task automatic ck(input logic ok,input string msg);
        checks++;
        if(ok!==1'b1) $fatal(1,"FAIL %s",msg);
    endtask
    always @(posedge clk) if(rst_n && y_valid) begin
        outputs++;
        if($isunknown(y_data)) $fatal(1,"FAIL unknown eng1 output");
        if(y_data!=0) nonzero_outputs++;
    end
    longint signed expected_mix=0, term_a, term_b;
    integer mix_checks=0;
    always @(posedge clk) if(rst_n) begin
        if(dut.era_yv && dut.erb_yv) begin
            term_a=($signed(dut.era_y)*$signed(dut.emap[dut.g])) >>> 31;
            term_b=($signed(dut.erb_y)*$signed(dut.emap[dut.g+2])) >>> 31;
            expected_mix=(dut.g==0 ? 0 : expected_mix)+term_a+term_b;
        end
        if(dut.body_accept) begin
            mix_checks++;
            if(dut.mix_q!==expected_mix)
                $fatal(1,"FAIL bank A/B mix got=%0d expected=%0d",dut.mix_q,expected_mix);
        end
    end
    task automatic operation;
        @(negedge clk);midi_valid=1;
        while(!midi_ready) @(negedge clk);
        @(negedge clk);midi_valid=0;midi_retrigger=0;midi_hard_clear=0;
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        wait(dut.inst_prev==INST_FLUTE && dut.active_midi && done);
        @(negedge clk);
        // G=1, a1=-0.5 in Q2.24; keep the original synthetic decay.
        force dut.co_ra = {32'd16777216,32'hff800000,32'd0,32'd0,32'd0,32'd0,32'd0};
        force dut.co_rb = {32'd16777216,32'hff800000,32'd0,32'd0,32'd0,32'd0,32'd0};
        midi_gate=4;midi_retrigger=4;midi_velocity[20:14]=1;
        operation();
        ck(dut.note_on==4 && dut.u_exc.u_gen.tgt[2]==(32'(2)<<16),"eng1 low velocity reaches default excitation");
        repeat(40) begin wait(y_valid);@(negedge clk);wait(!y_valid); end
        wait(done);@(negedge clk);
        ck(dut.q_ram_b[0]>0 && nonzero_outputs>0,"eng1 consumes actual excitation and produces samples");
        midi_hard_clear=4;midi_gate=0;
        operation();
        for(integer i=0;i<4;i++) ck(dut.q_ram_b[i]==0 && dut.v_ram_b[i]==0,"eng1 hard clear includes both history states");
        ck(dut.emap[2]==0,"constant envelope branch obeys MIDI gate");
        $display("PASS tb_router_midi_eng1 checks=%0d outputs=%0d mix_checks=%0d",checks,outputs,mix_checks);$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL eng1 timeout");end
endmodule
