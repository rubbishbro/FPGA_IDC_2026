"""Only synthetic fixtures; no hardware acceptance assertion here."""
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
from review_i2s_pin_delays import PINS, certified_envelope, check_bounds, parse_report


def fixture(delays, launch='clk_audio:[R]', offset=0.0):
    return ''.join(f'''Path Summary:
Data Arrival Time : {value + offset:.3f}
From : u_top/u_audio/u_core/u_transport/g_i2s_amp.u_tx/test_reg
To : {pin}_obuf
Launch Clk : {launch}
Latch Clk : clk_audio:[R]
Data Arrival Path:
 {offset:.3f} 0.000 active clock edge time
 {value + offset:.3f} {value:.3f} tINS pad
Data Required Path:
 80.000 80.000 active clock edge time
Path Statistics:
'''
                   for pin, value in delays.items())


class I2SDelayReview(unittest.TestCase):
    def certified_fixture(self):
        raw = '<Numbers of Setup Violated Endpoints>:0\n<Numbers of Hold Violated Endpoints>:0\n'
        raw += ' 3 clk_audio Generated 80.000 12.500MHz\n'
        for p in PINS:
            raw += f'TC_OUTPUT_DELAY Actived set_output_delay -clock clk_audio 40.000 -max [get_ports {{{p}}}]\n'
            raw += f'TC_OUTPUT_DELAY Actived set_output_delay -clock clk_audio 0.000 -min [get_ports {{{p}}}]\n'
        return raw

    def test_conditional_envelope(self):
        high = parse_report(fixture(dict.fromkeys(PINS, 40.0)))
        low = parse_report(fixture(dict.fromkeys(PINS, 0.0)))
        result = check_bounds(high, low)
        for p in ('amp_din', 'amp_lrc'):
            self.assertEqual(result['data'][p]['setup_lower_bound_ns'], 110.0)
            self.assertEqual(result['data'][p]['hold_lower_bound_ns'], 110.0)

    def test_launch_offset_not_path_delay(self):
        delays = parse_report(fixture(dict.fromkeys(PINS, 13.0), offset=160.0))
        self.assertEqual(delays['amp_bclk'], [13.0])

    def test_missing_pin_rejected(self):
        with self.assertRaisesRegex(ValueError, 'amp_lrc'):
            parse_report(fixture({'amp_bclk': 10, 'amp_din': 10}))

    def test_wrong_domain_rejected(self):
        with self.assertRaisesRegex(ValueError, 'expected rising clk_audio'):
            parse_report(fixture(dict.fromkeys(PINS, 10), launch='clk_core:[R]'))

    def test_exceeded_envelope_rejected(self):
        high = dict.fromkeys(PINS, [41.0])
        low = dict.fromkeys(PINS, [1.0])
        with self.assertRaisesRegex(ValueError, 'outside'):
            check_bounds(high, low)

    def test_insufficient_real_skew_margin_rejected(self):
        with self.assertRaisesRegex(ValueError, 'insufficient'):
            check_bounds(dict.fromkeys(PINS, [40.0]), dict.fromkeys(PINS, [0.0]), margin_ns=111.0)

    def test_inverted_corner_interval_rejected(self):
        with self.assertRaisesRegex(ValueError, 'outside'):
            check_bounds(dict.fromkeys(PINS, [3.0]), dict.fromkeys(PINS, [8.0]))

    def test_hold_blocks_cannot_be_setup_evidence(self):
        raw = '<Hold Delay Model>:Fast 0.927V 85C ES\nHold Analysis Report\n'
        raw += fixture(dict.fromkeys(PINS, 8.0))
        with self.assertRaisesRegex(ValueError, 'Setup/Slow'):
            parse_report(raw, 'Setup')

    def test_full_report_analyses_not_mixed(self):
        raw = '<Setup Delay Model>:Slow 0.873V 0C ES\n<Hold Delay Model>:Fast 0.927V 85C ES\n'
        raw += '3.3.1 Setup Analysis Report\n' + fixture(dict.fromkeys(PINS, 20.0))
        raw += '3.3.2 Hold Analysis Report\n' + fixture(dict.fromkeys(PINS, 8.0))
        self.assertEqual(parse_report(raw, 'Setup')['amp_din'], [20.0])
        self.assertEqual(parse_report(raw, 'Hold')['amp_din'], [8.0])

    def test_certified_bound_distinct_from_measured(self):
        result = certified_envelope(self.certified_fixture())
        self.assertIn('NOT measured', result['bound_vs_measured'])
        self.assertEqual(result['data']['amp_din']['setup_lower_bound_ns'], 110.0)

    def test_failed_sta_cannot_certify_bound(self):
        raw = self.certified_fixture().replace('Setup Violated Endpoints>:0',
                                               'Setup Violated Endpoints>:3991')
        with self.assertRaisesRegex(ValueError, 'zero violations'):
            certified_envelope(raw)

    def test_ignored_output_bound_cannot_certify(self):
        raw = self.certified_fixture().replace('TC_OUTPUT_DELAY Actived', 'TC_OUTPUT_DELAY Ignored')
        with self.assertRaisesRegex(ValueError, 'active-constraint'):
            certified_envelope(raw)

    def test_false_path_cut_cannot_certify(self):
        raw = self.certified_fixture() + 'TC_FALSE_PATH Actived set_false_path -to [get_ports {amp_din}]\n'
        with self.assertRaisesRegex(ValueError, 'false path'):
            certified_envelope(raw)

    def test_internal_serializer_cut_cannot_certify(self):
        raw = self.certified_fixture() + ('TC_FALSE_PATH Actived set_false_path -hold '
            '-to [get_pins {u_top/u_audio/u_core/u_transport/g_i2s_amp.u_tx/ws_r_s0/D}]\n')
        with self.assertRaisesRegex(ValueError, 'first-stage'):
            certified_envelope(raw)

    def test_second_stage_cdc_cut_cannot_certify(self):
        raw = self.certified_fixture() + ('TC_FALSE_PATH Actived set_false_path -hold '
            '-to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/wgray_s2_0_s0/D}]\n')
        with self.assertRaisesRegex(ValueError, 'first-stage'):
            certified_envelope(raw)

    def test_stage1_setup_cut_not_automatically_accepted(self):
        raw = self.certified_fixture() + ('TC_FALSE_PATH Actived set_false_path '
            '-to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/wgray_s1_0_s0/D}]\n')
        with self.assertRaisesRegex(ValueError, 'hold-only'):
            certified_envelope(raw)

    def test_scoped_stage1_hold_only_still_conditional(self):
        raw = self.certified_fixture() + ('TC_FALSE_PATH Actived set_false_path -hold '
            '-to [get_pins {u_top/u_audio/u_core/u_transport/u_tx_fifo/wgray_s1_0_s0/D}]\n')
        result = certified_envelope(raw)
        self.assertIn('NOT measured', result['bound_vs_measured'])

    def test_reset_sync_requires_explicit_review_acknowledgement(self):
        raw = self.certified_fixture() + ('TC_FALSE_PATH Actived set_false_path '
            '-to [get_pins {u_top/u_clock_reset/crst_sync_0_s0/CLEAR}]\n')
        with self.assertRaisesRegex(ValueError, 'hold-only'):
            certified_envelope(raw)
        self.assertIn('NOT measured', certified_envelope(raw,
                      reviewed_reset_sync_exceptions=True)['bound_vs_measured'])

    def test_ordinary_reset_clear_cannot_be_cut(self):
        raw = self.certified_fixture() + ('TC_FALSE_PATH Actived set_false_path '
            '-to [get_pins {u_top/u_audio/u_core/g_body.u_body/y1_0_s0/CLEAR}]\n')
        with self.assertRaisesRegex(ValueError, 'hold-only'):
            certified_envelope(raw, reviewed_reset_sync_exceptions=True)

    def test_negative_removal_cannot_be_certified(self):
        raw = self.certified_fixture() + ('3.1.4 Removal Paths Table\n'
            ' 1 -0.709 pll_Q reset_sync_CLEAR\n3.2 Clock Details\n')
        with self.assertRaisesRegex(ValueError, 'removal table path'):
            certified_envelope(raw, reviewed_reset_sync_exceptions=True)

    def test_empty_exception_collection_rejected(self):
        raw = self.certified_fixture() + ('TC_FALSE_PATH Actived set_false_path -hold '
            '-to [get_pins { }]\n')
        with self.assertRaisesRegex(ValueError, 'first-stage'):
            certified_envelope(raw, reviewed_reset_sync_exceptions=True)

    def test_failed_clock_pulse_width_cannot_certify(self):
        raw = self.certified_fixture() + ('3.2 Minimum Pulse Width Table\n'
            ' 1 -0.769 0.131 0.900 High Pulse Width clk_core coeff_rom/CLK\n'
            '3.3 Timing Report By Analysis Type\n')
        with self.assertRaisesRegex(ValueError, 'minimum pulse width'):
            certified_envelope(raw, reviewed_reset_sync_exceptions=True)

    def test_positive_mpw_with_midpoint_latency_still_cannot_certify(self):
        raw = self.certified_fixture() + ('3.2 Minimum Pulse Width Table\n'
            ' 1 2.117 3.017 0.900 High Pulse Width clk_core coeff_rom/CLK\n'
            '3.3 Timing Report By Analysis Type\n'
            'TC_CLOCK_LATENCY Actived set_clock_latency -source 3.765 '
            '[get_clocks {clk_audio}]\n')
        with self.assertRaisesRegex(ValueError, 'timing override needs manual proof'):
            certified_envelope(raw, reviewed_reset_sync_exceptions=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
