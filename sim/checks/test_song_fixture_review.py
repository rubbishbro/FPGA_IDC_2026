"""Unit checks for gate-test reset binding; not FPGA functionality tests."""
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

from test_song_netlist_review import reset_connections


COMMON = {'clk_core', 'reset_d', 'clk_audio', 'crst_sync',
          'playback_ready', 'amp_din_d', 'bcnt', 't'}
SPLIT = '''module clock_reset(clk_d,n11_6,n11_7,clk_core,clk_audio,crst_sync);
LUT2 n11_s1 (.F(n11_5), .I0(n11_6), .I1(n11_7));
defparam n11_s1.INIT=4'h7;
endmodule'''


class ResetFixtureReview(unittest.TestCase):
    def test_single_input(self):
        ports, _ = reset_connections('', COMMON | {'n11_5'})
        self.assertEqual(ports, '.n11_5(~rst_n)')

    def test_reviewed_split_truth_table(self):
        ports, _ = reset_connections(SPLIT, COMMON | {'n11_6', 'n11_7'})
        self.assertEqual(ports, ".n11_6(rst_n), .n11_7(1'b1)")
        for rst_n in (0, 1):
            actual = (0x7 >> (rst_n | (1 << 1))) & 1
            self.assertEqual(actual, 1-rst_n)

    def test_unknown_or_wrong_encoding_rejected(self):
        for text, ports in [('', COMMON | {'n11_6', 'n11_7'}),
                            (SPLIT.replace("4'h7", "4'h8"), COMMON | {'n11_6', 'n11_7'}),
                            (SPLIT.replace('.I0(n11_6)', '.I0(other)'), COMMON | {'n11_6', 'n11_7'}),
                            ('', COMMON | {'different_reset'}),
                            ('', COMMON | {'n11_5', 'extra_unreviewed_input'})]:
            with self.subTest(text=text, ports=ports), self.assertRaises(AssertionError):
                reset_connections(text, ports)


if __name__ == '__main__':
    unittest.main()
