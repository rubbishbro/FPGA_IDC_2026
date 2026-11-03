"""Prepare private local browser assets from the workspace's recorded notes."""
import array
import ctypes as c
import ctypes.util
import json
import math
import pathlib
import re
import shutil
import sys
import wave

root=pathlib.Path(__file__).resolve().parents[3]
output=root/'web/midi-editor/assets/samples'
output.mkdir(parents=True,exist_ok=True)
class Info(c.Structure):
    _fields_=[('frames',c.c_longlong),('samplerate',c.c_int),('channels',c.c_int),('format',c.c_int),('sections',c.c_int),('seekable',c.c_int)]
lib=c.CDLL(ctypes.util.find_library('sndfile'))
lib.sf_open.argtypes=[c.c_char_p,c.c_int,c.POINTER(Info)];lib.sf_open.restype=c.c_void_p
lib.sf_readf_float.argtypes=[c.c_void_p,c.POINTER(c.c_float),c.c_longlong];lib.sf_readf_float.restype=c.c_longlong
lib.sf_close.argtypes=[c.c_void_p]
def pitch(text):
    m=re.fullmatch(r'([A-G])([s#b]?)(-?\d+)',text)
    if not m:return None
    n,acc,o=m.groups()
    return (int(o)+1)*12+{'C':0,'D':2,'E':4,'F':5,'G':7,'A':9,'B':11}[n]+({'s':1,'#':1,'b':-1}.get(acc,0))
def decode(file):
    info=Info();handle=lib.sf_open(str(file).encode(),0x10,c.byref(info))
    if not handle:raise RuntimeError(f'Cannot decode {file}')
    try:
        # Read enough for an attack and stable body, without decoding long tails.
        frames=min(info.frames,int(info.samplerate*5))
        buf=(c.c_float*(frames*info.channels))();count=lib.sf_readf_float(handle,buf,frames)
        samples=array.array('f');samples.frombytes(c.string_at(buf,count*info.channels*4))
    finally:lib.sf_close(handle)
    if info.channels>1:samples=array.array('f',(sum(samples[i:i+info.channels])/info.channels for i in range(0,len(samples),info.channels)))
    peak=max(map(abs,samples),default=0)
    if peak<.0001:raise RuntimeError(f'Silent sample {file}')
    block=max(1,info.samplerate//200);start=0
    for i in range(0,len(samples)-block,block):
        if math.sqrt(sum(x*x for x in samples[i:i+block])/block)>peak*.045:
            start=max(0,i-int(info.samplerate*.008));break
    return samples[start:start+int(info.samplerate*3)],info.samplerate,peak

instruments={}
for key,directory in [('piano','UprightPian'),('guitar','guitar'),('trumpet','trumpet'),('violin','violin'),('cello','cello'),('flute','flute'),('viola','viola'),('oboe','oboe'),('bass','double bass')]:
    choices={}
    for file in sorted((root/'music_resources'/directory).rglob('*')):
        if key=='piano':
            m=re.fullmatch(r'([A-G][s#b]?-?\d+)v([HL])',file.stem)
            if not m or file.suffix.lower()!='.flac':continue
            midi=pitch(m[1]);score=0 if m[2]=='L' else 1
        else:
            parts=file.stem.split('_')
            if file.suffix.lower()!='.mp3' or len(parts)!=5 or parts[4] not in ('normal','arco-normal'):continue
            midi=pitch(parts[1]);duration={'025':.25,'05':.5,'1':1,'15':1.5,'long':3,'very-long':5}.get(parts[2],3)
            score={'mezzo-forte':0,'mezzo-piano':.7,'piano':1.4,'forte':1.8,'pianissimo':2.5,'fortissimo':5}.get(parts[3],6)+abs(math.log(duration/3))
        if midi is not None and (midi not in choices or score<choices[midi][0]):choices[midi]=(score,file)
    if not choices:raise RuntimeError(f'Missing instrument: {key}')
    target=output/key;target.mkdir(exist_ok=True);entries=[]
    for midi,(_,file) in sorted(choices.items()):
        values,rate,peak=decode(file);duration=len(values)/rate
        loop=None
        if key not in ('piano','guitar') and duration>.9:
            begin=int(.35*rate);end=len(values)-int(.15*rate);cross=int(.03*rate)
            for n in range(cross):
                blend=n/(cross-1);values[end-cross+n]=values[end-cross+n]*(1-blend)+values[begin+n]*blend
            loop=[(begin+cross)/rate,end/rate]
        pcm=array.array('h')
        for i,value in enumerate(values):
            fade=min(1,(len(values)-i)/(.02*rate));pcm.append(round(max(-.99,min(.99,value*.72/peak*fade))*32767))
        if sys.byteorder!='little':pcm.byteswap()
        name=f'{midi}.wav'
        with wave.open(str(target/name),'wb') as wav:
            wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(rate);wav.writeframes(pcm.tobytes())
        entries.append({'pitch':midi,'url':f'/assets/samples/{key}/{name}','loop':loop,'source':str(file.relative_to(root))})
    instruments[key]={'samples':entries}
    print(f'{key}: {len(entries)} recorded pitches ready',flush=True)
(output/'manifest.json').write_text(json.dumps({'version':1,'instruments':instruments},ensure_ascii=False,indent=2)+'\n')
demo=root/'build/midi_resource_demo/巴赫_勃兰登堡2_演示.json'
if demo.exists():
    dest=root/'web/midi-editor/assets/demos';dest.mkdir(exist_ok=True);shutil.copyfile(demo,dest/'bach-ensemble.json')
print('Browser sample bank ready:',sum(len(v['samples']) for v in instruments.values()),'recorded pitches')
