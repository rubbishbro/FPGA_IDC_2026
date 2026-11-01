#!/usr/bin/env python3
"""Export the 4 KiB Flash control page; no RTL case ROM generation."""
from pathlib import Path
import json,struct

def control_page():
    tables=json.loads(Path(__file__).with_suffix('.json').read_text())
    words=[0]*1024
    for name,base in [('pitch_ratio',0),('pitch_sine',512),('pitch_depth',768)]:
        values=tables[name];words[base:base+len(values)]=values
    return struct.pack('>1024I',*words)

def with_profile(payload, profile):
    data=bytearray(payload)
    values=[(profile>>64)&0x1ffff,(profile>>32)&0xffffffff,profile&0xffffffff]
    for mode,value in enumerate(values):struct.pack_into('>I',data,mode*64+28,value)
    return bytes(data)

if __name__=='__main__':
    Path(__file__).with_suffix('.bin').write_bytes(control_page())
