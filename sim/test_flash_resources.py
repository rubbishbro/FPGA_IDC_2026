#!/usr/bin/env python3
"""Deployment address/packing tests, including pre-existing padded guitar BIN."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('pack_board_flash',ROOT/'rtl/router/tools/pack_board_flash.py')
pack_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(pack_module)

class FlashResourceTests(unittest.TestCase):
    def test_actual_images_do_not_gain_padding_or_double_offset(self):
        piano=ROOT/'rtl/router/tools/coefficients/eng0_piano.bin';guitar=ROOT/'rtl/router/tools/coefficients/eng0_guitar.bin'
        base,capacity=pack_module.board_layout()
        self.assertEqual((base,capacity),(0x800000,0x1000000))
        packed,manifest=pack_module.pack({0:piano,1:guitar},65536,base,capacity)
        self.assertEqual(packed,piano.read_bytes()+guitar.read_bytes()[65536:131072])
        self.assertEqual(len(packed),131072)
        self.assertEqual([r['flash_address'] for r in manifest],[0x800000,0x810000])

    def test_physical_and_24bit_boundaries(self):
        pack_module.check_layout(0xffffc0,0x1000000,64)
        for args in [(0x800000,0x800000,64),(0xffffc0,0x1000000,128),(0x1000000,0x2000000,64),(0x800001,0x1000000,64)]:
            with self.subTest(args=args),self.assertRaises(ValueError):pack_module.check_layout(*args)

    def test_reject_unrecognized_prefix_or_wrong_record_size(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'bad.bin'
            for data in [b'\0'*127,b'\0'*128,b'\xff'*64]:
                p.write_bytes(data)
                with self.assertRaises(ValueError):pack_module.pack({1:p},64,0x800000,0x1000000)

if __name__=='__main__':unittest.main()
