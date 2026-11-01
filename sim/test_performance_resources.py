"""Four selected timbres: deployed layout and source-to-loader format regressions."""
from pathlib import Path
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
sys.path.insert(0,str(ROOT/'rtl/router/tools'))
from check_performance_resources import check
import performance_resources as P

DIRECTORY=ROOT/'rtl/router/tools/performance'


class PerformanceResourcesTests(unittest.TestCase):
    def test_current_deployment_contract(self):
        result=check(DIRECTORY)
        self.assertEqual((result['records'],result['image_bytes']), (4096,393216))

    def test_exported_records_are_selected_source_coefficients(self):
        m=json.loads((DIRECTORY/'resources.json').read_text())
        data=(DIRECTORY/'resources.bin').read_bytes()
        for name,ident in P.INSTRUMENTS.items():
            for midi in (40,60,76):
                slot=m['note_map'].index(midi)
                row=P.make_note(name,midi)
                at=ident*65536+slot*4096
                self.assertEqual(data[at:at+4096],row['data'],(name,midi))

    def test_wrong_map_and_stride_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            d=Path(temp)
            for p in DIRECTORY.iterdir():
                if p.is_file():shutil.copyfile(p,d/p.name)
            original=json.loads((d/'resources.json').read_text())
            for change in ('map','offset'):
                m=json.loads(json.dumps(original))
                if change=='map':m['note_map'][0],m['note_map'][1]=m['note_map'][1],m['note_map'][0]
                else:m['entries'][-1]['offset']-=2*65536
                (d/'resources.json').write_text(json.dumps(m))
                with self.subTest(change=change),self.assertRaises(ValueError):check(d)

    def test_old_eng0_cli_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            p=subprocess.run([sys.executable,str(ROOT/'rtl/router/tools/pack_board_flash.py'),
                '--instrument',f'0={ROOT/"rtl/router/tools/piano_flash.bin"}',
                '--out',str(Path(temp)/'wrong.bin')],capture_output=True,text=True)
            self.assertNotEqual(p.returncode,0)
            self.assertIn('Expected ENG1 ABC/P1T1',p.stderr)
            self.assertFalse((Path(temp)/'wrong.bin').exists())

    def test_padding_cannot_be_computed_modes(self):
        data=(DIRECTORY/'resources.bin').read_bytes()
        for ident in (0,1,3,5):
            for slot in range(16):
                for mode in range(48,64):
                    self.assertEqual(struct.unpack_from('>3I',data,ident*65536+slot*4096+mode*64),(0,0,0))


if __name__=='__main__':unittest.main()
