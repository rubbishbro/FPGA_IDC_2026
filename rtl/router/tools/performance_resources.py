#!/usr/bin/env python3
"""Export six timbres for the parallel matrix/ABC engines in fixed Flash regions.

Default: per-instrument 32-note banks, 64 records/note, 64 bytes/record. The image
starts at instrument0 and is programmed at FLASH_BASE, without an 8MiB prefix.
Each bank exposes 16 keys; the low bank is the power-on default.
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
from pitch_tables import control_page
from matrix_resources import matrix_note,piano_abc
from pack_board_flash import board_layout, pack

INSTRUMENTS = {'piano':0, 'guitar':1, 'trumpet':3, 'violin':5,'piano_abc':10,'guitar_abc':11}
NOTE_RANGES={'piano':(21,52),'piano_abc':(21,52),'guitar':(40,71),'guitar_abc':(40,71),'trumpet':(51,82),'violin':(55,86)}
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
        data,metadata=matrix_note(name,midi)
        return dict(metadata,instrument=INSTRUMENTS[name],name=name,midi=midi,
            modes=64 if name=='piano' else 20,format='eng0 matrix',data=data,
            coeff_sha256=hashlib.sha256(data).hexdigest())
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
        table,row=piano_abc(midi)
    data = abc_record(table)
    return dict(row, instrument=INSTRUMENTS[name],name=name,midi=midi,
                modes=table.n_modes,format='eng1 ABC/P1T1',data=data,coeff_sha256=hashlib.sha256(data).hexdigest())


def generate(out, notes=None, banked=True):
    out=Path(out);out.mkdir(parents=True,exist_ok=True)
    if notes is not None:raise ValueError('A shared MIDI list cannot represent per-instrument ranges; use NOTE_RANGES')
    if not banked:raise ValueError('The production layout requires 32 notes per instrument')
    note_count=32
    note_maps={name:list(range(lo,hi+1)) for name,(lo,hi) in NOTE_RANGES.items()}
    files={};entries=[]
    for name, ident in INSTRUMENTS.items():
        data=bytearray()
        for slot,midi in enumerate(note_maps[name]):
            row=make_note(name,midi)
            # Validate both A and B using the same decoder-independent contract.
            if name not in ('piano','guitar'):
                words=np.frombuffer(row['data'],dtype='>i4').astype(np.int64).reshape(64,16)
                table=R.Eng1Coeffs(words[:,0],words[:,1],words[:,2],row['modes'])
                if abc_record(table) != row['data']:raise ValueError('record/P1T1 layout mismatch')
            payload=bytearray(row['data'])
            profile=((1<<80)|(int(row['period'])<<64)|(row['a_step']<<32)|row['r_step']) if name in ('trumpet','violin') else 0
            for mode,value in enumerate([(profile>>64)&0x1ffff,(profile>>32)&0xffffffff,profile&0xffffffff]):
                struct.pack_into('>I',payload,mode*64+28,value)
            row['data']=bytes(payload)
            row['coeff_sha256']=hashlib.sha256(row['data']).hexdigest()
            data.extend(row['data'])
            entries.append(dict({k:v for k,v in row.items() if k!='data'},slot=slot,
                                offset=ident*note_count*4096+slot*4096))
        engine='eng0' if name in ('piano','guitar') else 'eng1'
        path=out/f'{name}_{engine}.bin';path.write_bytes(data);files[ident]=path
        path.with_suffix('.mem').write_text(''.join(f'{v:02X}\n' for v in data))
        print('exported',name,note_count,'notes',len(data),'bytes',flush=True)
    base,capacity=board_layout()
    image,regions=pack(files,note_count*4096,base,capacity,control_profiles=True)
    control_offset=len(image)
    image+=control_page()
    if base+len(image)>min(capacity,1<<24):raise ValueError('control page exceeds Flash bounds')
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
    sources=[Path(__file__),Path(__file__).with_name('matrix_resources.py'),Path(__file__).with_name('pitch_tables.py'),Path(__file__).with_name('pitch_tables.json'),Path(__file__).with_name('sustain_profiles.json'),ROOT/'python/modal_sim/eng1_audition.py',
        ROOT/'python/modal_sim/guitar_refit_experiments.py',
        ROOT/'rtl/router/tools/sustain_resources.py',ROOT/'python/modal_sim/pitch_linear.py',
        ROOT/'python/modal_sim/router_eng1.py',ROOT/'python/modal_sim/params.py',
        ROOT/'python/modal_sim/eng1_rtl.py',ROOT/'FFT_results/params/guitar_manifest.json']
    sources += [Path(__file__).parent/'coefficients'/f'eng0_{name}.bin' for name in ('piano','guitar')]
    sources += [ROOT/'sythsound'/name for name in ['piano_coeff_scaled.txt','guitar_coeff_scaled.txt','guitar_param.txt']]
    sources += [ROOT/f'FFT_results/params/{name}_{suffix}' for name in ('piano','guitar')
                for suffix in ('coeff.mem','coeffindex.json')]
    sources += [ROOT/f'FFT_results/params/{name}_sustain.npz' for name in ('trumpet','violin')]
    manifest=dict(schema=5,control_page=dict(offset=control_offset,bytes=4096,ratio_word=0,sine_word=512,depth_word=768),format='instrument-indexed eng0 matrix + eng1 ABC/P1T1',resource_fs=48000,
        flash_base=base,flash_bytes=capacity,image_flash_address=base,image_bytes=len(image),
        image_sha256=hashlib.sha256(image).hexdigest(),notes=note_count,note_maps=note_maps,
        note_ranges={name:dict(instrument=INSTRUMENTS[name],first=lo,last=hi,count=32,
            low=list(range(lo,lo+16)),high=list(range(lo+16,hi+1))) for name,(lo,hi) in NOTE_RANGES.items()},
        note_banks=1,default_bank=0,first_midi=None,
        resource_mask=sum(1<<i for i in INSTRUMENTS.values()),pcm_headroom_bits=3,
        table_bytes=note_count*4096,storage_modes=64,active_modes_limit=64,eng1_active_modes_limit=48,record_bytes=64,
        record_formats={
            'eng0 matrix':dict(words=['a11 Q28','a12 Q30','a21 Q23','a22 Q28','gq Q32','gv Q34','wo Q29'],reserved_words=[],profile_word=7,profile_modes=[0,1,2]),
            'eng1 ABC/P1T1':dict(words=['G signed26 Q24','a1 signed26 Q24','a2 unsigned24'],reserved_words=[3,4,5,6],profile_word=7,profile_modes=[0,1,2],pitch_tag=P.TAG)},
        regions=regions,entries=entries,
        frontends=frontends,firmware_flash_address=0,bulk_erase_between_files=False,
        source_hashes={str(p.relative_to(ROOT)):digest(p) for p in sources})
    manifest['validation_status']='UNTESTED: 32-note banks generated offline; no RTL simulation, synthesis or board programming'
    manifest['gain_policy']='envelope then sum; count-gated left shift; no per-note gain'
    (out/'resources.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    for name in ('piano_eng1','guitar_eng1'):
        for suffix in ('.bin','.mem'):(out/(name+suffix)).unlink(missing_ok=True)
    return manifest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'rtl/router/tools/performance')
    args=parser.parse_args()
    manifest=generate(args.out)
    print(f'PASS {manifest["image_bytes"]} bytes at 0x{manifest["flash_base"]:06X}, '
          f'RESOURCE_MASK=0x{manifest["resource_mask"]:03X}',flush=True)


if __name__=='__main__':main()
