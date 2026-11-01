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
        self.assertEqual((result['records'],result['image_bytes']), (6144,786432))

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

    def test_polyphony_gain_lut_is_inverse_sqrt(self):
        pkg=(ROOT/'rtl/router/pkg/performance_gain_pkg.sv').read_text()
        scales={int(k):int(v) for k,v in
                re.findall(r"5'd(\d+):return 13'd(\d+)",pkg)}
        expected=[4096]+[round(4096/math.sqrt(i)) for i in range(1,17)]
        self.assertEqual([scales.get(i) for i in range(17)],expected)

    def test_missing_calibration_dependency_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            d=Path(temp)
            for p in DIRECTORY.iterdir():
                if p.is_file():shutil.copyfile(p,d/p.name)
            gain=json.loads((d/'gain.json').read_text())
            del gain['source_hashes']['python/modal_sim/eng1_rtl.py']
            (d/'gain.json').write_text(json.dumps(gain))
            m=json.loads((d/'resources.json').read_text())
            m['gain_calibration']['sha256']=hashlib.sha256((d/'gain.json').read_bytes()).hexdigest()
            (d/'resources.json').write_text(json.dumps(m))
            with self.assertRaisesRegex(ValueError,'missing calibration dependencies'):check(d)

    def test_fresh_resources_cannot_bless_stale_model_gain(self):
        with tempfile.TemporaryDirectory() as temp:
            d=Path(temp)
            for p in DIRECTORY.iterdir():
                if p.is_file():shutil.copyfile(p,d/p.name)
            gain=json.loads((d/'gain.json').read_text())
            gain['source_hashes']['python/modal_sim/eng1_rtl.py']='0'*64
            (d/'gain.json').write_text(json.dumps(gain))
            m=json.loads((d/'resources.json').read_text())
            m['gain_calibration']['sha256']=hashlib.sha256((d/'gain.json').read_bytes()).hexdigest()
            (d/'resources.json').write_text(json.dumps(m))
            with self.assertRaisesRegex(ValueError,'stale gain source: python/modal_sim/eng1_rtl.py'):check(d)

    def test_wrong_engine_id_cli_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            p=subprocess.run([sys.executable,str(ROOT/'rtl/router/tools/pack_board_flash.py'),
                '--instrument',f'10={ROOT/"rtl/router/tools/piano_flash.bin"}',
                '--out',str(Path(temp)/'wrong.bin')],capture_output=True,text=True)
            self.assertNotEqual(p.returncode,0)
            self.assertIn('Instrument ID/engine format mismatch',p.stderr)
            self.assertFalse((Path(temp)/'wrong.bin').exists())

    def test_padding_cannot_be_computed_modes(self):
        data=(DIRECTORY/'resources.bin').read_bytes()
        for ident in (3,5,10,11):
            for slot in range(16):
                for mode in range(48,64):
                    self.assertEqual(struct.unpack_from('>3I',data,ident*65536+slot*4096+mode*64),(0,0,0))


if __name__=='__main__':unittest.main()
