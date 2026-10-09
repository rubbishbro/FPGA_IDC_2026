"""Parent gate unit tests. All purported tool reports here are synthetic."""
import os as _sim_os
import sys as _sim_sys

_sim_p = _sim_os.path.dirname(_sim_os.path.abspath(__file__))
while not (_sim_os.path.isdir(_sim_os.path.join(_sim_p, "rtl"))
           and _sim_os.path.isdir(_sim_os.path.join(_sim_p, "sim"))):
    _sim_p = _sim_os.path.dirname(_sim_p)
_sim_sys.path.insert(0, _sim_os.path.join(_sim_p, "sim", "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)

from pathlib import Path
import tempfile
import unittest

from review_gowin_reports import review


class ReportGateReview(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gowin-gate-review-', dir='/tmp/opencode')
        self.root = Path(self.temp.name)
        for name in ('synthesis.log', 'pnr.log', 'timing_report.tr'):
            (self.root / name).write_text('SYNTHETIC UNIT-TEST EVIDENCE\n')
        (self.root / 'timing_report.tr').write_text(
            '<Numbers of Setup Violated Endpoints>:0\n<Numbers of Hold Violated Endpoints>:0\n'
            ' 1 clk_50m Base 20.000 50.000MHz\n'
            ' 2 clk_core Generated 10.000 100.000MHz\n'
            ' 3 clk_audio Generated 80.000 12.500MHz\n')
        (self.root / 'synthesis_resources.xml').write_text(
            '<Module name="board_top">' + ''.join(
                f'<SubModule name="g_lane[{i}].u_lane" T_Bsram="4(4)" '
                'T_MULT27X36="1(1)"/>' for i in range(4)) + '</Module>')
        (self.root / 'pnr_report.txt').write_text(' DSP | 4/420 | 1%\n BSRAM | 49/630 | 8%\n')

    def tearDown(self):
        self.temp.cleanup()

    def test_structural_fixture_only(self):
        self.assertEqual(review(self.root), [])  # NOT timing or device sign-off

    def test_rom_warning_rejects_success(self):
        (self.root / 'synthesis.log').write_text('WARN(EX3988): Cannot open file modal_coeff.mem\nSUCCESS\n')
        self.assertTrue(any('EX3988' in x for x in review(self.root)))

    def test_console_pnr_error_without_report_rejected(self):
        (self.root / 'pnr.log').unlink()
        (self.root / 'pnr_report.txt').unlink()
        (self.root / 'flow.log').write_text("ERROR(PA2122): WRITE_MODE=2'b10\n")
        errors = review(self.root)
        self.assertTrue(any('Missing/empty' in x for x in errors))
        self.assertTrue(any('PA2122' in x for x in errors))

    def test_empty_lane_rejected(self):
        path = self.root / 'synthesis_resources.xml'
        path.write_text(path.read_text().replace('T_Bsram="4(4)"', 'T_Bsram="0(0)"'))
        self.assertTrue(any('lacks real RAM' in x for x in review(self.root)))

    def test_lane_missing_rejected(self):
        (self.root / 'synthesis_resources.xml').write_text('<Module name="top"/>')
        self.assertTrue(any('Missing implemented modal lane 3' in x for x in review(self.root)))

    def test_zero_used_resources_omitted(self):
        (self.root / 'pnr_report.txt').write_text(' Logic | 776/138240\n Register | 621/139140\n')
        errors = review(self.root)
        self.assertTrue(any('DSP count 0' in x for x in errors))
        self.assertTrue(any('BSRAM count 0' in x for x in errors))

    def test_malformed_xml_rejected(self):
        (self.root / 'synthesis_resources.xml').write_text('<Module')
        self.assertTrue(any('Invalid resource XML' in x for x in review(self.root)))

    def test_timing_failure_rejected_with_real_resources(self):
        path = self.root / 'timing_report.tr'
        path.write_text(path.read_text().replace('Setup Violated Endpoints>:0',
                                                'Setup Violated Endpoints>:3991'))
        self.assertTrue(any('setup failed: 3991' in x for x in review(self.root)))

    def test_hold_failure_rejected(self):
        path = self.root / 'timing_report.tr'
        path.write_text(path.read_text().replace('Hold Violated Endpoints>:0',
                                                'Hold Violated Endpoints>:10'))
        self.assertTrue(any('hold failed: 10' in x for x in review(self.root)))

    def test_wrong_audio_frequency_rejected(self):
        path = self.root / 'timing_report.tr'
        path.write_text(path.read_text().replace('80.000', '81.380'))
        self.assertTrue(any('Wrong STA clock period: clk_audio' in x for x in review(self.root)))

    def test_missing_clock_rejected(self):
        path = self.root / 'timing_report.tr'
        path.write_text('\n'.join(x for x in path.read_text().splitlines() if 'clk_core' not in x))
        self.assertTrue(any('Missing implemented STA clock: clk_core' in x for x in review(self.root)))

    def test_prebody_cannot_pass_body_delivery_gate(self):
        self.assertTrue(any('Missing implemented shared body' in x
                            for x in review(self.root, require_body=True)))

    def test_body_mapping_required(self):
        path = self.root / 'synthesis_resources.xml'
        path.write_text(path.read_text().replace('</Module>',
            '<SubModule name="g_body.u_body" T_Register="1700(1700)" '
            'T_MULT27X36="3(3)"/></Module>'))
        self.assertEqual(review(self.root, require_body=True), [])

    def test_empty_body_shell_rejected(self):
        path = self.root / 'synthesis_resources.xml'
        path.write_text(path.read_text().replace('</Module>',
            '<SubModule name="g_body.u_body"/></Module>'))
        self.assertTrue(any('Implausible shared-body mapping' in x
                            for x in review(self.root, require_body=True)))

    def test_removal_is_not_invisible_when_hold_table_positive(self):
        path = self.root / 'timing_report.tr'
        path.write_text(path.read_text() + '\n3.1.2 Hold Paths Table\n 1 0.247 normal_Q normal_D\n'
                        '3.1.4 Removal Paths Table\n 1 -0.709 pll_lock_Q reset_sync_CLEAR\n'
                        '3.2 Clock Details\n')
        self.assertTrue(any('removal table path 1' in x for x in review(self.root)))

    def test_negative_clock_pulse_width_rejected(self):
        path = self.root / 'timing_report.tr'
        path.write_text(path.read_text() + '\n3.2 Minimum Pulse Width Table\n'
                        ' 1 -0.769 0.131 0.900 High Pulse Width clk_core coeff_rom/CLK\n'
                        '3.3 Timing Report By Analysis Type\n')
        self.assertTrue(any('minimum pulse width path 1' in x for x in review(self.root)))

    def test_ignored_gray_bound_rejected(self):
        path = self.root / 'timing_report.tr'
        path.write_text(path.read_text() + '\nTC_MAX_DELAY Ignored set_max_delay '
                        '-from [get_clocks {clk_core}] 10.000 -to [get_clocks {clk_audio}]\n')
        self.assertTrue(any('Ignored/inactive timing constraint' in x for x in review(self.root)))

    def test_midpoint_latency_cannot_turn_clean_counters_into_physical_pass(self):
        path = self.root / 'timing_report.tr'
        path.write_text(path.read_text() + '\n3.2 Minimum Pulse Width Table\n'
                        ' 1 2.117 3.017 0.900 High Pulse Width clk_core coeff_rom/CLK\n'
                        '3.3 Timing Report By Analysis Type\n'
                        'TC_CLOCK_LATENCY Actived set_clock_latency -source 3.765 '
                        '[get_clocks {clk_core}]\n'
                        'TC_CLOCK_LATENCY Actived set_clock_latency -source 3.765 '
                        '[get_clocks {clk_audio}]\n')
        self.assertEqual(sum('physical-model proof' in e for e in review(self.root)), 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
