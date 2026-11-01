#!/usr/bin/env python3
"""Hinos Sentimentais track11 hymn excerpt, solo trumpet ENG1 comparison.

Uses first4 measures of the public-domain Converse hymn melody, not Fernando
Lopez's recording arrangement. Frozen production modal/envelope parameters.
"""
from pathlib import Path
import hashlib
import json
import math
import xml.etree.ElementTree as ET
import numpy as np
import soundfile as sf
from scipy.signal import butter,sosfilt,lfilter
import eng1_rtl as E
import router_eng1 as R
from sustain_engine import SustainPatch
from trumpet_excitation_experiment import LipExcitation

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'FFT_results/sim/eng1/hinos_sentimentais'
FS=48000;BPM=72;LEAD=.20;TAIL=1.0
XML=OUT/'source_what_a_friend.musicxml'
ALBUM='https://www.qobuz.com/ie-en/album/hinos-sentimentais-fernando-lopez/e58131rbp49sa'
SCORE='https://library.timelesstruths.org/music/What_a_Friend_We_Have_in_Jesus/'
CCB='https://www.superpartituras.com.br/hinario-ccb/-402--o-irmaos-a-deus-devemos'


def rms(y):return float(np.sqrt(np.mean(np.asarray(y)**2)))


def score_events():
    root=ET.parse(XML).getroot();part=root.find("part[@id='P1']")
    divisions=None;events=[];audit=[]
    for bar,measure in enumerate(part.findall('measure')[:4]):
        if measure.find('attributes/divisions') is not None:divisions=int(measure.findtext('attributes/divisions'))
        cursor=0;groups=[];previous=None
        for node in measure:
            if node.tag in ['backup','forward']:
                cursor+=(-1 if node.tag=='backup' else 1)*int(node.findtext('duration'));continue
            if node.tag!='note':continue
            chord=node.find('chord') is not None
            duration=int(node.findtext('duration','0'))
            if not chord:
                previous=dict(start=cursor,duration=duration,voice=node.findtext('voice','1'),pitches=[])
                groups.append(previous);cursor+=duration
            pitch=node.find('pitch')
            if pitch is not None:
                midi=12*(int(pitch.findtext('octave'))+1)+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[pitch.findtext('step')]+int(pitch.findtext('alter','0'))
                previous['pitches'].append(midi)
        selected=[g for g in groups if g['voice']=='1' and g['pitches']]
        assert max(g['start']+g['duration'] for g in selected)==4*divisions
        audit.append(dict(measure=bar+1,melody=[dict(beat=g['start']/divisions,midi=max(g['pitches']),beats=g['duration']/divisions) for g in selected]))
        for g in selected:
            beat=4*bar+g['start']/divisions;beats=g['duration']/divisions
            seconds=beats*60/BPM
            at_phrase_end=abs(beat+beats-8)<1e-8 or abs(beat+beats-16)<1e-8
            # Small separations and two explicit breaths; no added score notes.
            gate_duration=seconds-(.18 if at_phrase_end else min(.025,.05*seconds))
            events.append(dict(time=LEAD+beat*60/BPM,midi=max(g['pitches']),duration=gate_duration,
                               score_beats=beats,beat=beat,measure=bar+1,velocity=94 if beat%4<.01 else 86))
    assert len(events)==15 and min(e['midi'] for e in events)==60 and max(e['midi'] for e in events)==74
    return events,audit


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    events,audit=score_events()
    notes=sorted({e['midi'] for e in events})
    for m in range(min(notes),max(notes)+1):
        if len(notes)>=8:break
        if m not in notes:notes.append(m)
    notes=tuple(sorted(notes));assert len(notes)==8
    bank=E.ResourceBank.build('trumpet',notes)
    patch=SustainPatch('trumpet')
    resource_rows=[dict(midi=m,source_midi=patch._pick_key(m,'forte')[0],source_dynamic=patch._pick_key(m,'forte')[1],period=bank.notes[m].period,modes=bank.notes[m].coeffs.n_modes) for m in notes]
    n=round((LEAD+16*60/BPM+TAIL)*FS)
    random=np.random.default_rng(20261031).standard_normal((n,8))
    noise=sosfilt(butter(2,[500,10000],btype='bandpass',fs=FS,output='sos'),random,axis=0)
    noise/=np.sqrt(np.mean(noise**2,axis=0))[None,:]
    synths={name:E.Eng1Synth('trumpet',note_map=notes,resources=bank,stereo=False) for name in ['baseline','new_excitation']}
    synths['new_excitation'].excitation=LipExcitation([bank.notes[m].period for m in notes],shape=True,unstable=True,air=True,noise=noise)
    ons={};offs={}
    for e in events:
        ons.setdefault(round(e['time']*FS),[]).append(e)
        offs.setdefault(round((e['time']+e['duration'])*FS),[]).append(e['midi'])
    outputs={name:np.empty(n,dtype=np.int64) for name in synths};rails={name:0 for name in synths};pcm_rails=rails.copy()
    delta=np.zeros(8,dtype=np.int64)
    for i in range(n):
        for m in offs.get(i,[]):
            for s in synths.values():s.note_off(notes.index(m))
        for e in ons.get(i,[]):
            for s in synths.values():s.note_on(e['midi'],e['velocity'])
        for name,s in synths.items():
            frame=s.step(committed_delta=delta);s.trigger[:]=False;outputs[name][i]=frame.out
            rails[name]+=int(np.count_nonzero((s.core.y1==R.Y_MAX)|(s.core.y1==R.Y_MIN)))
            pcm_rails[name]+=int(frame.pcm[0] in [-32768,32767])
        if i and i%(FS*3)==0:print(f'{i/FS:.0f}/{n/FS:.2f}s',flush=True)
    assert not any(rails.values()) and not any(pcm_rails.values())
    signals={name:y.astype(float)/(1<<24)/8 for name,y in outputs.items()}
    active=slice(round(LEAD*FS),round((LEAD+16*60/BPM)*FS))
    envelope=np.sqrt(np.maximum(lfilter(np.ones(480)/480,[1.],signals['baseline']**2),0))
    breath=noise[:,0]*envelope*(outputs['baseline']!=0)
    breath*=rms(signals['baseline'][active])*10**(-36/20)/max(rms(breath[active]),1e-30)
    signals['new_excitation_breath']=signals['new_excitation']+breath
    target=min(.075,*[.88*rms(y[active])/max(abs(y).max(),1e-30) for y in signals.values()])
    results=[]
    for name,y in signals.items():
        gain=target/rms(y[active]);z=y*gain;z[-960:]*=np.linspace(1,0,960)
        path=OUT/f'hinos_oiirmaos_{name}.wav'
        sf.write(path,np.repeat(z[:,None],2,axis=1),FS,subtype='PCM_24')
        check,fs=sf.read(path,always_2d=True)
        assert fs==FS and check.shape==(n,2) and np.isfinite(check).all() and abs(check).max()<=.880001
        assert abs(20*math.log10(rms(check[active,0])/target))<.00002
        assert not np.any(check[:round(LEAD*FS)])
        np.save(OUT/f'{name}_raw.npy',y)
        results.append(dict(name=name,file=path.name,frames=n,seconds=n/FS,active_rms_dbfs=20*math.log10(rms(check[active,0])),peak_dbfs=20*math.log10(abs(check).max()),gain_db=20*math.log10(gain),
                            state_rail_hits=rails.get(name),native_mono_pcm_rail_samples=pcm_rails.get(name),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    summary=dict(title='Ó Irmãos, a Deus Devemos / What a Friend We Have in Jesus',album='Hinos Sentimentais — Fernando Lopez',album_track=11,composer='Charles Crozat Converse',
        scope='First4 measures, solo melody. Score-based audition, not transcription of Fernando Lopez arrangement, phrasing or ornaments.',album_url=ALBUM,score_url=SCORE,title_crosscheck_url=CCB,
        bpm=BPM,key='F major, concert pitch',measures=[1,4],lead_seconds=LEAD,tail_seconds=TAIL,events=events,score_audit=audit,resources=resource_rows,
        melody_extraction='P1 voice1 chord groups: highest pitch, duration inherited from voice anchor. Source chord duration sometimes omits dot despite dotted type; anchor duration agrees with CCB score preview.',
        model='Production ENG1 modal coefficients and original ADSR/release;8 fixed slots;no reverb;new excitation from trumpet_excitation_experiment.LipExcitation.',
        raw_saturation_checks=dict(state=rails,native_mono_pcm=pcm_rails),normalization='All3 active RMS matched, constant gain,peak<=.88,20ms file-end fade.',renders=results,
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),XML,ROOT/'python/modal_sim/trumpet_excitation_experiment.py',ROOT/'python/modal_sim/eng1_rtl.py',ROOT/'FFT_results/params/trumpet_sustain.npz']})
    (OUT/'manifest.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
    (OUT/'excerpt_events.json').write_text(json.dumps(events,indent=2)+'\n')
    lines=['# Hinos Sentimentais: solo trumpet excerpt','','Selected track11: Ó Irmãos, a Deus Devemos / What a Friend We Have in Jesus (Charles C. Converse).',
           '',summary['scope'],'',f'First4 bars,15 notes,F major,C4..D5,{BPM}BPM,{n/FS:.2f}s. Same melody and original envelope across variants.',
           '',f'[Album]({ALBUM}) / [Public score]({SCORE}) / [CCB title/score]({CCB})','','| Candidate | Audio |','|---|---|']
    for r in results:lines.append(f'| {r["name"]} | [play]({r["file"]}) |')
    lines+=['','New excitation: asymmetric bipolar pulse, transient cycle/amplitude jitter and slight filtered noise before modal bank; optional parallel breath variant.',
            '',summary['melody_extraction'],'','[Manifest](manifest.json)','','Run: `python python/modal_sim/trumpet_hinos_excerpt.py`']
    (OUT/'README.md').write_text('\n'.join(lines)+'\n')
    print('PASS Hinos excerpt',[(r['name'],round(r['active_rms_dbfs'],2),round(r['peak_dbfs'],2)) for r in results],flush=True)


if __name__=='__main__':main()
