import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {crc16,encodeFrame,FrameReader,packMidi} from '../src/protocol.mjs';
import {blankProject,demoProject,validateProject,beatToSeconds,secondsToBeat,compileEvents,hardwareIssues,History,uid,profileExercise} from '../src/model.mjs';
import {parseMidi,writeMidi} from '../src/midi-file.mjs';
import {Playback} from '../src/playback.mjs';
const hex=s=>Uint8Array.from(s.split(' ').map(s=>parseInt(s,16)));
const fixture=JSON.parse(await readFile(new URL('../../../rtl/drivers/analyzer/frame_vectors.json',import.meta.url)));
test('CRC and all six production RTL protocol vectors match byte for byte',()=>{
  assert.equal(crc16(new TextEncoder().encode('123456789')),0x29b1);
  for(const v of fixture.vectors)assert.deepEqual(encodeFrame(v.type,v.seq,hex(v.payload_hex)),hex(v.wire_hex));
});
test('SLIP fragmentation, shared delimiters, corruption and resynchronization',()=>{
  const frames=[],errors=[],reader=new FrameReader(f=>frames.push(f),e=>errors.push(e));
  const good=hex(fixture.vectors[0].wire_hex),escaped=hex(fixture.vectors[4].wire_hex);
  const wire=Uint8Array.from([14,15,...good,...escaped.slice(1)]);
  for(const byte of wire)reader.feed([byte]);
  assert.deepEqual(frames.map(f=>f.seq),[0,56256]);
  const bad=good.slice();bad[7]^=1;reader.feed(bad);reader.feed([0xc0,1,0xdb,0,0xc0]);reader.feed([0xc0,...new Array(45).fill(1),0xc0]);reader.feed(good);
  assert.equal(errors.length,3);assert.equal(frames.length,3);
});
test('MIDI packetizer never splits short messages or exceeds 32 bytes',()=>{
  const messages=Array.from({length:16},(_,i)=>[0x90,60+i,100]),packets=packMidi(messages);
  assert.deepEqual(packets.map(p=>p.length),[30,18]);assert.deepEqual(packets.flat(),messages.flat());
  assert.throws(()=>packMidi([[0x90,60]]));assert.throws(()=>encodeFrame(1,0,new Array(33).fill(0)));
});
test('SMF roundtrip preserves notes, channels, Chinese track names, tempo and CC/bend/program',()=>{
  const p=demoProject();p.tempoMap.push({beat:4,bpm:85},{beat:8,bpm:130});
  p.tracks[0].events=[{beat:1,data:[0xb1,64,127]},{beat:2,data:[0xb1,64,0]},{beat:0,data:[0xc1,1]},{beat:2,data:[0xe1,0,65]}];
  const {project:q,report}=parseMidi(writeMidi(p));assert.equal(report.auxiliary,4);assert.equal(q.tracks.length,2);
  for(let i=0;i<p.tracks.length;i++){assert.equal(q.tracks[i].name,p.tracks[i].name);assert.equal(q.tracks[i].channel,p.tracks[i].channel);assert.equal(q.tracks[i].notes.length,p.tracks[i].notes.length);for(let j=0;j<p.tracks[i].notes.length;j++){const a=p.tracks[i].notes[j],b=q.tracks[i].notes[j];assert.equal(b.pitch,a.pitch);assert.equal(b.velocity,a.velocity);assert.ok(Math.abs(b.duration-a.duration)<1/480);}}
  assert.equal(q.tempoMap.length,3);assert.ok(Math.abs(q.tempoMap[1].bpm-85)<.001);assert.deepEqual(q.tracks[0].events,p.tracks[0].events.toSorted((a,b)=>a.beat-b.beat));
});
function smf(events,division=480){return Uint8Array.from([77,84,104,100,0,0,0,6,0,0,0,1,division>>8,division&255,77,84,114,107,0,0,0,events.length,...events]);}
test('SMF running status, zero velocity note off, malformed lengths and unsupported timing',()=>{
  const p=parseMidi(smf([0,0x90,60,100,0x83,0x60,60,0,0,0xff,0x2f,0])).project;
  assert.equal(p.tracks[0].notes[0].duration,1);
  assert.throws(()=>parseMidi(smf([0,60,100])));
  assert.throws(()=>parseMidi(smf([0,0xff,0x51,3,1])));
  assert.throws(()=>parseMidi(smf([0,0xff,0x58,4,3,2,24,8])));
  assert.throws(()=>parseMidi(smf([],0xe728)));
  assert.throws(()=>parseMidi(writeMidi(demoProject()).slice(0,-1)));
});
test('tempo integration is reversible and event ties release before retrigger',()=>{
  const map=[{beat:0,bpm:120},{beat:4,bpm:60},{beat:8,bpm:180}];assert.equal(beatToSeconds(8,map),6);
  for(const b of [0,1,4,5.5,8,10,40])assert.ok(Math.abs(secondsToBeat(beatToSeconds(b,map),map)-b)<1e-8);
  const p=blankProject();p.tracks[0].notes=[{id:uid(),beat:0,duration:1,pitch:60,velocity:90},{id:uid(),beat:1,duration:1,pitch:60,velocity:80}];
  assert.deepEqual(compileEvents(p).filter(e=>e.beat===1).map(e=>e.data[0]&0xf0),[0x80,0x90]);
});
test('hardware admission enforces channel, active bank, solo/mute and same-note overlap',()=>{
  const p=demoProject(),profile={channel:1,notes:[...new Set(p.tracks.flatMap(t=>t.notes.map(n=>n.pitch)))]};
  assert.deepEqual(hardwareIssues(p,profile),[]);assert.ok(hardwareIssues(p,{...profile,notes:[60]}).some(s=>s.includes('缺少')));
  p.tracks[1].channel=2;assert.ok(hardwareIssues(p,profile).some(s=>s.includes('通道')));p.tracks[0].solo=true;assert.deepEqual(hardwareIssues(p,profile),[]);
  p.tracks[0].notes.push({...p.tracks[0].notes[0],id:uid(),beat:.1});assert.ok(hardwareIssues(p,profile).some(s=>s.includes('重叠')));
});
test('project JSON validation and undo/redo isolate snapshots',()=>{
  const p=blankProject(),history=new History(p);p.name='external';assert.notEqual(history.current.name,p.name);
  const q=structuredClone(history.current);q.name='next';history.commit(q);q.name='mutated';assert.equal(history.current.name,'next');history.undo();assert.equal(history.current.name,'未命名片段');history.redo();assert.equal(history.current.name,'next');
  assert.throws(()=>validateProject({...history.current,loop:{enabled:true,start:4,end:2}}));
});
test('playback emits only due messages, chases held notes and releases at stop/loop',()=>{
  const p=blankProject();p.tempoMap=[{beat:0,bpm:60}];p.loop={enabled:false,start:0,end:4};p.bars=1;
  p.tracks[0].notes=[{id:uid(),beat:0,duration:1,pitch:60,velocity:90},{id:uid(),beat:2,duration:.5,pitch:64,velocity:100}];
  let now=0,panic=0;const sent=[];const player=new Playback({now:()=>now,send:events=>sent.push(...events),panic:()=>panic++});
  player.start(p);player.tick();assert.equal(sent.length,1);now=999;player.tick();assert.equal(sent.length,1);now=1000;player.tick();assert.equal(sent[1].data[0]&0xf0,0x80);now=2000;player.tick();assert.equal(sent[2].data[1],64);player.stop();assert.equal(panic,1);
  sent.length=0;player.start(p,.5);assert.equal(sent.length,1);assert.equal(sent[0].data[1],60);player.stop();
  p.loop.enabled=true;p.loop.end=1;sent.length=0;now=0;player.start(p);player.tick();now=1001;player.tick();assert.equal(player.position,0);assert.ok(panic>=3);player.stop();
});
test('UART playback filters unsupported controls but preserves them in MIDI export',()=>{
  const p=blankProject();p.tracks[0].events=[{beat:0,data:[0xc1,0]},{beat:0,data:[0xb1,7,100]},{beat:0,data:[0xb1,64,127]}];
  assert.equal(compileEvents(p).length,3);assert.deepEqual(compileEvents(p,{hardware:true}).map(e=>e.data),[[0xb1,64,127]]);assert.equal(parseMidi(writeMidi(p)).project.tracks[0].events.length,3);
});
test('seek chases sustained released notes and ignores expected queue cancellation',async()=>{
  const p=blankProject();p.tempoMap=[{beat:0,bpm:60}];p.loop.enabled=false;p.tracks[0].notes=[{id:uid(),pitch:60,beat:0,duration:1,velocity:90}];
  p.tracks[0].events=[{beat:.5,data:[0xb1,64,127]},{beat:3,data:[0xb1,64,0]}];
  const sent=[];let errors=0;const player=new Playback({send:events=>{sent.push(...events);return Promise.reject(Object.assign(Error('cancelled'),{name:'AbortError'}));},panic(){},onError:()=>errors++});
  player.start(p,2);await Promise.resolve();assert.equal(errors,0);assert.deepEqual(sent.map(e=>e.data[0]&0xf0),[0xb0,0x90,0x80]);player.stop();
});

test('unclosed note exactly on a bar boundary gets a valid end and project length',()=>{
  const {project:p,report}=parseMidi(smf([0x8f,0,0x90,60,90,0,0xff,0x2f,0]));assert.equal(report.closed,1);assert.equal(p.bars,2);assert.ok(p.tracks[0].notes[0].duration>0);validateProject(p);
});
test('hardware test phrase only uses the selected channel and current note resources',()=>{
  const profile={channel:1,notes:[40,42,44,46,48,50,52,54,56,58,60,62,64,67,71,76]},p=profileExercise(profile);validateProject(p);assert.deepEqual(hardwareIssues(p,profile),[]);assert.deepEqual(p.tracks[0].notes.map(n=>n.pitch),profile.notes);assert.throws(()=>profileExercise({...profile,notes:[]}));
});
