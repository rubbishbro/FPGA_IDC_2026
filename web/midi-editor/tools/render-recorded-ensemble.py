"""Play the downloaded MIDI excerpt using the project's recorded instrument notes."""
import array
import ctypes as c
import ctypes.util
import hashlib
import json
import math
import pathlib
import random
import re
import sys
import wave

root = pathlib.Path(__file__).resolve().parents[3]
folder = root / 'build/midi_resource_demo'
project = json.loads((folder / '巴赫_勃兰登堡2_演示.json').read_text())
rate, bpm = 44100, 112
seconds_per_beat = 60 / bpm
length = math.ceil((64 * seconds_per_beat + 2) * rate)
left, right = array.array('f', [0]) * length, array.array('f', [0]) * length
rng = random.Random(1047)
roles = [
    ('trumpet', .115, .05), ('flute', .19, -.12), ('oboe', .14, .18),
    ('violin', .145, -.28), ('violin', .105, -.48), ('violin', .10, -.13),
    ('viola', .13, .34), ('double bass', .16, .22), ('cello', .17, .05),
]

class Info(c.Structure):
    _fields_ = [('frames', c.c_longlong), ('samplerate', c.c_int), ('channels', c.c_int),
                ('format', c.c_int), ('sections', c.c_int), ('seekable', c.c_int)]

lib = c.CDLL(ctypes.util.find_library('sndfile'))
lib.sf_open.argtypes = [c.c_char_p, c.c_int, c.POINTER(Info)]
lib.sf_open.restype = c.c_void_p
lib.sf_readf_float.argtypes = [c.c_void_p, c.POINTER(c.c_float), c.c_longlong]
lib.sf_readf_float.restype = c.c_longlong
lib.sf_close.argtypes = [c.c_void_p]
cache, used = {}, {}

def midi_pitch(text):
    match = re.fullmatch(r'([A-G])(s?)(-?\d+)', text)
    if not match:
        return None
    name, sharp, octave = match.groups()
    return (int(octave) + 1) * 12 + {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}[name] + bool(sharp)

catalog = {}
duration_values = {'025': .25, '05': .5, '1': 1, '15': 1.5, 'long': 3, 'very-long': 5}
for instrument, _, _ in roles:
    if instrument in catalog:
        continue
    candidates = []
    for file in sorted((root / 'music_resources' / instrument).glob('*.mp3')):
        parts = file.stem.split('_')
        if len(parts) != 5 or parts[4] not in ('normal', 'arco-normal'):
            continue
        pitch = midi_pitch(parts[1])
        if pitch is not None:
            candidates.append((file, pitch, duration_values.get(parts[2], 3), parts[3]))
    if not candidates:
        raise RuntimeError(f'No recorded normal articulation samples: {instrument}')
    catalog[instrument] = candidates

def load(file):
    if file in cache:
        return cache[file]
    info = Info()
    handle = lib.sf_open(str(file).encode(), 0x10, c.byref(info))
    if not handle:
        raise RuntimeError(f'Cannot decode {file}')
    try:
        buffer = (c.c_float * (info.frames * info.channels))()
        count = lib.sf_readf_float(handle, buffer, info.frames)
        values = array.array('f')
        values.frombytes(c.string_at(buffer, count * info.channels * 4))
    finally:
        lib.sf_close(handle)
    if info.channels > 1:
        values = array.array('f', (sum(values[i:i+info.channels])/info.channels for i in range(0, len(values), info.channels)))
    peak = max(map(abs, values), default=0)
    if peak < .0001:
        raise RuntimeError(f'Unexpected silent sample: {file}')
    # Trim recording lead-in while keeping 8 ms before the detected attack.
    block = max(1, info.samplerate // 200)
    onset = 0
    for i in range(0, len(values)-block, block):
        rms = math.sqrt(sum(x*x for x in values[i:i+block])/block)
        if rms > peak*.045:
            onset = max(0, i-int(info.samplerate*.008))
            break
    values = values[onset:]
    cache[file] = (values, info.samplerate, .72/peak)
    used[str(file.relative_to(root))] = {'sha256': hashlib.sha256(file.read_bytes()).hexdigest(), 'sampleRate': info.samplerate}
    return cache[file]

exact, shifted = 0, 0
for track, (instrument, level, pan) in zip(project['tracks'], roles):
    lgain, rgain = math.cos((pan+1)*math.pi/4), math.sin((pan+1)*math.pi/4)
    for note in track['notes']:
        gate = note['duration'] * seconds_per_beat
        def score(candidate):
            _, pitch, duration, dynamic = candidate
            dynamic_cost = {'mezzo-forte': 0, 'mezzo-piano': .7, 'piano': 1.4, 'forte': 1.8, 'pianissimo': 2.5, 'fortissimo': 5}.get(dynamic, 6)
            return abs(pitch-note['pitch'])*30 + abs(math.log(max(.12,gate)/duration)) + dynamic_cost
        ranked = sorted(catalog[instrument], key=score)
        best = score(ranked[0])
        choices = [candidate for candidate in ranked[:4] if score(candidate) <= best+.85]
        file, pitch, _, _ = rng.choice(choices)
        exact += pitch == note['pitch']
        shifted += pitch != note['pitch']
        samples, source_rate, normalization = load(file)
        ratio = source_rate/rate * 2**((note['pitch']-pitch)/12)
        release = .055 if instrument in ('flute','oboe','trumpet') else .085
        count = min(math.ceil((gate+release)*rate), int((len(samples)-1)/ratio))
        # Small player-to-player timing and dynamic variation; pitch stays exact.
        start = max(0, round((note['beat']*seconds_per_beat+rng.uniform(-.004,.006))*rate))
        gain = level*normalization*(note['velocity']/127)*rng.uniform(.94,1.04)
        gain *= 1.045 if abs(note['beat'] % 1) < 1e-6 else .98
        attack = .003*rate
        for i in range(min(count, length-start)):
            position = i*ratio
            index = int(position)
            fraction = position-index
            sample = samples[index]*(1-fraction)+samples[index+1]*fraction
            fade = min(1, i/attack)
            if i/rate > gate:
                fade *= max(0, 1-(i/rate-gate)/release)**2
            value = sample*gain*fade
            left[start+i] += value*lgain
            right[start+i] += value*rgain
    print(f'Rendered {track["name"]}: {len(track["notes"])} notes; {len(cache)} recorded samples cached', flush=True)

# Gentle stereo early reflections; recordings retain their original body/noise.
dry_left, dry_right = left[:], right[:]
for delay, amount in [(.043,.085),(.079,.065),(.127,.045),(.181,.035),(.269,.025),(.397,.015)]:
    shift = round(delay*rate)
    for i in range(shift,length):
        left[i] += dry_right[i-shift]*amount
        right[i] += dry_left[i-shift]*amount
peak = max(max(map(abs,left)),max(map(abs,right)))
gain = .89/peak
pcm = array.array('h')
energy = 0
for i in range(length):
    fade = min(1,(length-i)/(.6*rate))
    for channel in (left,right):
        value = channel[i]*gain*fade
        if not math.isfinite(value):
            raise RuntimeError('Invalid mix sample')
        pcm.append(round(value*32767))
        energy += value*value
if sys.byteorder != 'little':
    pcm.byteswap()
target = folder/'巴赫_勃兰登堡2_真实乐器采样版.wav'
with wave.open(str(target),'wb') as wav:
    wav.setnchannels(2);wav.setsampwidth(2);wav.setframerate(rate);wav.writeframes(pcm.tobytes())
report = {'file':str(target),'durationSeconds':length/rate,'recordedSamplesUsed':len(used),'notesUsingExactRecordedPitch':exact,'notesUsingNearestRecordedPitch':shifted,'peakDbFS':20*math.log10(.89),'rmsDbFS':20*math.log10(math.sqrt(energy/(length*2))),'samples':used}
(folder/'recorded-samples-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({key:value for key,value in report.items() if key!='samples'},ensure_ascii=False,indent=2))
