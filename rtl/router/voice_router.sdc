# voice_router 时序约束：100 MHz 主时钟
# （之前放在 rtl/simsynth/fmax.sdc，那边删掉后挪过来）
create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports {clk}]
