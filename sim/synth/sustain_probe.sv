// Synthesis-only probe. This is not a board top or a timing acceptance test.
module sustain_probe(
 input logic clk,rst_n,start,sample_tick,
 input logic [3:0] instrument,
 input logic [7:0] pressure,
 input logic [15:0] gate,retrigger,hard_clear,
 input logic [111:0] slot_notes,
 input logic [3:0] flash_dq,
 output logic cs_n,sck,dq_oe,
 output logic [3:0] dq_o,
 output logic y_valid,load_error,
 output logic [15:0] idle,
 output logic signed [63:0] y
);
 pad_driver_pkg::mat4x4 fmap;
 assign fmap.raw={16{pressure}};
 voice_router #(.MIDI_ENABLE(1),.EXTERNAL_SAMPLE_TICK(1),.DEBUG_PORT(0)) dut(
  .clk(clk),.rst_n(rst_n),.start(start),.sample_tick(sample_tick),.slot_note_map(slot_notes),
  .fmap(fmap),.inst(router_pkg::instrument_e'(instrument)),.reverb_preset(router_pkg::REVERB_NONE),.reload(1'b0),
  .done(),.ready(),.load_err(load_error),.table_valid(),.load_complete(),.voice_idle(idle),.y_valid(y_valid),.y_data(y),
  .qspi_cs_n(cs_n),.qspi_sck(sck),.qspi_dq_o(dq_o),.qspi_dq_oe(dq_oe),.qspi_dq_i(flash_dq),
  .midi_select(1'b1),.midi_valid(1'b1),.midi_ready(),.midi_gate(gate),.midi_retrigger(retrigger),.midi_hard_clear(hard_clear),
  .midi_velocity({16{pressure[7:1]}}),.maintenance_clear(1'b0),.maintenance_done(),.midi_inflight(),.map_reload(1'b0),.load_offsets('0),
  .ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0),.ns_rd_data(),.ns_rd_valid());
endmodule
