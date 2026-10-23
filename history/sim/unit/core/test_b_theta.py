"""gen_b_theta 的纯 Python 对拍：已知 θ -> core -> 反推 θ。"""

from __future__ import annotations

import math
import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE
while not (os.path.isdir(os.path.join(_ROOT, "rtl"))
           and os.path.isdir(os.path.join(_ROOT, "sim"))):
    _ROOT = os.path.dirname(_ROOT)
sys.path.insert(0, os.path.join(_ROOT, "python", "modal_sim"))

from gen_b_theta import theta_from_a1a2, theta_q_from_core, unpack_core  # noqa: E402


def pack_core(a1: int, a2: int, g: int = 0) -> int:
    return ((g & ((1 << 26) - 1)) << 46) | ((a2 & ((1 << 24) - 1)) << 22) | (a1 & ((1 << 22) - 1))


class TestTheta(unittest.TestCase):
    def test_roundtrip(self):
        r = 0.9
        for th in (0.01, 0.1, 0.5, 1.0, 2.0, 3.0, math.pi - 0.01):
            a1 = int(round(-2.0 * r * math.cos(th) * (1 << 20)))
            a2 = int(round(r * r * (1 << 24)))
            q = theta_q_from_core(pack_core(a1, a2))
            self.assertLessEqual(abs(q / 16384.0 - th), 1.5 / 16384.0,
                                 (th, q / 16384.0))

    def test_zero_radius(self):
        q = theta_q_from_core(pack_core(0, 0))
        self.assertEqual(q, 0)

    def test_clamp(self):
        # 故意给越界 cos，不能抛异常
        q = theta_q_from_core(pack_core(0, 1 << 24))
        self.assertGreaterEqual(q, 0)
        self.assertLessEqual(q, 65535)

    def test_unpack(self):
        w = pack_core(-1234, 0x123456, g=0x1ABCDE)
        g, a1, a2 = unpack_core(w)
        self.assertEqual(a1, -1234)
        self.assertEqual(a2, 0x123456)
        self.assertEqual(g & ((1 << 26) - 1), 0x1ABCDE)


if __name__ == "__main__":
    unittest.main()
