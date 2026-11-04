"""PAD gesture invariants for the RTL-derived Python audition (stdlib runner)."""
from pathlib import Path
import sys
import unittest
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[3]/'python_monotor/modal_sim'))
import eng1_pad_audition as A
import eng1_rtl as E


class PadGestureTests(unittest.TestCase):
    def test_adc_boundaries_and_hysteresis_do_not_create_extra_attacks(self):
        # Exercise the board's actual raw thresholds: >16 down, <12 up.
        raw = np.array([0, 16, 17, 16, 12, 11, 16, 17, 64, 127, 128, 255])
        force = A.board_force_map(raw)
        self.assertEqual(force.tolist(), [0, 64, 68, 64, 48, 44, 64, 68, 255, 255, 0, 0])
        gate = False
        edges = []
        for i, value in enumerate(force):
            new = value >= 48 if gate else value > 64
            if new and not gate:
                edges.append(i)
            gate = new
        self.assertEqual(edges, [2, 7])

    def test_duplicate_score_notes_retain_a_real_release(self):
        events = [dict(midi=60, velocity=86, time=.02, duration=.08),
                  dict(midi=60, velocity=86, time=.12, duration=.08)]
        for gradual in (False, True):
            p = A.board_force_map(A.pressure_fixture(events, round(.24*A.FS), gradual))
            gate = False
            edges = []
            for i, value in enumerate(p[:, 0]):
                new = value >= 48 if gate else value > 64
                if new != gate:
                    edges.append((i, bool(new)))
                gate = new
            self.assertEqual([up for _, up in edges], [True, False, True, False])
            self.assertGreaterEqual(edges[2][0]-edges[1][0], round(.02*A.FS))

    def test_held_pressure_variation_changes_impulses_without_retriggering(self):
        excitation = E.Excitation([8])
        envelope = E.Envelope([1000000], [1000000])
        samples = []
        levels = []
        for i in range(25):
            level = 128 if i < 12 else 192
            samples.append(int(excitation.step([True], [level], [False], [False], [0])[0]))
            levels.append(int(envelope.step([True], [False], [False])[0]))
        self.assertEqual(np.flatnonzero(samples).tolist(), [0, 8, 16, 24])
        self.assertEqual([samples[i] for i in (0, 8, 16, 24)],
                         [128 << 16, 128 << 16, 192 << 16, 192 << 16])
        self.assertEqual(levels[0], 0)
        self.assertTrue(np.all(np.diff(levels) > 0))


if __name__ == '__main__':
    unittest.main()
