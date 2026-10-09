"""Synthetic unit fixtures for the CDC review gate, not physical acceptance."""
import os as _sim_os
import sys as _sim_sys

_sim_p = _sim_os.path.dirname(_sim_os.path.abspath(__file__))
while not (_sim_os.path.isdir(_sim_os.path.join(_sim_p, "rtl"))
           and _sim_os.path.isdir(_sim_os.path.join(_sim_p, "sim"))):
    _sim_p = _sim_os.path.dirname(_sim_p)
_sim_sys.path.insert(0, _sim_os.path.join(_sim_p, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)

import unittest

from review_song_cdc import BOUNDS, PREFIX, TARGETS, review


def fixture():
    def ff(name, q, d, clk):
        return f'DFFCE {name} (.Q({q}), .D({d}), .CLK({clk}), .CE(VCC));\n'
    fifo = 'module audio_async_fifo();\n'
    for kind, source, target in [('wgray', 'clk_core', 'clk_audio'),
                                  ('rgray', 'clk_audio', 'clk_core')]:
        for bit in range(5):
            src = kind if bit < 4 else kind.replace('gray', 'bin')
            fifo += ff(f'{src}_{bit}_s0', f'{src}[{bit}]', 'nxt', source)
            fifo += ff(f'{kind}_s1_{bit}_s0', f'{kind}_s1[{bit}]', f'{src}[{bit}]', target)
            fifo += ff(f'{kind}_s2_{bit}_s0', f'{kind}_s2[{bit}]', f'{kind}_s1[{bit}]', target)
    fifo += 'endmodule\nmodule audio_transport();\n'
    fifo += ff('tick_tgl_s1', 'tick_tgl', 'next', 'clk_audio')
    fifo += ff('tgl_s1_s0', 'tgl_s1', 'tick_tgl', 'clk_core')
    fifo += ff('tgl_s2_s0', 'tgl_s2', 'tgl_s1', 'clk_core') + 'endmodule\n'
    sdc = '\n'.join(sorted(BOUNDS) + [f'set_false_path -hold -to [get_pins {{{p}}}]'
                                     for p in sorted(TARGETS)])
    timing = '<Numbers of Setup Violated Endpoints>:0\n<Numbers of Hold Violated Endpoints>:0\n'
    timing += '\n'.join('TC_FAKE Actived ' + line for line in sdc.splitlines())
    timing += '\n3.7.1 Setup Analysis Report\n'
    for i, bound in enumerate(sorted(BOUNDS)):
        timing += f'Timing Path Constraint[{i}]: {bound}\nFrom : source_{i}\nTo : target_{i}\n'
    timing += '\n3.7.2 Hold Analysis Report\n'
    return fifo, sdc, timing


class CDCGateReview(unittest.TestCase):
    def test_reviewed_fixture(self):
        self.assertEqual(len(review(*fixture())['stage_one_hold_pins']), 11)

    def test_stage_two_or_unreviewed_clear_cut_rejected(self):
        net, sdc, timing = fixture()
        for pin in (PREFIX + 'u_tx_fifo/wgray_s2_0_s0/D', 'unreviewed/CLEAR'):
            with self.subTest(pin=pin), self.assertRaises(AssertionError):
                review(net, sdc + f'\nset_false_path -hold -to [get_pins {{{pin}}}]', timing)

    def test_setup_cut_rejected(self):
        net, sdc, timing = fixture()
        with self.assertRaises(AssertionError):
            review(net, sdc.replace('set_false_path -hold', 'set_false_path'), timing)

    def test_bound_removal_or_no_real_witness_rejected(self):
        net, sdc, timing = fixture()
        for cut in sorted(BOUNDS):
            with self.subTest(cut=cut), self.assertRaises(AssertionError):
                review(net, sdc.replace(cut, '# removed'), timing)
        with self.assertRaises(AssertionError):
            review(net, sdc, timing.replace('From : source_0', 'No path here'))

    def test_source_must_be_registered_correct_domain(self):
        net, sdc, timing = fixture()
        for bad in (net.replace('.D(wgray[0])', '.D(combinational_gray)'),
                    net.replace('.D(wbin[4])', '.D(combinational_msb)'),
                    net.replace('wgray_0_s0 (.Q(wgray[0]), .D(nxt), .CLK(clk_core)',
                                'wgray_0_s0 (.Q(wgray[0]), .D(nxt), .CLK(clk_audio)')):
            with self.subTest(net=bad), self.assertRaises(AssertionError):
                review(bad, sdc, timing)

    def test_false_counters_and_inactive_command_rejected(self):
        net, sdc, timing = fixture()
        for bad in (timing.replace('Hold Violated Endpoints>:0', 'Hold Violated Endpoints>:2'),
                    timing.replace('Setup Violated Endpoints>:0', 'Setup Violated Endpoints>:1'),
                    timing.replace('TC_FAKE Actived', 'TC_FAKE Ignored', 1)):
            with self.subTest(timing=bad), self.assertRaises(AssertionError):
                review(net, sdc, bad)


if __name__ == '__main__':
    unittest.main()
