#!/usr/bin/env python3
"""Fail closed on stale/wrong-format board performance resources; no Flash I/O."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
import router_eng1 as R


def check(directory, deployment=True):
    directory=Path(directory)
    m=json.loads((directory/'resources.json').read_text())
    data=(directory/'resources.bin').read_bytes()
    def require(ok,msg):
        if not ok:raise ValueError(msg)
    require(m['format']=='ENG1 ABC Q24 + P1T1','wrong format')
    require(len(data)==m['image_bytes']==6*m['table_bytes'],'wrong region stride/image length')
    require(hashlib.sha256(data).hexdigest()==m['image_sha256'],'image hash mismatch')
    require(m['resource_mask']==0x2b and m['table_bytes']==m['notes']*4096,'wrong instrument mask/stride')
    require(bytes(int(x,16) for x in (directory/'resources.mem').read_text().split())==data,'MEM/BIN mismatch')
    for source,digest in m['source_hashes'].items():
        require(hashlib.sha256((ROOT/source).read_bytes()).hexdigest()==digest,f'stale resource source: {source}')
    count=0
    profiles=(ROOT/'rtl/router/pkg/sustain_profiles_pkg.sv').read_text()
    profile_words={int(key):int(value,16) for key,value in
                   re.findall(r"11'd(\d+): lookup=81'h([0-9a-f]+)",profiles)}
    for entry in m['entries']:
        off=entry['offset'];note=data[off:off+4096]
        require(off==entry['instrument']*m['table_bytes']+entry['slot']*4096,'double-offset/slot stride')
        require(entry['midi']==m['note_map'][entry['slot']],'note map mismatch')
        require(hashlib.sha256(note).hexdigest()==entry['coeff_sha256'],'note resource hash mismatch')
        if entry['name'] in ('trumpet','violin'):
            expected=(1<<80)|(entry['period']<<64)|(entry['a_step']<<32)|entry['r_step']
            require(profile_words.get(entry['instrument']*128+entry['midi'])==expected,
                    'Flash coefficients/profile ROM identity mismatch')
        if entry['name']=='guitar':
            path=ROOT/entry['source_file']
            require(hashlib.sha256(path.read_bytes()).hexdigest()==entry['source_recording_sha256'],'guitar recording changed')
            require(entry['selection']=='F: refit_amplitude_envelope','wrong guitar selection')
        for mode in range(64):
            words=struct.unpack_from('>16i',note,mode*64)
            g,a1,a2=words[:3]
            require(words[3:8]==(0,)*5 and words[15]==0x50315431,'matrix/ABC or P1T1 ABI mismatch')
            require(-(1<<25)<=g<1<<25 and -(1<<25)<=a1<1<<25 and 0<=a2<1<<24,'coefficient bit width')
            if mode<entry['modes']:
                require(a2>0 and (1<<24)+a1+a2>0 and (1<<24)-a1+a2>0,'unstable pole')
            else:require((g,a1,a2)==(0,0,0),'nonzero padding')
            require(words[9]==a1 and words[8]<=a1<=words[10],'wrong a1 metadata/bounds')
            count+=1
    require(count==4*m['notes']*64,'missing records')
    for ident in (2,4):
        require(data[ident*m['table_bytes']:(ident+1)*m['table_bytes']]==b'\xff'*m['table_bytes'],'uninstalled region is not erased')
    require(R.body_coeffs('piano')==m['frontends']['piano']['body_q27'],'piano body mismatch')
    require(R.body_coeffs('guitar')==m['frontends']['guitar']['body_q27'],'guitar body mismatch')
    if deployment:
        for filename in ('instrument_board_top.sv','instrument_system.sv'):
            source=(ROOT/'rtl/platform/tang_mega_138k_pro'/filename).read_text()
            mask=re.search(r"RESOURCE_MASK=10'b([01_]+)",source)
            require(mask is not None,'missing board resource mask')
            board_mask=int(mask[1].replace('_',''),2)
            headroom=re.search(r'PCM_HEADROOM_BITS=(-?\d+)',source)
            require(headroom is not None,'missing board PCM headroom')
            # Preserve the current piano/guitar audition profile alongside the full resource profile.
            require((board_mask,int(headroom[1])) in ((m['resource_mask'],m['pcm_headroom_bits']),(0x03,0)),
                    'board resource mask/PCM profile mismatch')
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
