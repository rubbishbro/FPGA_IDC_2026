"""Parent independent original-SOS/ROM/float review; no implementation model.

Run with torch312 Python. Temporary regenerated files stay in /tmp/opencode;
the original FFT parameters and checked-in ROMs are never overwritten.
"""
from __future__ import annotations
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from scipy.signal import sosfilt, sosfreqz

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'python/modal_sim'))
from params import Patch

NAMES = ('guitar', 'piano', 'banjo', 'mandolin')


def original_coefficients(name):
    sos = np.asarray(Patch(name).sos)
    assert sos.shape == (4, 6) and np.all(sos[:, 3] == 1)
    q = [[math.floor(float(row[k]) * (1 << 30) + 0.5)
          for k in (0, 1, 2, 4, 5)] for row in sos]
    assert all(-(1 << 31) <= v < (1 << 31) for row in q for v in row)
    return sos, q


def process(q, seq):
    history = [[0] * 4 for _ in range(4)]
    result = []
    for item in seq:
        value = int(item) << 4
        for j, c in enumerate(q):
            x1, x2, y1, y2 = history[j]
            y = (c[0]*value + c[1]*x1 + c[2]*x2 - c[3]*y1 - c[4]*y2 + (1 << 29)) >> 30
            assert -(1 << 67) <= y < (1 << 67), 'normal amplitude should never saturate'
            history[j] = [value, x1, y, y1]
            value = y
        y = (value + 8) >> 4
        assert -(1 << 63) <= y < (1 << 63)
        result.append(y / (1 << 30))
    return np.asarray(result)


class BodyNumericReview(unittest.TestCase):
    def test_rom_from_original_sos_and_manifest_hash(self):
        data = (ROOT / 'rtl/rom/body_coeff.mem').read_bytes()
        tokens = data.decode().splitlines()
        self.assertEqual(len(tokens), 80)
        self.assertTrue(all(re.fullmatch('[0-9a-fA-F]{8}', t) for t in tokens))
        expected = [f'{v & 0xffffffff:08X}' for name in NAMES
                    for row in original_coefficients(name)[1] for v in row]
        self.assertEqual([t.upper() for t in tokens], expected)
        manifest = json.loads((ROOT / 'rtl/rom/body_manifest.json').read_text())
        self.assertEqual(manifest['instrument_order'], list(NAMES))
        self.assertEqual(manifest['words_per_instrument'], 20)
        self.assertEqual(manifest['coeff_sha256'], hashlib.sha256(data).hexdigest())
        for key, value in dict(external_bits=64, external_frac=30, internal_bits=68,
                               internal_frac=34, guard_bits=4, acc_bits=104,
                               product_bits=100, fs=48000).items():
            self.assertEqual(manifest[key], value, key)
        for i, name in enumerate(NAMES):
            info = manifest['per_instrument'][name]
            self.assertEqual(info['base'], i * 20)
            original_sos, _ = original_coefficients(name)
            np.testing.assert_array_equal(np.asarray(info['sos_float']), original_sos)
            source = manifest['source_files'][name]
            self.assertEqual(source['path'], name + '_body.npz')
            source_bytes = (ROOT / 'FFT_results/params' / source['path']).read_bytes()
            self.assertEqual(source['sha256'], hashlib.sha256(source_bytes).hexdigest())
            for j, c in enumerate(original_coefficients(name)[1]):
                section = info['sections'][j]
                self.assertEqual([section[t + '_q'] for t in ('b0', 'b1', 'b2', 'a1', 'a2')], c)

    def test_reproducible_generator_from_other_cwd(self):
        with tempfile.TemporaryDirectory(prefix='body-rom-review-', dir='/tmp/opencode') as tmp:
            p = subprocess.run([sys.executable, str(ROOT / 'python/modal_sim/gen_body_rom.py'),
                                '--rom-dir', tmp], cwd='/tmp/opencode', text=True,
                               capture_output=True, timeout=120)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            for name in ('body_coeff.mem', 'body_manifest.json'):
                self.assertEqual((Path(tmp) / name).read_bytes(), (ROOT / 'rtl/rom' / name).read_bytes())

    def test_float_error_frequency_and_long_silence(self):
        rng = np.random.default_rng(312)
        for name in NAMES:
            sos, q = original_coefficients(name)
            x = np.r_[1., rng.uniform(-.5, .5, 4096), np.zeros(65536)]
            integer_input = np.floor(x * (1 << 30) + .5).astype(np.int64)
            actual = process(q, integer_input)
            reference = sosfilt(sos, integer_input.astype(np.float64) / (1 << 30))
            error = actual - reference
            peak = float(np.max(np.abs(error)))
            rms = float(np.sqrt(np.mean(error * error)))
            tail = float(np.max(np.abs(actual[-4096:])))
            quantised_sos = np.floor(sos * (1 << 30) + .5) / (1 << 30)
            frequencies = np.linspace(20, 20000, 4000)
            _, original_h = sosfreqz(sos, worN=frequencies, fs=48000)
            _, quantised_h = sosfreqz(quantised_sos, worN=frequencies, fs=48000)
            frequency_error = float(np.max(np.abs(20 * np.log10(np.abs(quantised_h / original_h)))))
            radius = max(float(np.max(np.abs(np.roots(row[3:])))) for row in quantised_sos)
            print(f'{name}: original SOS vs independent 68Q34 DFI; '
                  f'peak={peak:.9g} RMS={rms:.9g} tail={tail:.9g} '
                  f'FRF_error_dB={frequency_error:.9g} max_pole={radius:.9g}', flush=True)
            self.assertLessEqual(peak, 1e-5)
            self.assertLessEqual(tail, 2e-7)
            self.assertLessEqual(frequency_error, .01)
            self.assertLess(radius, 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
