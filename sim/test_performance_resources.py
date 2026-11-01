"""Six timbres: both engines, fixed address regions and format regressions."""
from pathlib import Path
import json
import hashlib
import math
import re
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
        self.assertEqual((result['records'],result['image_bytes']), (12288,1576960))

    def test_exported_records_are_selected_source_coefficients(self):
        m=json.loads((DIRECTORY/'resources.json').read_text())
        data=(DIRECTORY/'resources.bin').read_bytes()
        for name,ident in P.INSTRUMENTS.items():
            for slot in (0,15,16,31):
                midi=m['note_maps'][name][slot]
                row=P.make_note(name,midi)
                profile=((1<<80)|(row['period']<<64)|(row['a_step']<<32)|row['r_step']) if name in ('trumpet','violin') else 0
                from pitch_tables import with_profile
                row['data']=with_profile(row['data'],profile)
                at=ident*131072+slot*4096
                self.assertEqual(data[at:at+4096],row['data'],(name,midi))

    def test_wrong_map_and_stride_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            d=Path(temp)
            for p in DIRECTORY.iterdir():
                if p.is_file():shutil.copyfile(p,d/p.name)
            original=json.loads((d/'resources.json').read_text())
            for change in ('map','offset'):
                m=json.loads(json.dumps(original))
                if change=='map':m['note_maps']['piano'][0],m['note_maps']['piano'][1]=m['note_maps']['piano'][1],m['note_maps']['piano'][0]
                else:m['entries'][-1]['offset']-=2*65536
                (d/'resources.json').write_text(json.dumps(m))
                with self.subTest(change=change),self.assertRaises(ValueError):check(d)

    def test_engine_identity_is_keyed_by_instrument_id(self):
        with tempfile.TemporaryDirectory() as temp:
            d=Path(temp)
            for p in DIRECTORY.iterdir():
                if p.is_file():shutil.copyfile(p,d/p.name)
            original=json.loads((d/'resources.json').read_text())
            for change in ('name','format','coverage','frontend','region'):
                m=json.loads(json.dumps(original))
                entry=next(e for e in m['entries'] if e['instrument']==10)
                if change=='name':entry['name']='piano'
                elif change=='format':entry['format']='eng0 matrix'
                elif change=='coverage':m['entries'].remove(entry)
                elif change=='frontend':m['frontends']['piano']['engine']='eng1'
                else:m['regions'][0]['flash_address']+=64
                (d/'resources.json').write_text(json.dumps(m))
                with self.subTest(change=change),self.assertRaises(ValueError):check(d)

    def test_wrong_engine_id_cli_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            p=subprocess.run([sys.executable,str(ROOT/'rtl/router/tools/pack_board_flash.py'),
                '--instrument',f'10={ROOT/"rtl/router/tools/coefficients/eng0_piano.bin"}',
                '--out',str(Path(temp)/'wrong.bin')],capture_output=True,text=True)
            self.assertNotEqual(p.returncode,0)
            self.assertIn('Instrument ID/engine format mismatch',p.stderr)
            self.assertFalse((Path(temp)/'wrong.bin').exists())

    def test_padding_cannot_be_computed_modes(self):
        data=(DIRECTORY/'resources.bin').read_bytes()
        for ident in (3,5,10,11):
            for slot in range(16):
                for mode in range(48,64):
                    self.assertEqual(struct.unpack_from('>3I',data,ident*131072+slot*4096+mode*64),(0,0,0))


if __name__=='__main__':unittest.main()
