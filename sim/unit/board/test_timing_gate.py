#!/usr/bin/env python3
"""The board acceptance gate must reject every clock-check category independently."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
CHECK = ROOT / 'rtl/platform/tang_mega_138k_pro/check_board.py'
TABLES = {
    'setup': '3.1.1 Setup Paths Table',
    'hold': '3.1.2 Hold Paths Table',
    'recovery': '3.1.3 Recovery Paths Table',
    'removal': '3.1.4 Removal Paths Table',
    'min_pulse_width': '3.2 Minimum Pulse Width Table',
}

class TimingGate(unittest.TestCase):
    def invoke(self, bad=None, omit=None):
        text = '<Numbers of Setup Violated Endpoints>:0\n<Numbers of Hold Violated Endpoints>:0\n'
        for i,(name,target) in enumerate([('clk50',50),('clk_core',50),('clk_audio',12.5),('clk_pix',33.333)]):
            text+=f'  {i+1} {name} {target:.3f}(MHz) {target+10:.3f}(MHz) 1 TOP\n'
        # Include the real report's directory: a TOC entry is not a timing table.
        text += '\n'.join('\t' + title for title in TABLES.values()) + '\n'
        for name, title in TABLES.items():
            if name != omit:
                text += f'\n{title}\n  1  {"-0.001" if name == bad else "0.100"}  source  destination\n'
        text += '\n3.3 Timing Report By Analysis Type\n'
        if omit != 'max_delay':
            text += ('\n3.7.1 Setup Analysis Report\n'
                     'Timing Path Constraint[1]: set_max_delay -from source -to capture 10.000\n'
                     f'Slack : {"-0.001" if bad == "max_delay" else "0.100"}\n'
                     '3.7.2 Hold Analysis Report\n')
        with tempfile.TemporaryDirectory() as tmp:
            report, result = Path(tmp)/'fixture.tr', Path(tmp)/'result.json'
            report.write_text(text)
            run = subprocess.run(['python3', str(CHECK), '--timing', str(report), '--out', str(result)],
                                 cwd=ROOT, capture_output=True, text=True)
            return run.returncode, json.loads(result.read_text()) if result.exists() else None

    def test_clean(self):
        code, result = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(result['status'], 'passed')

    def test_each_category_rejects_even_with_zero_summary_counts(self):
        for name in [*TABLES, 'max_delay']:
            with self.subTest(category=name):
                code, result = self.invoke(bad=name)
                self.assertNotEqual(code, 0)
                self.assertEqual(result['timing']['checks'][name]['reported_violations'], 1)

    def test_missing_table_fails_closed(self):
        for name in [*TABLES, 'max_delay']:
            with self.subTest(category=name):
                code, _ = self.invoke(omit=name)
                self.assertNotEqual(code, 0)

if __name__ == '__main__':
    unittest.main()
