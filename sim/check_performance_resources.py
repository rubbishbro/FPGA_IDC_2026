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
    require(m['schema']==5,'Flash control parameters require resource schema 5')
    require(m['format']=='instrument-indexed eng0 matrix + eng1 ABC/P1T1','wrong format')
    require(m['active_modes_limit']==64 and m['eng1_active_modes_limit']==48,'wrong engine mode limits')
    require(m['record_formats']['eng0 matrix']['reserved_words']==[] and
            m['record_formats']['eng1 ABC/P1T1']['reserved_words']==[3,4,5,6],'mixed-format ABI metadata mismatch')
    require(m['flash_base']==0x800000 and m['image_flash_address']==m['flash_base'],
            'wrong Flash resource base')
    require(m['firmware_flash_address']==0 and m['bulk_erase_between_files'] is False,
            'resource BIN must not include/erase firmware')
    ranges={'piano':(21,52),'piano_abc':(21,52),'guitar':(40,71),'guitar_abc':(40,71),'trumpet':(51,82),'violin':(55,86)}
    require(m['notes']==32 and m['note_banks']==1 and m['default_bank']==0,'wrong bank layout')
    require(set(m['note_maps'])==set(ranges),'missing instrument note maps')
    for name,(first,last) in ranges.items():
        require(m['note_maps'][name]==list(range(first,last+1)),f'wrong range: {name}')
        row=m['note_ranges'][name]
        require(row['instrument']==INSTRUMENT_IDS[name] and row['first']==first and row['last']==last and
                row['count']==32 and row['low']==list(range(first,first+16)) and row['high']==list(range(first+16,last+1)),f'wrong bank metadata: {name}')
    require(len(data)==m['image_bytes']==(max(INSTRUMENTS)+1)*m['table_bytes']+4096,'wrong region stride/image length')
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
    page=m['control_page']
    require(page['offset']==12*m['table_bytes'] and page['bytes']==4096,'wrong control page address')
    tables=json.loads((ROOT/'rtl/router/tools/pitch_tables.json').read_text())
    expected_page=[0]*1024
    for key,base in [('pitch_ratio',0),('pitch_sine',512),('pitch_depth',768)]:
        expected_page[base:base+len(tables[key])]=tables[key]
    require(data[page['offset']:]==struct.pack('>1024I',*expected_page),'control table payload mismatch')
    require(m['pcm_headroom_bits']==3,'unexpected PCM headroom')
    count=0
    for entry in m['entries']:
        matrix=entry['instrument'] in MATRIX_IDS
        require((entry.get('format')=='eng0 matrix')==matrix,
                'instrument/engine format mismatch')
        require((entry['modes']==MATRIX_MODES[entry['name']]) if matrix
                else (1<=entry['modes']<=48),'wrong active mode count')
        off=entry['offset'];note=data[off:off+4096]
        require(off==entry['instrument']*m['table_bytes']+entry['slot']*4096,'double-offset/slot stride')
        require(entry['midi']==m['note_maps'][entry['name']][entry['slot']],'note map mismatch')
        require(hashlib.sha256(note).hexdigest()==entry['coeff_sha256'],'note resource hash mismatch')
        actual_profile=((struct.unpack_from('>I',note,28)[0]&0x1ffff)<<64)|(struct.unpack_from('>I',note,92)[0]<<32)|struct.unpack_from('>I',note,156)[0]
        expected=((1<<80)|(entry['period']<<64)|(entry['a_step']<<32)|entry['r_step']) if entry['name'] in ('trumpet','violin') else 0
        require(actual_profile==expected,'Flash profile payload mismatch')
        if entry['name']=='guitar_abc':
            path=ROOT/entry['source_file']
            require(hashlib.sha256(path.read_bytes()).hexdigest()==entry['source_recording_sha256'],'guitar recording changed')
            require(entry['selection']=='F: refit_amplitude_envelope','wrong guitar selection')
        for mode in range(64):
            words=struct.unpack_from('>16i',note,mode*64)
            if matrix:
                require(mode<3 or words[7]==0,'matrix profile padding')
                count+=1
                continue
            g,a1,a2=words[:3]
            require(words[3:7]==(0,)*4 and (mode<3 or words[7]==0) and words[15]==0x50315431,'matrix/ABC or P1T1 ABI mismatch')
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
        require('.INSTRUMENT_NOTE_RANGES(NOTE_BANKS)' in
                (ROOT/'rtl/platform/tang_mega_138k_pro/instrument_system.sv').read_text(),'per-instrument ranges disabled')
        pkg=(ROOT/'rtl/router/pkg/router_pkg.sv').read_text()
        for token,value in [('INST_PIANO,INST_PIANO_ABC',21),('INST_GUITAR,INST_GUITAR_ABC',40),('INST_TRUMPET',51),('INST_MANDOLIN,INST_VIOLIN',55)]:
            require(f'{token}:return {value};' in pkg,'RTL note range mismatch')
        require(m['flash_base']==0x800000 and m['flash_base']+len(data)<=min(m['flash_bytes'],1<<24),'Flash bounds')
    return dict(passed=True,notes=m['notes'],records=count,image_bytes=len(data),
                flash_base=m['flash_base'],sha256=m['image_sha256'])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,default=ROOT/'rtl/router/tools/performance')
    args=parser.parse_args()
    print(json.dumps(check(args.directory),ensure_ascii=False))
