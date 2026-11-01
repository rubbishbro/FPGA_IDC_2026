#!/usr/bin/env python3
"""Fail closed on stale/wrong-format board performance resources; no Flash I/O."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
import router_eng1 as R

# Deployment identity is keyed by instrument ID, not by a free-form manifest
# name.  The router selects the engine from the ID, so matrix/ABC format and
# calibration must be checked against this table.
INSTRUMENTS={0:'piano',1:'guitar',3:'trumpet',5:'violin',10:'piano_abc',11:'guitar_abc'}
INSTRUMENT_IDS={name:ident for ident,name in INSTRUMENTS.items()}
MATRIX_IDS={0,1}
MATRIX_MODES={'piano':64,'guitar':20}
ENGINES={'piano':'eng0','guitar':'eng0','trumpet':'eng1','violin':'eng1',
         'piano_abc':'eng1','guitar_abc':'eng1'}
LEGACY_NOTES=(40,42,44,46,48,50,52,54,56,58,60,62,64,67,71,76)


def check(directory, deployment=True):
    directory=Path(directory)
    m=json.loads((directory/'resources.json').read_text())
    data=(directory/'resources.bin').read_bytes()
    def require(ok,msg):
        if not ok:raise ValueError(msg)
    require(m['format']=='instrument-indexed eng0 matrix + eng1 ABC/P1T1','wrong format')
    require(m['active_modes_limit']==64 and m['eng1_active_modes_limit']==48,'wrong engine mode limits')
    require(m['record_formats']['eng0 matrix']['reserved_words']==[7] and
            m['record_formats']['eng1 ABC/P1T1']['reserved_words']==[3,4,5,6,7],'mixed-format ABI metadata mismatch')
    require(m['flash_base']==0x800000 and m['image_flash_address']==m['flash_base'],
            'wrong Flash resource base')
    require(m['firmware_flash_address']==0 and m['bulk_erase_between_files'] is False,
            'resource BIN must not include/erase firmware')
    require(m['notes'] in (16,32) and len(m['note_map'])==m['notes'] and
            len(set(m['note_map']))==m['notes'] and min(m['note_map'])>=0 and
            max(m['note_map'])<=127,'invalid note map')
    if m['note_banks']:
        require(m['notes']==32 and m['first_midi'] is not None and
                tuple(m['note_map'])==tuple(range(m['first_midi'],m['first_midi']+32)),
                'invalid banked note map')
    else:
        require(tuple(m['note_map'])==LEGACY_NOTES,'wrong fixed 16-note map')
    require(len(data)==m['image_bytes']==(max(INSTRUMENTS)+1)*m['table_bytes'],'wrong region stride/image length')
    require(hashlib.sha256(data).hexdigest()==m['image_sha256'],'image hash mismatch')
    require(m['resource_mask']==0xc2b==sum(1<<i for i in INSTRUMENTS) and
            m['table_bytes']==m['notes']*4096,'wrong instrument mask/stride')
    require(bytes(int(x,16) for x in (directory/'resources.mem').read_text().split())==data,'MEM/BIN mismatch')
    for source,digest in m['source_hashes'].items():
        require(hashlib.sha256((ROOT/source).read_bytes()).hexdigest()==digest,f'stale resource source: {source}')
    # Exactly one row per (instrument, slot), and no free-form name may claim a
    # different engine than the ID the router uses.
    entries={}
    for entry in m['entries']:
        ident,name,slot=entry['instrument'],entry['name'],entry['slot']
        require(ident in INSTRUMENTS and name==INSTRUMENTS[ident],f'wrong instrument/name: {ident}/{name}')
        require(0<=slot<m['notes'],f'bad slot: {ident}/{slot}')
        require((ident,slot) not in entries,f'duplicate entry: {ident}/{slot}')
        entries[(ident,slot)]=entry
    require(set(entries)=={(i,s) for i in INSTRUMENTS for s in range(m['notes'])},
            'missing/extra instrument-slot entries')
    require(set(m['frontends'])==set(INSTRUMENTS.values()),'missing/extra frontends')
    for name,engine in ENGINES.items():
        require(m['frontends'][name]['engine']==engine,f'wrong frontend engine: {name}')
    regions={r['instrument']:r for r in m['regions']}
    require(len(m['regions'])==len(INSTRUMENTS) and set(regions)==set(INSTRUMENTS),
            'missing/extra region metadata')
    for ident in INSTRUMENTS:
        r=regions[ident]
        require(r['offset']==ident*m['table_bytes'] and r['bytes']==m['table_bytes'] and
                r['flash_address']==m['flash_base']+r['offset'],f'bad region address: {ident}')
        require(hashlib.sha256(data[r['offset']:r['offset']+r['bytes']]).hexdigest()==r['table_sha256'],
                f'region hash mismatch: {ident}')
    binding=m['gain_calibration'];gain_path=directory/binding['file']
    require(hashlib.sha256(gain_path.read_bytes()).hexdigest()==binding['sha256'],'stale gain calibration')
    gain=json.loads(gain_path.read_text())
    require(gain['resources_sha256']==m['image_sha256'],'gain/resource identity mismatch')
    require(gain['headroom']==binding['headroom']==m['pcm_headroom_bits']==3,'gain/headroom mismatch')
    required_gain_sources={
        'rtl/router/tools/calibrate_performance_gain.py','rtl/router/tools/performance_resources.py',
        'python/modal_sim/performance_chain.py','python/modal_sim/eng1_rtl.py',
        'python/modal_sim/router_eng1.py','python/modal_sim/eng1_audition.py',
        'rtl/router/pkg/modal_step_pkg.sv','rtl/router/pkg/router_pkg.sv',
        'rtl/router/routers/body_router.sv','rtl/router/routers/env_router.sv',
        'rtl/router/routers/exc_router.sv','rtl/router/parts/polyphony_gain.sv',
        'rtl/router/voice_router.sv',
        'rtl/platform/tang_mega_138k_pro/instrument_board_top.sv',
        'rtl/platform/tang_mega_138k_pro/instrument_system.sv'}
    require(required_gain_sources<=set(gain['source_hashes']),'missing calibration dependencies')
    for source,digest in gain['source_hashes'].items():
        require(hashlib.sha256((ROOT/source).read_bytes()).hexdigest()==digest,f'stale gain source: {source}')
    pkg=(ROOT/'rtl/router/pkg/performance_gain_pkg.sv').read_text()
    gains={int(k):int(v) for k,v in re.findall(r"11'd(\d+):return 20'd(\d+)",pkg)}
    require(set(gain['instruments'])==set(INSTRUMENTS.values()),'missing/extra calibrated instruments')
    for name,row in gain['instruments'].items():
        require(row['instrument']==INSTRUMENT_IDS[name],f'wrong gain instrument: {name}')
        require(set(map(int,row['note_gain_q12']))==set(m['note_map']),'incomplete pitch gain map')
        for note,value in row['note_gain_q12'].items():
            require(0<value<(1<<20),f'pitch gain outside Q12 signed20: {name}/{note}')
            require(gains.get(row['instrument']*128+int(note))==value,f'RTL gain mismatch: {name}/{note}')
    norm=gain['normalization_q12']
    require(norm==[4096]+[round(4096/math.sqrt(i)) for i in range(1,17)],
            'polyphony normalization is not 1/sqrt(N)')
    scales={int(k):int(v) for k,v in re.findall(r"5'd(\d+):return 13'd(\d+)",pkg)}
    require([scales.get(i) for i in range(17)]==norm,'polyphony gain LUT mismatch')
    if m['notes']==16:
        for name,ident in (('piano',0),('guitar',1)):
            original=(ROOT/f'rtl/router/tools/{name}_flash.bin').read_bytes()
            require(data[ident*m['table_bytes']:(ident+1)*m['table_bytes']]==
                    original[ident*m['table_bytes']:(ident+1)*m['table_bytes']],
                    f'legacy {name} matrix changed')
    count=0
    profiles=(ROOT/'rtl/router/pkg/sustain_profiles_pkg.sv').read_text()
    profile_words={int(key):int(value,16) for key,value in
                   re.findall(r"11'd(\d+): lookup=81'h([0-9a-f]+)",profiles)}
    for entry in m['entries']:
        matrix=entry['instrument'] in MATRIX_IDS
        require((entry.get('format')=='eng0 matrix')==matrix,
                'instrument/engine format mismatch')
        require((entry['modes']==MATRIX_MODES[entry['name']]) if matrix
                else (1<=entry['modes']<=48),'wrong active mode count')
        off=entry['offset'];note=data[off:off+4096]
        require(off==entry['instrument']*m['table_bytes']+entry['slot']*4096,'double-offset/slot stride')
        require(entry['midi']==m['note_map'][entry['slot']],'note map mismatch')
        require(hashlib.sha256(note).hexdigest()==entry['coeff_sha256'],'note resource hash mismatch')
        if entry['name'] in ('trumpet','violin'):
            expected=(1<<80)|(entry['period']<<64)|(entry['a_step']<<32)|entry['r_step']
            require(profile_words.get(entry['instrument']*128+entry['midi'])==expected,
                    'Flash coefficients/profile ROM identity mismatch')
        if entry['name']=='guitar_abc':
            path=ROOT/entry['source_file']
            require(hashlib.sha256(path.read_bytes()).hexdigest()==entry['source_recording_sha256'],'guitar recording changed')
            require(entry['selection']=='F: refit_amplitude_envelope','wrong guitar selection')
        for mode in range(64):
            words=struct.unpack_from('>16i',note,mode*64)
            if matrix:
                require(words[7]==0,'matrix reserved word')
                count+=1
                continue
            g,a1,a2=words[:3]
            require(words[3:8]==(0,)*5 and words[15]==0x50315431,'matrix/ABC or P1T1 ABI mismatch')
            require(-(1<<25)<=g<1<<25 and -(1<<25)<=a1<1<<25 and 0<=a2<1<<24,'coefficient bit width')
            if mode<entry['modes']:
                require(a2>0 and (1<<24)+a1+a2>0 and (1<<24)-a1+a2>0,'unstable pole')
            else:require((g,a1,a2)==(0,0,0),'nonzero padding')
            require(words[9]==a1 and words[8]<=a1<=words[10],'wrong a1 metadata/bounds')
            count+=1
    require(count==len(INSTRUMENTS)*m['notes']*64,'missing records')
    for ident in sorted(set(range(max(INSTRUMENTS)+1))-set(INSTRUMENTS)):
        require(data[ident*m['table_bytes']:(ident+1)*m['table_bytes']]==b'\xff'*m['table_bytes'],'uninstalled region is not erased')
    require(R.body_coeffs('piano')==m['frontends']['piano']['body_q27'],'piano body mismatch')
    require(R.body_coeffs('guitar')==m['frontends']['guitar']['body_q27'],'guitar body mismatch')
    require(R.body_coeffs('piano_abc')==m['frontends']['piano_abc']['body_q27'],'piano2 body mismatch')
    require(R.body_coeffs('guitar_abc')==m['frontends']['guitar_abc']['body_q27'],'guitar2 body mismatch')
    if deployment:
        for filename in ('instrument_board_top.sv','instrument_system.sv'):
            source=(ROOT/'rtl/platform/tang_mega_138k_pro'/filename).read_text()
            mask=re.search(r"RESOURCE_MASK=12'b([01_]+)",source)
            require(mask and int(mask[1].replace('_',''),2)==m['resource_mask'],'board resource mask mismatch')
            headroom=re.search(r'PCM_HEADROOM_BITS=(-?\d+)',source)
            require(headroom and int(headroom[1])==m['pcm_headroom_bits'],'board PCM headroom mismatch')
        source=(ROOT/'rtl/platform/tang_mega_138k_pro/instrument_board_top.sv').read_text()
        require(int(re.search(r'NOTE_BANKS=(\d+)',source)[1])==m['note_banks'],'bank mode mismatch')
        if not m['note_banks']:
            pkg=(ROOT/'rtl/router/pkg/router_pkg.sv').read_text()
            notes=[int(value) for _,value in re.findall(r'(\d+):return (\d+);',pkg)]
            require(notes==m['note_map'],'board default note map mismatch')
        else:require(int(re.search(r'FIRST_MIDI=(\d+)',source)[1])==m['first_midi'],'bank base mismatch')
        require(m['flash_base']==0x800000 and m['flash_base']+len(data)<=min(m['flash_bytes'],1<<24),'Flash bounds')
    return dict(passed=True,notes=m['notes'],records=count,image_bytes=len(data),
                flash_base=m['flash_base'],sha256=m['image_sha256'])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,default=ROOT/'rtl/router/tools/performance')
    args=parser.parse_args()
    print(json.dumps(check(args.directory),ensure_ascii=False))
