# Reference audio regression

Start the MIDI editor server and open
`http://127.0.0.1:5173/tests/browser/audio-response.html`, then click the run button.
The page uses Chromium's actual OfflineAudioContext and the production ReferenceSynth.
It renders the reported low-register project without changing any MIDI pitches.

Checks include final-output RMS at ten MIDI pitches (18–96), a 150 Hz high-pass /
5 kHz low-pass speaker-band proxy, coherent 16-voice peaks, and the four-note
reported project. The proxy is a deterministic filter, not a measurement of the
user's speakers or an equal-loudness model. Biquad low/high-pass Q is in dB;
-3.0103 dB gives a Butterworth response.

The legacy triangle fixture holds velocity, envelope and output processing fixed
so its speaker-band gap can be compared with the enhanced reference waveform.
The Node test suite also checks tuning, spectral energy and harmonic bandwidth
for every MIDI pitch at 44.1 and 48 kHz.
