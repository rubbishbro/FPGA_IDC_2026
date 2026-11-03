"""Render prepared MIDI events using installed FluidSynth and sampled GM sounds."""
import array
import ctypes as c
import ctypes.util
import json
import math
import pathlib
import sys
import wave

folder = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/midi_resource_demo')
data = json.loads((folder / 'render-events.json').read_text())
lib = c.CDLL(ctypes.util.find_library('fluidsynth'))

def bind(name, result, *args):
    function = getattr(lib, name)
    function.restype, function.argtypes = result, args
    return function

pointer, integer = c.c_void_p, c.c_int
new_settings = bind('new_fluid_settings', pointer)
setnum = bind('fluid_settings_setnum', integer, pointer, c.c_char_p, c.c_double)
setint = bind('fluid_settings_setint', integer, pointer, c.c_char_p, integer)
new_synth = bind('new_fluid_synth', pointer, pointer)
sfload = bind('fluid_synth_sfload', integer, pointer, c.c_char_p, integer)
render = bind('fluid_synth_write_float', integer, pointer, integer, pointer, integer, integer, pointer, integer, integer)
handlers = {
    0x80: bind('fluid_synth_noteoff', integer, pointer, integer, integer),
    0x90: bind('fluid_synth_noteon', integer, pointer, integer, integer, integer),
    0xB0: bind('fluid_synth_cc', integer, pointer, integer, integer, integer),
    0xC0: bind('fluid_synth_program_change', integer, pointer, integer, integer),
    0xD0: bind('fluid_synth_channel_pressure', integer, pointer, integer, integer),
    0xE0: bind('fluid_synth_pitch_bend', integer, pointer, integer, integer),
}
rate = 44100
settings = new_settings()
setnum(settings, b'synth.sample-rate', rate)
setnum(settings, b'synth.gain', .35)
setnum(settings, b'synth.reverb.room-size', .55)
setnum(settings, b'synth.reverb.level', .22)
setint(settings, b'synth.chorus.active', 0)
synth = new_synth(settings)
if not synth:
    raise RuntimeError('Cannot initialize FluidSynth')
soundfont = '/usr/share/sounds/sf2/TimGM6mb.sf2'
if sfload(synth, soundfont.encode(), 1) < 0:
    raise RuntimeError('Cannot load sampled GM soundfont')
audio = array.array('f')
block = (c.c_float * (4096 * 2))()
position = 0

def advance(target):
    global position
    while position < target:
        length = min(4096, target - position)
        if render(synth, length, block, 0, 2, block, 1, 2) < 0:
            raise RuntimeError('FluidSynth rendering failed')
        audio.frombytes(c.string_at(block, length * 8))
        position += length

try:
    for event in data['events']:
        advance(round(event['time'] * rate))
        status, *payload = event['data']
        kind, channel = status & 0xF0, status & 15
        if kind == 0xE0:
            payload = [payload[0] | (payload[1] << 7)]
        handler = handlers.get(kind)
        if handler and handler(synth, channel, *payload) < 0:
            raise RuntimeError(f'MIDI event rejected: {event}')
    advance(round((data['duration'] + data['tail']) * rate))
finally:
    bind('delete_fluid_synth', None, pointer)(synth)
    bind('delete_fluid_settings', None, pointer)(settings)

if not audio or not all(math.isfinite(x) for x in audio):
    raise RuntimeError('Invalid rendered audio')
peak = max(map(abs, audio))
if peak < .001:
    raise RuntimeError('Unexpected silent render')
gain = .89 / peak
pcm = array.array('h')
square = 0.0
frames = len(audio) // 2
for index, sample in enumerate(audio):
    fade = min(1, (frames - index // 2) / (rate * .5))
    value = sample * gain * fade
    pcm.append(round(value * 32767))
    square += value * value
if sys.byteorder != 'little':
    pcm.byteswap()
target = folder / '巴赫_勃兰登堡2_真实MIDI重奏.wav'
with wave.open(str(target), 'wb') as wav:
    wav.setnchannels(2)
    wav.setsampwidth(2)
    wav.setframerate(rate)
    wav.writeframes(pcm.tobytes())
report = {'durationSeconds': frames / rate, 'channels': 2, 'sampleRate': rate,
          'peakDbFS': 20 * math.log10(.89),
          'rmsDbFS': 20 * math.log10(math.sqrt(square / len(audio))),
          'source': 'Mutopia Bach BWV1047 score.mid', 'renderer': 'FluidSynth',
          'soundfont': soundfont, 'events': len(data['events']), 'tracks': data['tracks']}
(folder / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
