// Keep the real router load/commit path; audio outputs are intentionally unused.
module record_pitch_probe(input wire clk,rst_n,run,reload,tick,input wire [111:0] notes,input pad_driver_pkg::mat4x4 fmap,input router_pkg::instrument_e inst,input wire [3:0] dq,output wire [111:0] snapshot,output wire valid,output wire cs,sck,oe,output wire [3:0] dout);
logic [111:0] note_map;always_comb note_map=notes;
voice_router #(.MIDI_ENABLE(0),.LOAD_OFFSETS(1),.EXTERNAL_SAMPLE_TICK(1)) dut(.clk(clk),.rst_n(rst_n),.start(run),.reload(reload),.sample_tick(tick),.fmap(fmap),.inst(inst),.reverb_preset(router_pkg::REVERB_NONE),.slot_note_map(note_map),.record_snapshot_notes(snapshot),.record_snapshot_valid(valid),.qspi_dq_i(dq),.qspi_cs_n(cs),.qspi_sck(sck),.qspi_dq_oe(oe),.qspi_dq_o(dout),.midi_select(1'b0),.midi_valid(1'b0),.midi_gate(16'd0),.midi_retrigger(16'd0),.midi_hard_clear(16'd0),.midi_velocity(112'd0),.maintenance_clear(1'b0),.map_reload(1'b0),.load_offsets(512'd0),.ns_rd_en(1'b0),.ns_rd_addr(10'd0),.ns_rd_sel(1'b0));
endmodule

module record_capture_probe(input wire clk,rst_n,tick,start,stop,snapshot,input wire [15:0] gate,input wire [127:0] levels,input wire [111:0] notes,output wire valid,input wire ready,output wire [191:0] payload);
performance_capture dut(.clk(clk),.rst_n(rst_n),.frame_tick(tick),.abort_capture(1'b0),.start_req(start),.stop_req(stop),.request_id(32'd7),.eligible(1'b1),.channel(4'd1),.snapshot_valid(snapshot),.snapshot_gate(gate),.snapshot_level(levels),.snapshot_notes(notes),.out_valid(valid),.out_ready(ready),.out_payload(payload));
endmodule
