import test from 'node:test';
import assert from 'node:assert/strict';
import {SampleSynth} from '../src/sample-synth.mjs';
import {trackInstrument,nearestSample} from '../src/sample-instruments.mjs';
import {blankProject,compileEvents,validateProject} from '../src/model.mjs';
import {writeMidi,parseMidi} from '../src/midi-file.mjs';

function track(program){const t=blankProject().tracks[0];t.events=[{beat:0,data:[0xc0|t.channel,program]}];t.notes=[{id:crypto.randomUUID(),pitch:60,beat:0,duration:1,velocity:90}];return t;}
test('local note events retain each track instrument even on a shared channel',()=>{
  const p=blankProject();p.tracks=[track(73),track(42)];
  const attacks=compileEvents(p).filter(e=>(e.data[0]&240)===144);
  assert.deepEqual(attacks.map(e=>e.instrument),['flute','cello']);
  assert.ok(compileEvents(p,{hardware:true}).every(e=>!('instrument' in e)));
});
test('program changes, channel defaults and explicit track choices resolve consistently',()=>{
  const t=track(73);t.events.push({beat:4,data:[0xc0|t.channel,40]});
  assert.equal(trackInstrument(t,0),'flute');assert.equal(trackInstrument(t,4),'violin');
  t.previewInstrument='cello';assert.equal(trackInstrument(t,4),'cello');
  const p=blankProject();p.tracks=[t];const back=parseMidi(writeMidi(p)).project;
  assert.equal(trackInstrument(back.tracks[0],4),'cello');
  t.previewInstrument='invalid';assert.throws(()=>validateProject(p),/音色/);
});
test('sample lookup uses the closest recorded pitch at both ends of an instrument range',()=>{
  const samples=[{pitch:48},{pitch:60},{pitch:72}];
  assert.equal(nearestSample(samples,0).pitch,48);assert.equal(nearestSample(samples,127).pitch,72);assert.equal(nearestSample(samples,59).pitch,60);
});
test('parallel requests share a decoded sample and a failed request can be retried',async()=>{
  const samples=[{pitch:60,url:'/piano-60.wav'}],bank={version:1,instruments:{piano:{samples}}};
  let requests=0,decodes=0,fail=true;
  const synth=new SampleSynth({fetch:async url=>{
    if(url.endsWith('manifest.json'))return {ok:true,json:async()=>bank};
    requests++;if(fail){fail=false;return {ok:false};}
    return {ok:true,arrayBuffer:async()=>new ArrayBuffer(8)};
  }});
  synth.context={decodeAudioData:async()=>{decodes++;return {duration:1};}};
  await assert.rejects(synth.load('piano',60),/加载失败/);
  const [a,b]=await Promise.all([synth.load('piano',60),synth.load('piano',61)]);
  assert.equal(a,b);assert.equal(requests,2);assert.equal(decodes,1);
});
test('prepare skips muted tracks and restores volume/pan before a seek',async()=>{
  const p=blankProject();p.tracks=[track(73),track(42)];p.tracks[1].muted=true;
  p.tracks[0].events.push({beat:0,data:[0xb1,7,80]},{beat:3,data:[0xb1,10,96]});
  const synth=new SampleSynth(),jobs=[];synth.bank=async()=>({});synth.load=async(instrument,pitch)=>jobs.push([instrument,pitch]);
  await synth.prepare(p,()=>{},4);
  assert.deepEqual(jobs,[['flute',60]]);assert.deepEqual(synth.controllers.get(1),{volume:80/127,pan:.5});
});
