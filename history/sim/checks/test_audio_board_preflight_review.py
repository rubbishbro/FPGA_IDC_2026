"""Parent-owned adversarial preflight review; ONLY temporary fixtures are mutated.

Synthetic PLL text below is for gate tests, not vendor IP or a synthesis source.
"""
from __future__ import annotations
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve()
while not ((ROOT / "rtl").is_dir() and (ROOT / "sim").is_dir()):
    ROOT = ROOT.parent
import sys as _sim_sys  # noqa: E402
_sim_sys.path.insert(0, str(ROOT / "sim" / "support"))
from _sim_paths import bootstrap as _sim_bootstrap  # noqa: E402
ROOT = _sim_bootstrap(__file__)
PLATFORM = ROOT / 'rtl/platform/tang_mega_138k_pro'


class PreflightReview(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='board-gate-review-',
                                                dir='/tmp/opencode')
        self.root = Path(self.temp.name)
        self.man = json.loads((PLATFORM / 'board_build.json').read_text())
        files = self.man['sources'] + [self.man[k] for k in
                                      ('cst', 'sdc', 'source_list', 'readme')]
        files += [m['path'] for m in self.man['rom'].values()]
        for rel in files:
            dest = self.root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, dest)
            if dest.name == 'board_top.sv':
                # This copied wrapper belongs to the TEMP fixture; its absolute
                # ROM parameters must point into that fixture, not the real repo.
                dest.write_text(dest.read_text().replace(str(ROOT), str(self.root)))
        self.ip = self.root / 'rtl/platform/tang_mega_138k_pro/ip'
        for pll in self.man['pll']:
            path = self.ip / pll['ip_subdir'] / pll['ip_file']
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(self.synthetic(pll))
            if pll.get('mod_file'):
                # New Gowin PLL_ADV generation has a primitive companion. This
                # is still a synthetic gate fixture, never a real vendor IP.
                companion = dict(pll, module=pll['module'] + '_mod')
                (path.parent / pll['mod_file']).write_text(self.synthetic(companion))

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def synthetic(pll):
        ports = ', '.join(pll['ports'])
        declarations = ''.join(
            ('output ' if p == 'lock' or p.startswith('clkout') else 'input ')
            + p + ';\n' for p in pll['ports'])
        return (f'module {pll["module"]}({ports});\n'
                + declarations +
                'PLL probe (.CLKIN(clkin), .LOCK(lock), .CLKOUT0(clkout0));\n'
                'endmodule\n')

    def run_gate(self, code):
        p = subprocess.run([sys.executable, str(PLATFORM / 'preflight.py'),
                            '--root', str(self.root), '--ip-dir', str(self.ip),
                            '--no-tool'], capture_output=True, text=True,
                           cwd='/tmp/opencode')
        self.assertNotIn('Traceback', p.stderr)
        self.assertEqual(p.returncode, code, p.stdout + p.stderr)

    def pll_path(self):
        pll = self.man['pll'][0]
        return self.ip / pll['ip_subdir'] / pll['ip_file']

    def test_structural_fixture_only(self):
        self.run_gate(0)  # Not a PLL legality or synthesis assertion.

    def test_comment_only_ports_rejected(self):
        self.pll_path().write_text('// ' + self.synthetic(self.man['pll'][0]).replace('\n', '\n// '))
        self.run_gate(3)

    def test_behavioral_delay_rejected(self):
        text = self.pll_path().read_text().replace('endmodule',
                                                 'always #5 lock = ~lock;\nendmodule')
        self.pll_path().write_text(text)
        self.run_gate(3)

    def test_misleading_source_suffix_rejected(self):
        source = self.root / self.man['source_list']
        text = source.read_text()
        p = self.man['pll'][0]
        old = 'rtl/platform/tang_mega_138k_pro/ip/' + p['ip_subdir'] + '/' + p['ip_file']
        self.assertIn(old, text)
        source.write_text(text.replace(old, 'nonexistent/' + p['ip_subdir'] + '/' + p['ip_file']))
        self.run_gate(2)

    def test_missing_source_list_is_controlled(self):
        (self.root / self.man['source_list']).unlink()
        self.run_gate(2)

    def test_corrupt_middle_rom_word(self):
        path = self.root / self.man['rom']['coeff']['path']
        lines = path.read_text().splitlines()
        lines[2500] = 'NOT_HEX'
        path.write_text('\n'.join(lines) + '\n')
        self.run_gate(2)

    def test_extra_rom_token_rejected(self):
        path = self.root / self.man['rom']['coeff']['path']
        lines = path.read_text().splitlines()
        lines[2500] += ' 123456789ABCDEF012'
        path.write_text('\n'.join(lines) + '\n')
        self.run_gate(2)

    def test_body_word_overflow_rejected(self):
        path = self.root / self.man['rom']['body']['path']
        words = path.read_text().splitlines()
        words[37] = '100000000'  # 33 bits, not a valid signed32 ROM word
        path.write_text('\n'.join(words) + '\n')
        self.run_gate(2)

    def test_short_body_image_rejected(self):
        path = self.root / self.man['rom']['body']['path']
        path.write_text('\n'.join(path.read_text().splitlines()[:-1]) + '\n')
        self.run_gate(2)

    def test_disabled_production_body_rejected(self):
        path = self.root / 'rtl/platform/tang_mega_138k_pro/board_top.sv'
        self.assertIn('.ENABLE_BODY(1)', path.read_text())
        path.write_text(path.read_text().replace('.ENABLE_BODY(1)', '.ENABLE_BODY(0)'))
        self.run_gate(4)

    def test_wrong_production_instrument_rejected(self):
        path = self.root / 'rtl/platform/tang_mega_138k_pro/board_top.sv'
        self.assertIn('.BODY_INSTRUMENT(0)', path.read_text())
        path.write_text(path.read_text().replace('.BODY_INSTRUMENT(0)', '.BODY_INSTRUMENT(1)'))
        self.run_gate(4)

    def test_production_body_path_not_fixture_rejected(self):
        path = self.root / 'rtl/platform/tang_mega_138k_pro/board_top.sv'
        right = str(self.root / self.man['rom']['body']['path'])
        self.assertIn(right, path.read_text())
        path.write_text(path.read_text().replace(right, str(ROOT / self.man['rom']['body']['path'])))
        self.run_gate(4)

    def test_commented_generated_clock_not_a_constraint(self):
        path = self.root / self.man['sdc']
        lines = path.read_text().splitlines()
        # Comment all SDC; note strings still exist, but no active constraint does.
        path.write_text('\n'.join('# ' + line for line in lines) + '\n')
        self.run_gate(4)


if __name__ == '__main__':
    unittest.main(verbosity=2)
