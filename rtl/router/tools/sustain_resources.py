#!/usr/bin/env python3
"""Generate eng1 ABC images and matching per-note drive/envelope profiles.

Requires numpy/scipy. Retuning from a different recorded MIDI is opt-in and recorded
in the manifest. Catalog profiles do not enable RESOURCE_MASK or burn Flash.
"""
from pathlib import Path
from typing import TypedDict
import argparse,hashlib,json,struct,sys
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
sys.path.insert(0,str(ROOT/'python'))
sys.path.insert(0,str(ROOT/'python/fft_analysis'))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import router_eng1 as model
from pitch_tables import control_page,with_profile
import pitch_linear
from sustain_engine import SustainPatch
INST={'flute':2,'trumpet':3,'cello':4,'violin':5,'oboe':6}
FS=48000;DEPTH=64;ENV=(1<<31)-1

class NoteResource(TypedDict):
    instrument: int
    name: str
    midi: int
    source_midi: int
    source_dynamic: str
    retuned: bool
    modes: int
    period: int
    a_step: int
    r_step: int
    attack_s: float
    release_full_scale_s: float
    coeff_sha256: str
    data: bytes


def make_note(name: str, midi: int, allow_retune: bool) -> NoteResource | None:
    patch=SustainPatch(name)
    selected=patch._pick_key(midi,'forte')
    if selected[0]!=midi and not allow_retune:
        raise ValueError(f'{name} MIDI{midi}: missing recording (nearest {selected[0]}); use --allow-retune explicitly')
    try:t=model.build_b_table(name,midi,'forte')
    except ValueError:return None
    if not t.n_modes:return None
    period=t.drive_period
    if period is None or not 2<=period<=65535:
        raise ValueError(f'{name} MIDI{midi}: invalid sustained drive period {period}')
    attack=max(float(t.attack_s or .02),.003);release=max(float(t.release_s or .05),.02)
    a=max(1,int(ENV/(attack*FS)));r=max(1,int(ENV/(release*FS)))
    words=[]
    modulation=pitch_linear.modulation_words(t)
    for mode in range(DEPTH):
        g,a1,a2=(int(t.G[mode]),int(t.a1[mode]),int(t.a2[mode])) if mode<t.n_modes else (0,0,0)
        words.extend([g,a1,a2,*([0]*5),*modulation[mode]])
    data=b''.join(struct.pack('>I',v&0xffffffff) for v in words)
    return NoteResource(instrument=INST[name],name=name,midi=midi,
        source_midi=int(selected[0]),source_dynamic=str(selected[1]),
        retuned=selected[0]!=midi,modes=int(t.n_modes),period=period,a_step=a,r_step=r,
        attack_s=attack,release_full_scale_s=release,
        coeff_sha256=hashlib.sha256(data).hexdigest(),data=data)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--catalog',action='store_true',help='generate profiles for MIDI0..127, no Flash image')
    ap.add_argument('--first-midi',type=int,default=48)
    ap.add_argument('--notes',type=int,default=32,choices=[16,32])
    ap.add_argument('--allow-retune',action='store_true')
    ap.add_argument('--profile-out',type=Path,help='write offline JSON profiles here (not an RTL package)')
    args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    notes=range(128) if args.catalog else range(args.first_midi,args.first_midi+args.notes)
    if min(notes)<0 or max(notes)>127:ap.error('MIDI range must be 0..127')
    entries: list[NoteResource]=[]
    for name in INST:
        for note in notes:
            row=make_note(name,note,args.allow_retune)
            if row is None:
                if not args.catalog:raise ValueError(f'{name} MIDI{note} has no usable modes')
                continue
            profile=(1<<80)|(int(row['period'])<<64)|(row['a_step']<<32)|row['r_step']
            row['data']=with_profile(row['data'],profile)
            row['coeff_sha256']=hashlib.sha256(row['data']).hexdigest()
            entries.append(row)
    if not args.catalog:
        size=args.notes*DEPTH*64;image=bytearray(b'\xff'*(12*size))
        for row in entries:
            offset=row['instrument']*size+(row['midi']-args.first_midi)*DEPTH*64
            image[offset:offset+DEPTH*64]=row['data']
        image+=control_page()
        (args.out/'sustain_flash.bin').write_bytes(image)
        (args.out/'sustain_flash.mem').write_text(''.join(f'{v:02X}\n' for v in image))
    manifest=dict(resource_fs=FS,storage_modes=DEPTH,active_modes_limit=48,allow_retune=args.allow_retune,
        a1_format='Q2.24',a1_frac=model.A1_FRAC,a1_bits=model.A1_BITS,
        record_bytes=64,record_words=16,coeff_words=['G','a1','a2'],
        pitch_format='P1T1',pitch_slope_frac=pitch_linear.SLOPE_FRAC,
        pitch_words={'8':'lower','9':'a1_nominal','10':'upper','13':'K','15':'P1T1 tag'},
        first_midi=None if args.catalog else args.first_midi,notes=None if args.catalog else args.notes,
        sources={name:hashlib.sha256((ROOT/f'FFT_results/params/{name}_sustain.npz').read_bytes()).hexdigest() for name in INST},
        entries=[{k:v for k,v in row.items() if k!='data'} for row in entries])
    (args.out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    if args.profile_out:
        profiles={str(row['instrument']*128+row['midi']):
            (1<<80)|(int(row['period'])<<64)|(row['a_step']<<32)|row['r_step'] for row in entries}
        args.profile_out.write_text(json.dumps(profiles,indent=2)+'\n')
    print(f'PASS sustain resources entries={len(entries)} retuned={sum(row["retuned"] for row in entries)} fs={FS}')
if __name__=='__main__':main()
