#!/usr/bin/env python3
"""Production B-instrument baseline on the existing four-bar hymn fixture."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import soundfile as sf
import eng1_rtl as E
import router_eng1 as R
import trumpet_hinos_excerpt as H
from sustain_engine import SustainPatch


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--instrument',choices=list(E.INSTRUMENTS),required=True)
    instrument=ap.parse_args().instrument
    out=H.OUT/instrument;out.mkdir(parents=True,exist_ok=True)
    events,audit=H.score_events();notes=sorted({e['midi'] for e in events})
    for m in range(min(notes),max(notes)+1):
        if len(notes)>=8:break
        if m not in notes:notes.append(m)
    notes=tuple(sorted(notes));bank=E.ResourceBank.build(instrument,notes)
    s=E.Eng1Synth(instrument,note_map=notes,resources=bank,stereo=False)
    fs=48000;n=round((H.LEAD+16*60/H.BPM+H.TAIL)*fs)
    ons={};offs={}
    for e in events:
        ons.setdefault(round(e['time']*fs),[]).append(e)
        offs.setdefault(round((e['time']+e['duration'])*fs),[]).append(e['midi'])
    raw=np.empty(n,dtype=np.int64);pcm=np.empty(n,dtype=np.int16);rails=0
    delta=np.zeros(8,dtype=np.int64)
    for i in range(n):
        for m in offs.get(i,[]):s.note_off(notes.index(m))
        for e in ons.get(i,[]):s.note_on(e['midi'],e['velocity'])
        f=s.step(committed_delta=delta);s.trigger[:]=False;raw[i]=f.out;pcm[i]=f.pcm[0]
        rails+=int(np.count_nonzero((s.core.y1==R.Y_MAX)|(s.core.y1==R.Y_MIN)))
        if i and i%(fs*3)==0:print(instrument,f'{i/fs:.0f}/{n/fs:.2f}s',flush=True)
    assert rails==0
    wave=raw.astype(float)/(1<<24)/8;active=slice(round(H.LEAD*fs),round((H.LEAD+16*60/H.BPM)*fs))
    rms=lambda y:float(np.sqrt(np.mean(y*y)))
    gain=min(.075/max(rms(wave[active]),1e-30),.88/max(abs(wave).max(),1e-30))
    listen=wave*gain;listen[-960:]*=np.linspace(1,0,960)
    path=out/f'hinos_{instrument}_baseline.wav'
    sf.write(path,np.repeat(listen[:,None],2,axis=1),fs,subtype='PCM_24')
    sf.write(out/f'hinos_{instrument}_native.wav',np.repeat(pcm[:,None],2,axis=1),fs,subtype='PCM_16')
    check,sr=sf.read(path,always_2d=True)
    assert sr==fs and check.shape==(n,2) and np.isfinite(check).all() and abs(check).max()<=.880001
    patch=SustainPatch(instrument)
    meta=dict(instrument=instrument,status='production baseline audition',title='Ó Irmãos, a Deus Devemos / What a Friend We Have in Jesus',
        scope='Same four-bar solo score fixture and note articulation as trumpet hymn audition; no trumpet-specific excitation changes.',
        bpm=H.BPM,events=events,score_audit=audit,frames=n,seconds=n/fs,sample_rate=fs,
        route='current production ENG1, original excitation/envelope, frozen G/a1/a2,48 active modes,no reverb',
        resources=[dict(midi=m,source_midi=patch._pick_key(m,'forte')[0],period=bank.notes[m].period,attack_step=bank.notes[m].a_step,release_step=bank.notes[m].r_step) for m in notes],
        state_rail_hits=rails,native_pcm_rail_samples=int(np.count_nonzero((pcm==-32768)|(pcm==32767))),
        listening_gain_db=20*np.log10(gain),active_rms_dbfs=20*np.log10(rms(check[active,0])),peak_dbfs=20*np.log10(abs(check).max()),
        file=path.name,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        source_hashes={str(p.relative_to(H.ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),H.XML,Path(E.__file__),H.ROOT/f'FFT_results/params/{instrument}_sustain.npz']})
    (out/'baseline.json').write_text(json.dumps(meta,indent=2,ensure_ascii=False)+'\n')
    print('PASS',instrument,'hymn, native rails',meta['native_pcm_rail_samples'],'state rails',rails,flush=True)


if __name__=='__main__':main()
