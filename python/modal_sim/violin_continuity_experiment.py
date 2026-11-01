#!/usr/bin/env python3
"""Diagnose violin gaps and compare release-only versus bowed articulation.

Frozen production modal coefficients/excitation. Bow envelope and scheduling are
audition candidates, not changes to production RTL or MIDI behavior.
"""
from pathlib import Path
import hashlib
import json
import math
import os
import numpy as np
import soundfile as sf
from scipy.signal import lfilter
import eng1_rtl as E
import router_eng1 as R
import trumpet_hinos_excerpt as H

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'FFT_results/sim/eng1/violin_continuity'
BASE=H.OUT/'violin'
FS=48000


class BowEnvelope(E.Envelope):
    """20ms linear attack, full sustain,80ms release from full level."""
    def __init__(self,slots):
        super().__init__([math.ceil(0x7fffffff/(FS*.020))]*slots,
                         [math.ceil(0x7fffffff/(FS*.080))]*slots)

    def step(self,gate,trigger,clear):
        for s in range(self.slots):
            old=int(self.level[s])
            if clear[s]:
                self.level[s]=0;self.state[s]=self.IDLE;self.dead[s]=True
            elif trigger[s] or (gate[s] and not self.previous_gate[s]):
                self.level[s]=0;self.state[s]=self.ATTACK;self.dead[s]=False
            elif not gate[s]:
                self.level[s]=max(0,old-int(self.release[s]));self.dead[s]=old<=self.release[s]
                self.state[s]=self.IDLE if self.dead[s] else self.RELEASE
            else:
                self.dead[s]=False
                if self.state[s]==self.ATTACK:
                    self.level[s]=min(0x7fffffff,old+int(self.attack[s]))
                    if self.level[s]==0x7fffffff:self.state[s]=self.SUSTAIN
                elif self.state[s]==self.SUSTAIN:self.level[s]=0x7fffffff
                else:self.state[s]=self.ATTACK
        self.previous_gate[:]=gate
        return self.level.copy()


def zero_gaps(y):
    z=y==0;edges=np.diff(np.r_[False,z,False].astype(int))
    starts=np.flatnonzero(edges==1);ends=np.flatnonzero(edges==-1)
    return [dict(start=a/FS,end=b/FS,ms=(b-a)/48) for a,b in zip(starts,ends)
            if b-a>=48 and a>.3*FS and b<13.5*FS]


def schedule(events,legato):
    ons={};offs={};updates={};records=[]
    for i,e in enumerate(events):
        before=events[i-1] if i else None
        after=events[i+1] if i+1<len(events) else None
        phrase_end=abs(e['beat']+e['score_beats']-8)<1e-8 or abs(e['beat']+e['score_beats']-16)<1e-8
        previous_phrase_end=bool(before and (abs(before['beat']+before['score_beats']-8)<1e-8))
        carry=bool(legato and before and before['midi']==e['midi'] and not previous_phrase_end)
        on=round(e['time']*FS)
        if carry:updates.setdefault(on,[]).append(e)
        else:ons.setdefault(on,[]).append(e)
        hold=bool(legato and after and after['midi']==e['midi'] and not phrase_end)
        off=e['time']+e['duration']
        if legato and after and not phrase_end:off=after['time']
        if not hold:offs.setdefault(round(off*FS),[]).append(e['midi'])
        records.append(dict(midi=e['midi'],on=e['time'],off=None if hold else off,carried_same_pitch=carry))
    return ons,offs,updates,records


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    meta=json.loads((BASE/'baseline.json').read_text());events=meta['events']
    notes=tuple(row['midi'] for row in meta['resources'])
    bank=E.ResourceBank.build('violin',notes)
    previous,fs=sf.read(BASE/meta['file'],always_2d=True);assert fs==FS
    n=len(previous);signals={'baseline':previous[:,0]};synths={};schedules={};traces={};rails={};pcm_rails={}
    for name in ['release_only','bow_legato']:
        s=E.Eng1Synth('violin',note_map=notes,resources=bank,stereo=False)
        if name=='release_only':
            # Production sustain=1/4;80ms slope is calibrated from that level.
            s.envelope.release[:]=math.ceil(0x1fffffff/(FS*.080))
        else:s.envelope=BowEnvelope(len(notes))
        synths[name]=s;schedules[name]=schedule(events,name=='bow_legato')
        signals[name]=np.empty(n);traces[name]=np.empty((n,8),dtype=np.int64);rails[name]=pcm_rails[name]=0
    delta=np.zeros(8,dtype=np.int64)
    for i in range(n):
        for name,s in synths.items():
            ons,offs,updates,_=schedules[name]
            for m in offs.get(i,[]):s.note_off(notes.index(m))
            for e in ons.get(i,[]):s.note_on(e['midi'],e['velocity'])
            for e in updates.get(i,[]):
                # Continuous bow on repeated pitch: change drive level, preserve
                # envelope, resonator history and excitation phase.
                s.level[notes.index(e['midi'])]=(e['velocity']*255+63)//127
            f=s.step(committed_delta=delta);s.trigger[:]=False
            signals[name][i]=f.out/(1<<24)/8;traces[name][i]=f.emap
            rails[name]+=int(np.count_nonzero((s.core.y1==R.Y_MAX)|(s.core.y1==R.Y_MIN)))
            pcm_rails[name]+=int(f.pcm[0] in [-32768,32767])
        if i and i%(FS*3)==0:print(f'{i/FS:.0f}/{n/FS:.2f}s',flush=True)
    assert not any(rails.values()) and not any(pcm_rails.values())
    active=slice(round(H.LEAD*FS),round((H.LEAD+16*60/H.BPM)*FS))
    rms=lambda y:float(np.sqrt(np.mean(y*y)))
    target=min(.075,*[.88*rms(y[active])/max(abs(y).max(),1e-30) for y in signals.values()])
    rows={}
    for name,y in signals.items():
        gain=target/rms(y[active]);z=y*gain;z[-960:]*=np.linspace(1,0,960)
        path=OUT/f'hinos_violin_{name}.wav';sf.write(path,np.repeat(z[:,None],2,axis=1),FS,subtype='PCM_24')
        check,fs=sf.read(path,always_2d=True)
        assert fs==FS and check.shape==(n,2) and np.isfinite(check).all() and abs(check).max()<=.880001
        assert abs(20*math.log10(rms(check[active,0])/target))<.00002
        rows[name]=dict(file=path.name,frames=n,active_rms_dbfs=20*math.log10(rms(check[active,0])),peak_dbfs=20*math.log10(abs(check).max()),
            gain_db=20*math.log10(gain),state_rail_hits=rails.get(name,0),native_pcm_rail_samples=pcm_rails.get(name,0),
            digital_zero_gaps=zero_gaps(check[:,0]),sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        np.save(OUT/f'{name}_wave.npy',y)
    summary=dict(instrument='violin',cause='Trumpet-style21..25ms gate gaps plus5..13ms release from1/4 sustain; slow41..320ms attack, peak-to1/4 decay, same-pitch retrigger clears.',
        variants=rows,release_only='Original score gaps, original attack/decay/sustain, only release slope80ms from1/4 sustain.',
        bow_legato='20ms attack,full sustain,no decay,80ms release; adjacent different pitches have zero scheduled gate gap with release overlap; repeated pitches continue bow/history and update velocity;180ms phrase breath retained.',
        caveat='Bow legato merges same-pitch rearticulations into continuous bow; not an implemented MIDI/RTL legato policy. Resonator ring-up remains. It is a listening candidate.',
        modal_excitation='Original production violin G/a1/a2 and periodic excitation unchanged; no added noise/reverb.',
        schedules={k:v[3] for k,v in schedules.items()},normalization='Matched active RMS,constant gain,peak<=.88,20ms final fade.',
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
            [Path(__file__),BASE/'baseline.json',BASE/meta['file'],Path(E.__file__),ROOT/'FFT_results/params/violin_sustain.npz']})
    (OUT/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    os.environ.setdefault('MPLCONFIGDIR',str(OUT/'mpl'))
    import matplotlib;matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axes=plt.subplots(1,2,figsize=(12,4))
    for name,row in rows.items():
        y,fs=sf.read(OUT/row['file']);env=np.sqrt(lfilter(np.ones(240)/240,[1.],y[:,0]**2))
        for ax,(a,b) in zip(axes,[(1.35,1.65),(2.65,3.95)]):
            start,end=round(a*FS),round(b*FS);ax.plot(np.arange(start,end)/FS,20*np.log10(np.maximum(env[start:end],1e-8)),label=name)
    axes[0].axvline(1.45,color='gray',linestyle='--');axes[0].set(title='Repeated C5 at1.45s',xlabel='Time(s)',ylabel='5ms RMS(dBFS)',ylim=(-85,-8))
    axes[1].axvline(3.533333,color='gray',linestyle='--');axes[1].set(title='Slow-attack A4/F4 and repeated F4',xlabel='Time(s)',ylabel='5ms RMS(dBFS)',ylim=(-85,-8))
    for ax in axes:ax.grid(alpha=.2);ax.legend()
    fig.tight_layout();fig.savefig(OUT/'continuity.png',dpi=150);plt.close(fig)
    lines=['# Violin continuity diagnosis','',''+summary['cause'],'',summary['release_only'],'',summary['bow_legato'],'',summary['caveat'],'',
           '| Candidate | Audio |','|---|---|']
    for name,row in rows.items():lines.append(f'| {name} | [play]({row["file"]}) |')
    lines+=['','[Results](results.json)','','![Continuity](continuity.png)','','Run: `python python/modal_sim/violin_continuity_experiment.py`']
    (OUT/'README.md').write_text('\n'.join(lines)+'\n')
    print('PASS continuity candidates',[(name,len(row['digital_zero_gaps'])) for name,row in rows.items()],flush=True)


if __name__=='__main__':main()
