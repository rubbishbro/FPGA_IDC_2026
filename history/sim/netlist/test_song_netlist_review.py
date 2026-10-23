"""Independent original-parameter song gate-level check with vendor primitives.

Direct core/audio clocks isolate synthesis functionality from PLL model startup.
Checks 64-bit modal sums and externally decoded standard-I2S mono against the
parent golden model, including a reset/restart. No force or mocked datapath.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve()
while not ((ROOT / "rtl").is_dir() and (ROOT / "sim").is_dir()):
    ROOT = ROOT.parent
import sys as _sim_sys  # noqa: E402
_sim_sys.path.insert(0, str(ROOT / "sim" / "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)


def reset_connections(text, actual):
    """Only accept reset encodings independently inspected in real netlists.

    The reviewed split encoding has NAND(n11_6,n11_7)=n11_5 in clock_reset;
    driving (rst_n,1) is therefore the same test reset as old (~rst_n).
    This models PLL-ready/reset for functional testing, not the physical PLL.
    """
    common = {'clk_core', 'reset_d', 'clk_audio', 'crst_sync',
              'playback_ready', 'amp_din_d', 'bcnt', 't'}
    if actual == common | {'n11_5'}:
        return '.n11_5(~rst_n)', 'reviewed active-high n11_5 reset input'
    if actual == common | {'n11_6', 'n11_7'}:
        clock = re.search(r'module clock_reset\s*\(.*?endmodule', text, re.S)
        assert clock, 'Cannot verify split reset without original clock_reset'
        nand = re.search(r'LUT2\s+(\w+)\s*\(\s*\.F\(n11_5\),\s*'
                         r'\.I0\(n11_6\),\s*\.I1\(n11_7\)\s*\);', clock.group())
        assert nand, 'Split reset is not the reviewed n11_5 NAND gate'
        assert re.search(r'defparam\s+' + re.escape(nand.group(1)) +
                         r"\.INIT\s*=\s*4'h7\s*;", clock.group()), 'Wrong split reset truth table'
        return ".n11_6(rst_n), .n11_7(1'b1)", 'reviewed NAND(n11_6,n11_7) reset encoding'
    raise AssertionError(f'Inspect renamed synthesis ports before connecting: {actual}')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--netlist', type=Path, required=True)
    ap.add_argument('--build-dir', type=Path, required=True)
    ap.add_argument('--samples', type=int, default=16)
    ap.add_argument('--vendor-library', type=Path,
                    default=Path.home() / 'gowin/IDE/simlib/gw5a/prim_sim.v')
    args = ap.parse_args()
    assert args.samples >= 8
    base = args.build_dir.resolve()
    assert not (base / 'result.json').exists(), 'Refuse to overwrite completed evidence'
    base.mkdir(parents=True, exist_ok=True)
    os.environ.update(AUDIO_REVIEW_VOICES='32', AUDIO_REVIEW_GAP='12000',
                      AUDIO_REVIEW_BODY='1', AUDIO_REVIEW_ATT='3',
                      AUDIO_REVIEW_AUDIO_PS='80000')
    import test_audio_chain_review as chain
    golden = chain.reference(args.samples + 4)
    (base / 'sum.mem').write_text(''.join(f'{row[0] & ((1 << 64)-1):016x}\n' for row in golden))
    (base / 'pcm.mem').write_text(''.join(f'{row[1]:04x}\n' for row in golden))
    text = args.netlist.read_text()
    match = re.search(r'module audio_demo_core\s*\((.*?)\)\s*;', text, re.S)
    assert match, 'Expected synthesized production integration module absent'
    actual = {p.strip() for p in match.group(1).split(',')}
    reset_ports, reset_description = reset_connections(text, actual)
    harness = base / 'tb_song_gate.sv'
    harness.write_text('''`timescale 1ns/1ps
module tb_song_gate;
    reg core=0, audio=0, rst_n=0;
    always #5 core=~core;
    always #40 audio=~audio;
    GSR GSR (.GSRI(1'b1));
    wire pb,din,bclk,ws;
    audio_demo_core dut(.clk_core(core), .reset_d(1'b0), __RESET_PORTS__,
        .clk_audio(audio), .crst_sync(1'b1), .playback_ready(pb),
        .amp_din_d(din), .bcnt(ws), .t(bclk));
    localparam integer COUNT=__COUNT__;
    reg [63:0] sums[0:COUNT+3];
    reg [15:0] pcm[0:COUNT+3];
    integer sum_count=0, frame_count=0, phase=0, position=-1;
    integer total_frames=0, total_sums=0, nonzero_frames=0;
    reg previous_ws=0;
    reg [15:0] left=0,right=0,want=0;
    initial begin
        $readmemh("__SUM__",sums);
        $readmemh("__PCM__",pcm);
    end
    always @(negedge core) if(rst_n && dut.sp_out_valid === 1'b1) begin
        if (sum_count <= COUNT+3 && dut.sp_out_sum !== sums[sum_count])
            $fatal(1,"Modal sum mismatch phase=%0d sample=%0d actual=%h expected=%h",
                phase,sum_count,dut.sp_out_sum,sums[sum_count]);
        sum_count=sum_count+1;
        total_sums=total_sums+1;
    end
    // Sample receiver rising edge; WS delay bit at slot position0, MSB at1.
    always @(posedge bclk) begin
        #1;
        if(rst_n) begin
            if(!ws && previous_ws) begin
                if(position != -1 && position != 64) $fatal(1,"Wrong I2S frame length");
                position=0; left=0; right=0;
            end
            if(position >= 0 && position < 64) begin
                if(ws !== (position >= 32)) $fatal(1,"Wrong WS slot polarity");
                if(position%32 >= 1 && position%32 <= 16) begin
                    if(ws) right={right[14:0],din};
                    else left={left[14:0],din};
                end else if(din !== 0) $fatal(1,"Nonzero delay/padding bit");
                position=position+1;
                if(position==64 && frame_count <= COUNT) begin
                    // Exactly one startup empty-FIFO frame, then ordered samples.
                    want=(frame_count==0)?16'b0:pcm[frame_count-1];
                    if(left !== want || right !== want)
                        $fatal(1,"I2S mismatch phase=%0d frame=%0d L=%h R=%h want=%h",
                            phase,frame_count,left,right,want);
                    if(want != 0) nonzero_frames=nonzero_frames+1;
                    frame_count=frame_count+1; total_frames=total_frames+1;
                end
            end
            previous_ws=ws;
        end
    end
    initial begin
        #1001;
        for(phase=0;phase<2;phase=phase+1) begin
            sum_count=0; frame_count=0; position=-1; previous_ws=0;
            rst_n=1;
            wait(frame_count==COUNT+1);
            #2;
            if(pb !== 1 || sum_count < COUNT) $fatal(1,"Producer not ready after samples");
            $display("PHASE_PASS phase=%0d decoded_frames=%0d modal_sums=%0d",phase,frame_count,sum_count);
            rst_n=0;
            #2;
            if(pb !== 0) $fatal(1,"Reset did not clear playback_ready");
            #1000;
        end
        if(nonzero_frames==0) $fatal(1,"No nonzero audio frames observed");
        $display("SONG_GATE_FUNCTION_PASS total_frames=%0d total_sums=%0d nonzero_frames=%0d",total_frames,total_sums,nonzero_frames);
        $finish;
    end
    initial begin
        #__TIMEOUT__;
        $fatal(1,"Timeout: pb=%b phase=%0d modal_sums=%0d decoded_frames=%0d",pb,phase,sum_count,frame_count);
    end
endmodule
'''.replace('__COUNT__', str(args.samples))
        .replace('__RESET_PORTS__', reset_ports)
        .replace('__SUM__', str(base / 'sum.mem'))
        .replace('__PCM__', str(base / 'pcm.mem'))
        .replace('__TIMEOUT__', str((args.samples + 6) * 21000 * 2)))
    env = dict(os.environ)
    env['PATH'] = str(Path.home() / 'micromamba/envs/torch312/bin') + ':' + env['PATH']
    files = [harness, args.netlist.resolve(), args.vendor_library.resolve()]
    command = ['iverilog', '-g2012', '-s', 'tb_song_gate', '-o', str(base / 'gate.vvp'),
               *map(str, files)]
    compiled = subprocess.run(command, env=env, text=True, capture_output=True)
    (base / 'compile.log').write_text(compiled.stdout + compiled.stderr)
    compiled.check_returncode()
    result = subprocess.run(['vvp', str(base / 'gate.vvp')], env=env,
                            text=True, capture_output=True)
    (base / 'run.log').write_text(result.stdout + result.stderr)
    evidence_files = files + [base / 'sum.mem', base / 'pcm.mem', Path(__file__).resolve(),
        ROOT / 'sim/integration/test_audio_chain_review.py',
        ROOT / 'FFT_results/params/guitar_coeff.mem',
        ROOT / 'FFT_results/params/guitar_coeffindex.json']
    report = {'command': command, 'returncode': result.returncode, 'samples_per_reset': args.samples,
        'reset_binding': reset_description,
        'files': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in evidence_files}}
    (base / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(result.stdout + result.stderr)
    result.check_returncode()
    assert 'SONG_GATE_FUNCTION_PASS' in result.stdout


if __name__ == '__main__':
    main()
