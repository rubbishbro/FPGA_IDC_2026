// A reference tone must remain audible on speakers that cannot reproduce its
// fundamental. Add consecutive bass harmonics without transposing the MIDI note.
// Normalize spectral energy rather than the peak, which varies with harmonic mix.
export function referenceSpectrum(pitch,sampleRate) {
  const frequency=440*2**((pitch-69)/12);
  const count=Math.max(1,Math.min(64,Math.floor(sampleRate*.45/frequency)));
  const real=new Float32Array(count+1),imag=new Float32Array(count+1);
  const bass=Math.max(0,Math.min(1,(60-pitch)/24));
  let energy=0;
  for(let harmonic=1;harmonic<=count;harmonic++) {
    const triangle=harmonic%2?(-1)**((harmonic-1)/2)/harmonic**2:0;
    const body=harmonic===1?.35:
      1.2*Math.exp(-.5*(Math.log2(harmonic*frequency/220)/.85)**2)/Math.sqrt(harmonic);
    imag[harmonic]=(1-bass)*triangle+bass*body;
    energy+=imag[harmonic]**2;
  }
  const scale=Math.sqrt((2/3)/energy);
  for(let harmonic=1;harmonic<=count;harmonic++)imag[harmonic]*=scale;
  return {frequency,real,imag};
}
