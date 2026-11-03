"""Arithmetic experiment checks, including independent SV expression evaluation."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import numpy as np
import unittest
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'python/modal_sim'))
import flute_air_envelope as F


def test_zero_envelope_and_signed_product_slice():
    for modal in [-(1<<63), -123456789, -1, 0, 1, 123456789, (1<<63)-1]:
        for air in [-100000, 0, 100000]:
            assert F.env_mul(modal, air, 0) == 0
            for e in [1, 0x1fffffff, 0x7fffffff]:
                operand = ((modal+air+(1<<63)) % (1<<64))-(1<<63)
                bits = ((operand*e) % (1<<96)) >> 31
                expected = ((bits+(1<<63)) % (1<<64))-(1<<63)
                assert F.env_mul(modal, air, e) == expected


def test_noise_deterministic_independent_and_bounded():
    sequences = []
    for seed in F.SEEDS:
        def run():
            state, dc = seed, 0
            result = []
            for _ in range(4096):
                state, dc, hp = F.noise_step(state, dc)
                assert state and -(1<<24) < hp < (1<<24)
                result.append(hp)
            return result
        a = run()
        assert a == run()
        sequences.append(a)
    assert all(sequences[0] != a for a in sequences[1:])


def test_systemverilog_noise_and_shared_multiplier(tmp_path):
    compiler = os.environ.get('IVERILOG') or shutil.which('iverilog')
    runner = os.environ.get('VVP') or shutil.which('vvp')
    if not compiler or not runner:
        raise unittest.SkipTest('Icarus not available')
    rng = np.random.default_rng(20261103)
    vectors, expected = [], []
    lfsr, dc = F.SEEDS[0], 0
    for i in range(8192):
        lfsr, dc, hp = F.noise_step(lfsr, dc)
        modal = int(rng.integers(-(1<<40), 1<<40))
        e = [0, 1, 0x1fffffff, 0x7fffffff][i % 4]
        shift = 2+i % 3
        vectors.append(f'{modal & ((1<<64)-1):016x} {e:08x} {shift:x}\n')
        expected.append((lfsr, dc, hp, F.env_mul(modal, hp >> shift, e)))
    (tmp_path/'vectors.txt').write_text(''.join(vectors))
    source = tmp_path/'check.sv'
    source.write_text('''module tb;
reg [31:0] lfsr=32'h13579bdf;
reg signed [31:0] dc=0, white, hp;
reg signed [63:0] modal, operand, air, result;
reg signed [31:0] e;
reg signed [95:0] product;
integer fd, code, shift;
initial begin
  fd=$fopen("vectors.txt","r");
  while (!$feof(fd)) begin
    code=$fscanf(fd,"%h %h %h\\n",modal,e,shift);
    if(code==3)begin
      lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
      white={{8{lfsr[31]}},lfsr[31:8]};
      dc=dc+(($signed(white)-$signed(dc))>>>4);
      hp=white-dc;
      air=$signed(hp)>>>shift;
      operand=modal+air;
      product=operand*e;
      result=product[94:31];
      $display("%h %h %h %h",lfsr,dc,hp,result);
    end
  end
  $finish;
end
endmodule
''')
    cmd = [compiler, '-g2012']
    if os.environ.get('IVERILOG_IVL'): cmd += ['-B', os.environ['IVERILOG_IVL']]
    cmd += ['-o', str(tmp_path/'check.vvp'), str(source)]
    subprocess.run(cmd, check=True, capture_output=True)
    lines = subprocess.check_output([runner, str(tmp_path/'check.vvp')], cwd=tmp_path, text=True).splitlines()
    assert len(lines) == len(expected)
    masks = [(1<<32)-1]*3+[(1<<64)-1]
    for line, values in zip(lines, expected):
        assert [int(v,16) for v in line.split()] == [v&m for v,m in zip(values,masks)]


if __name__ == '__main__':
    test_zero_envelope_and_signed_product_slice()
    test_noise_deterministic_independent_and_bounded()
    with tempfile.TemporaryDirectory() as folder:
        test_systemverilog_noise_and_shared_multiplier(Path(folder))
    print('PASS: signed boundaries, silence, deterministic seeds and 8192 SV arithmetic vectors')
