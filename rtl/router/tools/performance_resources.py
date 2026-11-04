#!/usr/bin/env python3
"""Export all twelve timbres for the parallel matrix/ABC engines in fixed Flash regions.

Default: per-instrument 32-note banks, 64 records/note, 64 bytes/record. The image
starts at instrument0 and is programmed at FLASH_BASE, without an 8MiB prefix.
Each bank exposes 16 keys; the low bank is the power-on default.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import re
import subprocess
import sys
from functools import lru_cache

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'python_monotor/modal_sim'))
import eng1_audition as A
import guitar_refit_experiments as F
import pitch_linear as P
import router_eng1 as R
import sustain_resources as S
from drum_coefficients import DRUM_GM_NOTES,DRUM_KEYS,build_coefficients
import drumkit as DK
import percussion as PC
from pitch_tables import control_page
from matrix_resources import matrix_note,piano_abc
from pack_board_flash import board_layout, pack

INSTRUMENTS = {'piano':0,'guitar':1,'flute':2,'trumpet':3,'cello':4,'violin':5,'oboe':6,'drums':7,'banjo':8,'mandolin':9,'piano_abc':10,'guitar_abc':11}
SUSTAINED=('flute','trumpet','cello','violin','oboe')
NOTE_RANGES={'piano':(44,75),'piano_abc':(44,75),'guitar':(44,75),'guitar_abc':(44,75),'trumpet':(51,82),'violin':(55,86),'flute':(60,91),'cello':(44,75),'oboe':(58,89),'banjo':(48,79),'mandolin':(55,86)}
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
    silent=(g==0)&(a1==0)&(a2==0)
    if np.any(((a2 <= 0) | (a2 >= 1<<24)) & ~silent):
        raise ValueError('active a2 outside stable unsigned24 range')
    if np.any(((1<<24)+a1+a2 <= 0) & ~silent) or np.any(((1<<24)-a1+a2 <= 0) & ~silent):
        raise ValueError('quantized resonator violates strict Jury stability')
    words = P.modulation_words(table)
    records = []
    for mode in range(64):
        coeffs = [int(g[mode]),int(a1[mode]),int(a2[mode])] if mode < table.n_modes else [0]*3
        records.extend(coeffs+[0]*5+words[mode])
    return struct.pack('>1024I', *(v & 0xffffffff for v in records))


@lru_cache(None)
def _plucked_raw(name,midi):
    # Exact target MIDI; choose a recorded dynamic explicitly, never a neighbour.
    index=json.loads((ROOT/f'python_monotor/results/params/{name}_coeffindex.json').read_text())
    dynamic='forte' if f'{midi}|forte' in index else 'piano'
    old=R.load_a_table(name,midi,dynamic)
    # Old ABC gains assume a seven-sample raised-cosine pulse. Recalibrate
    # to exc_router's current generic 32-sample pluck, preserving modal peaks.
    from scipy.signal import lfilter
    previous=np.zeros(8192);previous[:7]=.5-.5*np.cos(2*np.pi*np.arange(7)/7)
    strike=A.Strike('guitar',1);strike.rise=5;strike.width=32
    current=np.array([int(strike.step([255],[True],[n==0],[False])[0])/float(255<<16) for n in range(8192)])
    gains=[]
    for g,a1,a2 in zip(old.G,old.a1,old.a2):
        den=[1.,int(a1)/(1<<24),int(a2)/(1<<24)]
        ratio=max(abs(lfilter([1.],den,previous)))/max(max(abs(lfilter([1.],den,current))),1e-30)
        gains.append(round(int(g)*ratio))
    return old,np.array(gains,dtype=np.int64),dict(source_midi=midi,source_dynamic=dynamic,retuned=False,
        selection='exact source ABC; generic 32-sample pluck peak calibration')


def plucked_note(name,midi):
    old,gains,row=_plucked_raw(name,midi)
    lo,hi=NOTE_RANGES[name]
    # One common bank scale, not per-mode clipping or per-note normalization.
    maximum=max(int(np.max(np.abs(_plucked_raw(name,n)[1]))) for n in range(lo,hi+1))
    scale=min(1.,((1<<25)-1)/max(maximum,1))
    gains=np.rint(gains*scale).astype(np.int64)
    table=R.Eng1Coeffs(gains,old.a1,old.a2,old.n_modes,label=f'{name}:{midi}:production')
    return table,dict(row,bank_gain_scale=scale)


@lru_cache(None)
def drum_notes():
    # Refit from source NPZ on each production invocation, never depend on a preview.
    subprocess.run([sys.executable,str(ROOT/'sim/fit_drum_noise.py')],cwd=ROOT,check=True)
    fits=json.loads((ROOT/'build/drum_filter_fit/results.json').read_text())['rows']
    kit=PC.load_kit(str(ROOT/'python_monotor/results/params/drums.npz'));result={}
    for key,gm in zip(DRUM_KEYS,DRUM_GM_NOTES):
        spec=kit[key];table,co,branches=build_coefficients(key,spec,fits)
        balance=DK._piece_norm(kit,key,1.,3.)*DK.KIT_GAIN[key]
        # Piece balance is part of the accepted drum method; the common Q12 trim
        # stays in router_pkg. Apply balance once to modal and noise gains.
        co[:48,0]=np.floor(co[:48,0]*balance+.5).astype(np.int64)
        co[[48,50],5]=np.floor(co[[48,50],5]*balance+.5).astype(np.int64)
        modal=R.Eng1Coeffs(co[:48,0],co[:48,1],co[:48,2],table.n_modes)
        data=bytearray(abc_record(modal))
        for mode in range(48,64):
            struct.pack_into('>16I',data,mode*64,*(int(v)&0xffffffff for v in [*co[mode],*([0]*9)]))
        result[gm]=dict(instrument=7,name='drums',midi=gm,drum=key,modes=52,
            modal_modes=table.n_modes,format='eng1 drum ABC/noise',reference_balance=balance,
            data=bytes(data),coeff_sha256=hashlib.sha256(data).hexdigest())
    return result


def make_note(name, midi):
    if name=='drums':return dict(drum_notes()[midi])
    if name in ('piano','guitar'):
        data,metadata=matrix_note(name,midi)
        return dict(metadata,instrument=INSTRUMENTS[name],name=name,midi=midi,
            modes=64 if name=='piano' else 20,format='eng0 matrix',data=data,
            coeff_sha256=hashlib.sha256(data).hexdigest())
    if name in SUSTAINED:
        row = S.make_note(name,midi,True)
        if row is None:raise ValueError(f'{name} MIDI{midi}: no resource')
        return row
    if name in ('banjo','mandolin'):
        table,row=plucked_note(name,midi)
    elif name == 'guitar_abc':
        table, row = F.table_for(midi,'measured','source_amplitude')
        source = ROOT/row['source_file']
        row = dict(row, selection='F: refit_amplitude_envelope',
                   source_recording_sha256=digest(source))
    else:
        table,row=piano_abc(midi)
    data = abc_record(table)
    return dict(row, instrument=INSTRUMENTS[name],name=name,midi=midi,
                modes=table.n_modes,format='eng1 ABC/P1T1',data=data,coeff_sha256=hashlib.sha256(data).hexdigest())


def frontend_configs():
    frontends=dict(
        piano_abc=dict(engine='eng1',rise_sh=2,pw_len=4,gap_len=476,n_pulse=3,
                   a_step=16777216,d_step=1048576,s_level=536870912,r_step=21845,
                   envelope_output='old level',body_q27=PIANO_BODY),
        guitar_abc=dict(engine='eng1',selection='F',rise_sh=5,pw_len=32,gap_len=0,n_pulse=0,output_shift=3,
                    a_step=89478486,d_step=0,s_level=2147483647,r_step=74566,
                    envelope_output='old level',body_q27=R.body_coeffs('guitar'),
                    legacy_matrix_modulation=False),
        violin=dict(engine='eng1',excitation='periodic impulse',a_step=2236963,d_step=0,
                    s_level=2147483647,r_step=559241,envelope_output='current level',
                    automatic_legato=False),
        trumpet=dict(engine='eng1',excitation='dyadic bipolar lip + onset jitter + band-limited air',
                     envelope='original per-note A/R; D=1048576,S=536870911',
                     excitation_module='trumpet_excitation',
                     experiment_equivalence='multiplier-free approximation, not sine/Gaussian bit exact'))
    frontends['piano']=dict(frontends['piano_abc'],engine='eng0',rise_sh=5,pw_len=32,gap_len=448,
                            body_q27=R.body_coeffs('piano'))
    frontends['guitar']=dict(frontends['guitar_abc'],engine='eng0',selection='original matrix',
                             rise_sh=1,pw_len=2,output_shift=0,legacy_matrix_modulation=True)
    for name in ('flute','cello','oboe'):
        frontends[name]=dict(engine='eng1',excitation='periodic impulse',envelope='per-note A/R; D=1048576,S=536870911')
    for name in ('banjo','mandolin'):
        frontends[name]=dict(engine='eng1',rise_sh=5,pw_len=32,gap_len=0,n_pulse=0,envelope='ADSR',a_step=89478486,d_step=0,s_level=2147483647,r_step=74566,body_q27=R.body_coeffs(name),body_source=f'params.Patch({name}).sos')
    frontends['drums']=dict(engine='eng1',rise_sh=3,pw_len=8,gap_len=0,n_pulse=0,envelope='ADSR',a_step=89478486,d_step=0,s_level=2147483647,r_step=74566,body='passthrough')
    for name in frontends:
        frontends[name]['modulation']='none' if name in ('piano','piano_abc','drums') else ('matrix aftertouch' if name=='guitar' else 'P1T1 aftertouch')
    return frontends


def resource_sources():
    sources=[Path(__file__),Path(__file__).with_name('matrix_resources.py'),Path(__file__).with_name('pitch_tables.py'),Path(__file__).with_name('pitch_tables.json'),Path(__file__).with_name('sustain_profiles.json'),ROOT/'python_monotor/modal_sim/eng1_audition.py',
        ROOT/'python_monotor/modal_sim/guitar_refit_experiments.py',
        ROOT/'rtl/router/tools/sustain_resources.py',ROOT/'python_monotor/modal_sim/pitch_linear.py',
        ROOT/'python_monotor/modal_sim/router_eng1.py',ROOT/'python_monotor/modal_sim/params.py',
        ROOT/'python_monotor/modal_sim/eng1_rtl.py',ROOT/'python_monotor/results/params/guitar_manifest.json']
    sources += [Path(__file__).parent/'coefficients'/f'eng0_{name}.bin' for name in ('piano','guitar')]
    sources += [ROOT/'python_monotor/matrix_sim'/name for name in ['piano_coeff_scaled.txt','guitar_coeff_scaled.txt','guitar_param.txt','piano_coeff_gen.py','guitar_coeff_gen.py','guitar_param_gen.py']]
    sources += [ROOT/f'python_monotor/results/params/{name}_{suffix}' for name in ('piano','guitar','banjo','mandolin')
                for suffix in ('coeff.mem','coeffindex.json')]
    sources += [ROOT/f'python_monotor/results/params/{name}_sustain.npz' for name in SUSTAINED]
    sources += [ROOT/f'python_monotor/results/params/{name}_body.npz' for name in ('banjo','mandolin')]
    sources += [ROOT/'python_monotor/fft_analysis/core.py',ROOT/'rtl/router/routers/body_router.sv']
    sources += [ROOT/'rtl/router/routers/exc_router.sv',ROOT/'rtl/router/parts/excitation.sv',
                ROOT/'rtl/router/parts/trumpet_excitation.sv',ROOT/'rtl/router/pkg/trumpet_excitation_pkg.sv',
                Path(__file__).with_name('trumpet_excitation_rom.py'),
                Path(__file__).parent/'performance/trumpet_excitation.json']
    sources += [ROOT/'python_monotor/modal_sim/trumpet_lip.py',ROOT/'rtl/router/pkg/router_pkg.sv',ROOT/'rtl/router/routers/mod_router.sv',ROOT/'rtl/router/parts/modulation1.sv',ROOT/'rtl/router/parts/modulation0.sv',ROOT/'rtl/config_pkg.sv',ROOT/'rtl/midi/midi_instrument_map.sv']
    sources += [ROOT/f'python_monotor/results/params/guitar_{suffix}.npz'
                for suffix in ('partials','gammascale','body')]
    sources += [ROOT/'python_monotor/modal_sim/drum_coefficients.py',ROOT/'python_monotor/modal_sim/drumkit.py',ROOT/'python_monotor/fft_analysis/percussion.py',ROOT/'python_monotor/results/params/drums.npz',ROOT/'sim/fit_drum_noise.py',ROOT/'rtl/router/routers/env_router.sv']
    return sources


def generate(out, notes=None, banked=True):
    out=Path(out);out.mkdir(parents=True,exist_ok=True)
    if notes is not None:raise ValueError('A shared MIDI list cannot represent per-instrument ranges; use NOTE_RANGES')
    if not banked:raise ValueError('The production layout requires 32 notes per instrument')
    note_count=32
    note_maps={name:list(range(lo,hi+1)) for name,(lo,hi) in NOTE_RANGES.items()}
    note_maps['drums']=list(DRUM_GM_NOTES)
    files={};entries=[]
    for name, ident in INSTRUMENTS.items():
        data=bytearray()
        for slot,midi in enumerate(note_maps[name]):
            row=make_note(name,midi)
            # Validate both A and B using the same decoder-independent contract.
            if name not in ('piano','guitar','drums'):
                words=np.frombuffer(row['data'],dtype='>i4').astype(np.int64).reshape(64,16)
                table=R.Eng1Coeffs(words[:,0],words[:,1],words[:,2],row['modes'])
                if abc_record(table) != row['data']:raise ValueError('record/P1T1 layout mismatch')
            payload=bytearray(row['data'])
            profile=((1<<80)|(int(row['period'])<<64)|(row['a_step']<<32)|row['r_step']) if name in SUSTAINED else 0
            for mode,value in enumerate([(profile>>64)&0x1ffff,(profile>>32)&0xffffffff,profile&0xffffffff]):
                struct.pack_into('>I',payload,mode*64+28,value)
            row['data']=bytes(payload)
            row['coeff_sha256']=hashlib.sha256(row['data']).hexdigest()
            data.extend(row['data'])
            entries.append(dict({k:v for k,v in row.items() if k!='data'},slot=slot,
                                offset=ident*note_count*4096+slot*4096))
        if name=='drums':data.extend(bytes((note_count-len(DRUM_GM_NOTES))*4096))
        engine='eng0' if name in ('piano','guitar') else 'eng1'
        path=out/f'{name}_{engine}.bin';path.write_bytes(data);files[ident]=path
        path.with_suffix('.mem').write_text(''.join(f'{v:02X}\n' for v in data))
        print('exported',name,len(note_maps[name]),'notes',len(data),'bytes',flush=True)
    base,capacity=board_layout()
    image,regions=pack(files,note_count*4096,base,capacity,control_profiles=True)
    control_offset=len(image)
    image+=control_page()
    if base+len(image)>min(capacity,1<<24):raise ValueError('control page exceeds Flash bounds')
    (out/'resources.bin').write_bytes(image)
    (out/'resources.mem').write_text(''.join(f'{v:02X}\n' for v in image))
    frontends=frontend_configs()
    sources=resource_sources()
    manifest=dict(schema=5,control_page=dict(offset=control_offset,bytes=4096,ratio_word=0,sine_word=512,depth_word=768),format='instrument-indexed eng0 matrix + eng1 ABC/P1T1',resource_fs=48000,
        flash_base=base,flash_bytes=capacity,image_flash_address=base,image_bytes=len(image),
        image_sha256=hashlib.sha256(image).hexdigest(),notes=note_count,note_maps=note_maps,
        note_ranges={name:dict(instrument=INSTRUMENTS[name],first=lo,last=hi,count=32,
            low=list(range(lo,lo+16)),high=list(range(lo+16,hi+1))) for name,(lo,hi) in NOTE_RANGES.items()},
        note_banks=1,default_bank=0,first_midi=None,
        resource_mask=sum(1<<i for i in INSTRUMENTS.values()),pcm_headroom_bits=0,
        table_bytes=note_count*4096,storage_modes=64,active_modes_limit=64,eng1_active_modes_limit=48,record_bytes=64,
        record_formats={
            'eng0 matrix':dict(words=['a11 Q28','a12 Q30','a21 Q23','a22 Q28','gq Q32','gv Q34','wo Q29'],reserved_words=[],profile_word=7,profile_modes=[0,1,2]),
            'eng1 ABC/P1T1':dict(words=['G signed26 Q24','a1 signed26 Q24','a2 unsigned24'],reserved_words=[3,4,5,6],profile_word=7,profile_modes=[0,1,2],pitch_tag=P.TAG)},
        regions=regions,entries=entries,
        frontends=frontends,firmware_flash_address=0,bulk_erase_between_files=False,
        source_hashes={str(p.relative_to(ROOT)):digest(p) for p in sources})
    manifest['validation_status']='Generated production twelve-instrument bank; run sim/check_production_stability.py and RTL regressions; not board programmed'
    manifest['eng1_drum_modes']=52
    manifest['record_formats']['eng1 drum ABC/noise']=dict(modal_slots=list(range(48)),noise_pairs=[[48,49],[50,51]],reserved_slots=list(range(52,64)),noise_words=['seed u32','initial Q24','decay Q24','alpha_lo Q24','alpha_hi Q24','gain Q16','reserved'],modulation='none')
    manifest['note_ranges']['drums']=dict(instrument=7,count=6,notes=list(DRUM_GM_NOTES),low=list(DRUM_GM_NOTES),high=list(DRUM_GM_NOTES),reserved_slots=list(range(6,32)))
    manifest['gain_policy']='envelope then sum; instrument Q12 trim; body/reverb; count-gated left shift; no per-note gain'
    gain_source=(ROOT/'rtl/router/pkg/router_pkg.sv').read_text()
    gains={name:int(value) for name,value in re.findall(r"INST_(\w+):\s*return 16'sd(\d+)",gain_source)}
    manifest['instrument_gain_q12']={str(ident):gains[name.upper()] for name,ident in INSTRUMENTS.items()}
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
