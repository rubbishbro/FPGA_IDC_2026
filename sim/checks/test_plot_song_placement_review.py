"""Pure parser checks; artificial fixture sites are NOT FPGA placement evidence."""
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

from plot_song_placement_review import backannotated_positions


class ExportParserTests(unittest.TestCase):
    def setUp(self):
        self.report = {"a": dict(location="R1C2[0][A]", row=1, column=2)}

    def test_fixed_sites_and_ignored_non_cfu(self):
        text = ('INS_LOC "a" R1C2[0][A];\n'
                'INS_LOC "b" R3C4[2][B];\n'
                'INS_LOC "pll" PLL_R[3];\n')
        parsed = backannotated_positions(text, self.report, ["a"])
        self.assertEqual(set(parsed), {"a", "b"})
        self.assertEqual(parsed["b"]["column"], 4)

    def test_region_is_not_actual_site(self):
        with self.assertRaisesRegex(ValueError, "missing exact"):
            backannotated_positions('INS_LOC "a" R[1:2]C[2:3];', self.report, ["a"])

    def test_wrong_anchor_refused(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            backannotated_positions('INS_LOC "a" R9C2[0][A];', self.report, ["a"])

    def test_conflicting_export_refused(self):
        with self.assertRaisesRegex(ValueError, "conflicting"):
            backannotated_positions('INS_LOC "a" R1C2[0][A];\nINS_LOC "a" R2C2[0][A];',
                                    self.report, ["a"])

    def test_other_known_report_site_must_match(self):
        report = {**self.report, "b": dict(location="R3C4[0][A]", row=3, column=4)}
        with self.assertRaisesRegex(ValueError, "coordinate mismatch"):
            backannotated_positions('INS_LOC "a" R1C2[0][A];\nINS_LOC "b" R3C5[0][A];',
                                    report, ["a"])


if __name__ == "__main__":
    unittest.main()
