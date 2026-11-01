#!/usr/bin/env python3
"""Export six timbres for the parallel matrix/ABC engines in fixed Flash regions.

Default: existing 16-pad note map, 64 records/note, 64 bytes/record. The image
starts at instrument0 and is programmed at FLASH_BASE, without an 8MiB prefix.
The optional banked range must be explicitly requested; it is never inferred.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'python/modal_sim'))
import eng1_audition as A
import guitar_refit_experiments as F
import pitch_linear as P
import router_eng1 as R
import sustain_resources as S
from pack_board_flash import board_layout, pack

INSTRUMENTS = {'piano':0, 'guitar':1, 'trumpet':3, 'violin':5,'piano_abc':10,'guitar_abc':11}
LEGACY_NOTES = (40,42,44,46,48,50,52,54,56,58,60,62,64,67,71,76)
PIANO_BODY = [[133721719,-267443437,133721719,-267441604,133227543],
              [183667245,-305371893,130743169,-214866875,89687668]]+[[1<<27,0,0,0,0]]*3


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def abc_record(table):
    """Current loader mapping: coeff_t.a11=G,a12=a1,a21=a2; no matrix Q's."""
    if not 0 < table.n_modes <= 48:
        raise ValueError('ENG1 supports 1..48 active modes, 64 stored records')
    g, a1, a2 = (np.asarray(v, dtype=np.int64)[:table.n_modes]
                  for v in (table.G,table.a1,table.a2))
    if np.any((g < -(1<<25)) | (g >= 1<<25)) or np.any((a1 < -(1<<25)) | (a1 >= 1<<25)):
        raise ValueError('G/a1 outside signed26 Q2.24')
    if np.any((a2 <= 0) | (a2 >= 1<<24)):
        raise ValueError('active a2 outside stable unsigned24 range')
    if np.any((1<<24)+a1+a2 <= 0) or np.any((1<<24)-a1+a2 <= 0):
        raise ValueError('quantized resonator violates strict Jury stability')
    words = P.modulation_words(table)
    records = []
    for mode in range(64):
        coeffs = [int(g[mode]),int(a1[mode]),int(a2[mode])] if mode < table.n_modes else [0]*3
        records.extend(coeffs+[0]*5+words[mode])
    return struct.pack('>1024I', *(v & 0xffffffff for v in records))


def make_note(name, midi):
    if name in ('piano','guitar'):
        if midi not in LEGACY_NOTES:
            raise ValueError('Legacy matrix image uses its fixed 16-note map; generate a matching matrix bank before changing ranges')
        source=Path(__file__).with_name(name+'_flash.bin')
        original=source.read_bytes();offset=(65536 if name=='guitar' else 0)+LEGACY_NOTES.index(midi)*4096
        data=original[offset:offset+4096]
        if len(data)!=4096:raise ValueError('truncated matrix table')
        return dict(instrument=INSTRUMENTS[name],name=name,midi=midi,source_midi=midi,
            modes=64 if name=='piano' else 20,format='eng0 matrix',data=data,
            selection='preserved original matrix image',coeff_sha256=hashlib.sha256(data).hexdigest())
    if name in ('trumpet','violin'):
        row = S.make_note(name,midi,True)
        if row is None:raise ValueError(f'{name} MIDI{midi}: no resource')
        return row
    if name == 'guitar_abc':
        table, row = F.table_for(midi,'measured','source_amplitude')
        source = ROOT/row['source_file']
        row = dict(row, selection='F: refit_amplitude_envelope',
                   source_recording_sha256=digest(source))
    else:
        table, row = A.experimental_table('piano',midi)
        row = dict(row, selection='selected short strike + clear body + 512ms release')
    data = abc_record(table)
    return dict(row, instrument=INSTRUMENTS[name],name=name,midi=midi,
                modes=table.n_modes,format='eng1 ABC/P1T1',data=data,coeff_sha256=hashlib.sha256(data).hexdigest())


def generate(out, notes=LEGACY_NOTES, banked=False):
    out=Path(out);out.mkdir(parents=True,exist_ok=True)
    notes=tuple(notes)
    if len(notes) not in (16,32) or len(set(notes)) != len(notes) or min(notes)<0 or max(notes)>127:
        raise ValueError('require 16 or 32 distinct MIDI notes in 0..127')
    if banked and (len(notes)!=32 or notes!=tuple(range(notes[0],notes[0]+32))):
        raise ValueError('banked resources require 32 consecutive notes')
    files={};entries=[]
    for name, ident in INSTRUMENTS.items():
        data=bytearray()
        for slot,midi in enumerate(notes):
            row=make_note(name,midi)
            # Validate both A and B using the same decoder-independent contract.
            if name not in ('piano','guitar'):
                words=np.frombuffer(row['data'],dtype='>i4').astype(np.int64).reshape(64,16)
                table=R.Eng1Coeffs(words[:,0],words[:,1],words[:,2],row['modes'])
                if abc_record(table) != row['data']:raise ValueError('record/P1T1 layout mismatch')
            data.extend(row['data'])
            entries.append(dict({k:v for k,v in row.items() if k!='data'},slot=slot,
                                offset=ident*len(notes)*4096+slot*4096))
        engine='eng0' if name in ('piano','guitar') else 'eng1'
        path=out/f'{name}_{engine}.bin';path.write_bytes(data);files[ident]=path
        path.with_suffix('.mem').write_text(''.join(f'{v:02X}\n' for v in data))
        print('exported',name,len(notes),'notes',len(data),'bytes',flush=True)
    base,capacity=board_layout()
    image,regions=pack(files,len(notes)*4096,base,capacity)
    (out/'resources.bin').write_bytes(image)
    (out/'resources.mem').write_text(''.join(f'{v:02X}\n' for v in image))
    frontends=dict(
        piano_abc=dict(engine='eng1',rise_sh=1,pw_len=2,gap_len=478,n_pulse=3,
                   a_step=16777216,d_step=1048576,s_level=536870912,r_step=21845,
                   envelope_output='old level',body_q27=PIANO_BODY),
        guitar_abc=dict(engine='eng1',selection='F',rise_sh=1,pw_len=2,gap_len=0,n_pulse=0,
                    a_step=89478486,d_step=0,s_level=2147483647,r_step=74566,
                    envelope_output='old level',body_q27=R.body_coeffs('guitar'),
                    legacy_matrix_modulation=False),
        violin=dict(engine='eng1',excitation='periodic impulse',a_step=2236963,d_step=0,
                    s_level=2147483647,r_step=559241,envelope_output='current level',
                    automatic_legato=False),
        trumpet=dict(engine='eng1',excitation='current periodic impulse',
                     envelope='original per-note A/R; D=1048576,S=536870911',
                     python_lip_excitation_implemented=False))
    frontends['piano']=dict(frontends['piano_abc'],engine='eng0',rise_sh=5,pw_len=32,gap_len=448,
                            body_q27=R.body_coeffs('piano'))
    frontends['guitar']=dict(frontends['guitar_abc'],engine='eng0',selection='original matrix',
                             legacy_matrix_modulation=True)
    sources=[Path(__file__),ROOT/'python/modal_sim/eng1_audition.py',
        ROOT/'python/modal_sim/guitar_refit_experiments.py',
        ROOT/'rtl/router/tools/sustain_resources.py',ROOT/'python/modal_sim/pitch_linear.py',
        ROOT/'python/modal_sim/router_eng1.py',ROOT/'python/modal_sim/params.py',
        ROOT/'python/modal_sim/eng1_rtl.py',ROOT/'FFT_results/params/guitar_manifest.json']
    sources += [Path(__file__).with_name(name+'_flash.bin') for name in ('piano','guitar')]
    sources += [ROOT/f'FFT_results/params/{name}_{suffix}' for name in ('piano','guitar')
                for suffix in ('coeff.mem','coeffindex.json')]
    sources += [ROOT/f'FFT_results/params/{name}_sustain.npz' for name in ('trumpet','violin')]
    manifest=dict(schema=3,format='instrument-indexed eng0 matrix + eng1 ABC/P1T1',resource_fs=48000,
        flash_base=base,flash_bytes=capacity,image_flash_address=base,image_bytes=len(image),
        image_sha256=hashlib.sha256(image).hexdigest(),notes=len(notes),note_map=notes,
        note_banks=int(banked),first_midi=notes[0] if banked else None,
        resource_mask=sum(1<<i for i in INSTRUMENTS.values()),pcm_headroom_bits=3,
        table_bytes=len(notes)*4096,storage_modes=64,active_modes_limit=64,eng1_active_modes_limit=48,record_bytes=64,
        record_formats={
            'eng0 matrix':dict(words=['a11 Q28','a12 Q30','a21 Q23','a22 Q28','gq Q32','gv Q34','wo Q29'],reserved_words=[7]),
            'eng1 ABC/P1T1':dict(words=['G signed26 Q24','a1 signed26 Q24','a2 unsigned24'],reserved_words=[3,4,5,6,7],pitch_tag=P.TAG)},
        regions=regions,entries=entries,
        frontends=frontends,firmware_flash_address=0,bulk_erase_between_files=False,
        source_hashes={str(p.relative_to(ROOT)):digest(p) for p in sources})
    if (out/'gain.json').is_file():
        gain=json.loads((out/'gain.json').read_text())
        if gain['resources_sha256']!=manifest['image_sha256']:
            raise ValueError('Coefficient image changed: regenerate gain calibration before final packaging')
        manifest['gain_calibration']=dict(file='gain.json',sha256=digest(out/'gain.json'),
            headroom=gain['headroom'],normalization='per-note Q12 + common polyphony Q12')
        manifest['source_hashes']['rtl/router/pkg/performance_gain_pkg.sv']=digest(ROOT/'rtl/router/pkg/performance_gain_pkg.sv')
    (out/'resources.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    for name in ('piano_eng1','guitar_eng1'):
        for suffix in ('.bin','.mem'):(out/(name+suffix)).unlink(missing_ok=True)
    return manifest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'rtl/router/tools/performance')
    parser.add_argument('--banked-first-midi',type=int,help='Explicitly choose a new consecutive 32-note layout')
    args=parser.parse_args()
    notes=LEGACY_NOTES if args.banked_first_midi is None else tuple(range(args.banked_first_midi,args.banked_first_midi+32))
    manifest=generate(args.out,notes,args.banked_first_midi is not None)
    print(f'PASS {manifest["image_bytes"]} bytes at 0x{manifest["flash_base"]:06X}, '
          f'RESOURCE_MASK=0x{manifest["resource_mask"]:03X}',flush=True)


if __name__=='__main__':main()
