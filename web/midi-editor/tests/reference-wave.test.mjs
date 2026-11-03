import test from 'node:test';
import assert from 'node:assert/strict';
import {referenceSpectrum} from '../src/reference-wave.mjs';

test('reference spectrum retains MIDI tuning and equal energy over all pitches',()=>{
  for(const rate of [44100,48000])for(let pitch=0;pitch<128;pitch++){
    const {frequency,real,imag}=referenceSpectrum(pitch,rate);
    assert.equal(frequency,440*2**((pitch-69)/12));
    assert.equal(real[0],0);assert.equal(imag[0],0);assert.ok(imag[1]>0);
    assert.ok((imag.length-1)*frequency<=rate*.45);
    assert.ok(imag.every(Number.isFinite));
    assert.ok(Math.abs(imag.reduce((sum,x)=>sum+x*x,0)-2/3)<1e-6);
  }
});

test('reported bass pitches retain audible upper harmonics without boosting treble',()=>{
  for(const pitch of [18,27,28,30]){
    const {frequency,imag}=referenceSpectrum(pitch,48000);
    const audible=imag.reduce((sum,x,n)=>sum+(n*frequency>=150?x*x:0),0);
    assert.ok(audible/(2/3)>.5,`MIDI ${pitch} needs energy above speaker bass rolloff`);
  }
  // Above middle C the original triangle harmonic proportions remain unchanged.
  const {imag}=referenceSpectrum(72,48000);
  assert.equal(imag[2],0);assert.ok(Math.abs(imag[3]/imag[1]+1/9)<1e-7);
});
