`timescale 1ns/1ps
// TEMP_AUDIO_AUDITION_20261101: independent wide reference for the two audition edits.
module tb_temporary_audio_gain;
 logic clk=0,rst_n=0,sv=0,ov,busy;
 always #5 clk=~clk;
 logic signed[63:0] source=0,vy;
 logic signed[83:0] left,right;
 logic[12:0] gl,gr;
 logic[9:0] pos,dl,dr;
 voice_router #(.SLOTS(4),.N_MODES(64)) voice(.clk(clk),.rst_n(rst_n),.start(1'b0),.sample_tick(1'b0),
  .fmap('0),.inst(router_pkg::INST_PIANO),.reverb_preset(router_pkg::REVERB_NONE),.reload(1'b0),
  .midi_select(1'b0),.midi_valid(1'b0),.midi_gate('0),.midi_retrigger('0),.midi_hard_clear('0),.midi_velocity('0),
  .maintenance_clear(1'b0),.map_reload(1'b0),.load_offsets('0),.qspi_dq_i('0),
  .ns_rd_en(1'b0),.ns_rd_addr('0),.ns_rd_sel(1'b0),.y_data(vy));
 stereo_spatializer spatial(.clk(clk),.rst_n(rst_n),.sample_valid(sv),.clear(1'b0),.in_data(vy),
  .pan_position(6'd16),.itd_enable(1'b1),.busy(busy),.out_valid(ov),.out_left(left),.out_right(right),
  .gain_left_q12(gl),.gain_right_q12(gr),.position_q4(pos),.delay_left_q6(dl),.delay_right_q6(dr));
 i2s_audio_output #(.PCM_HEADROOM_BITS(0)) audio(.clk(1'b0),.audio_clk(1'b0),.rst_n(1'b0),
  .active(1'b0),.in_valid(1'b0),.in_data(64'sd0));
 logic signed[127:0] doubled,expected,expected_spatial,scaled;
 logic signed[15:0] expected_pcm;
 integer count=0,seed=20261101;
 task automatic check(input logic signed[63:0] x);
  source=x;#1;
  doubled=128'($signed(x))*128'sd2;
  expected=doubled>128'sh7fffffffffffffff ? 128'sh7fffffffffffffff:
           doubled< -128'sh8000000000000000 ? -128'sh8000000000000000 : doubled;
  if(vy!==64'(expected))$fatal(1,"FAIL output x2 x=%0d got=%0d expected=%0d",x,vy,expected);
  @(negedge clk);sv=1;@(negedge clk);sv=0;
  wait(ov);@(negedge clk);
  expected_spatial=expected<<<18;
  scaled=(expected+128'sd256)>>>9;
  expected_pcm=scaled>32767 ? 16'sh7fff:scaled< -32768 ? 16'sh8000:16'(scaled);
  if(left!==84'(expected_spatial) || right!==84'(expected_spatial) || gl!=4096 || gr!=4096 || dl!=0 || dr!=0)
   $fatal(1,"FAIL center unity gain/delay x=%0d",x);
  if(audio.spatial_pcm16(left)!==expected_pcm || audio.spatial_pcm16(right)!==expected_pcm)
   $fatal(1,"FAIL final PCM saturation");
  count++;@(negedge clk);
 endtask
 initial begin
  force voice.rev_y=source;force voice.table_valid=1'b1;
  repeat(4)@(negedge clk);rst_n=1;
  check(0);check(1);check(-1);check(1<<24);check(-(1<<24));
  check(64'sh3fffffffffffffff);check(64'sh4000000000000000);
  check(-64'sh4000000000000000);check(-64'sh4000000000000001);
  check(64'sh7fffffffffffffff);check(64'sh8000000000000000);
  check(64'sd9344337);check(-64'sd9344337);
  repeat(1024)check({$urandom(seed),$urandom(seed)});
  force voice.table_valid=1'b0;#1;if(vy!==0)$fatal(1,"FAIL invalid table output not muted");
  $display("PASS temporary gain cases=%0d output_x2_signed64_sat center_LR_unity final_PCM_sat",count);$finish;
 end
 initial begin #1000000;$fatal(1,"FAIL temp gain timeout");end
endmodule
