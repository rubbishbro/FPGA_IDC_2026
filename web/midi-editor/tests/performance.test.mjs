import test from 'node:test';
import assert from 'node:assert/strict';
import {blankProject,validateProject} from '../src/model.mjs';
import {PerformanceRecorder,decodePerformance,recordIdBytes} from '../src/performance-recorder.mjs';
import {FrameReader,encodeFrame} from '../src/protocol.mjs';
import {SerialLink} from '../src/serial.mjs';
import {writeMidi,parseMidi} from '../src/midi-file.mjs';
function event({kind=0,id=42,ordinal=0,tick=0,slot=0,channel=1,flags=0,a=12500000,b=256}={}){
 const p=new Uint8Array(24),v=new DataView(p.buffer);p.set([kind,flags,channel,slot]);for(const [offset,value] of [[4,id],[8,ordinal],[12,tick],[16,a],[20,b]])v.setUint32(offset,value,true);return {type:130,seq:ordinal&255,payload:p};
}
function recorder(){const project=blankProject();project.tempoMap=[{beat:0,bpm:120},{beat:4,bpm:60}];return new PerformanceRecorder({id:42,project,insertBeat:2});}
test('performance stream has fixed LEN24 and survives bytewise SLIP, including IDs and timestamps',()=>{
 const input=event({id:0xdbc0dbc0,tick:0}),frames=[];const reader=new FrameReader(f=>frames.push(f));for(const b of encodeFrame(130,input.seq,input.payload))reader.feed([b]);assert.equal(frames.length,1);assert.equal(decodePerformance(frames[0]).id,0xdbc0dbc0);assert.deepEqual(recordIdBytes(0xdbc0dbc0),[192,219,192,219]);assert.throws(()=>encodeFrame(130,0,new Uint8Array(23)));
});
test('chord notes share time, OFF uses original pitch, END closes held keys, take is editable/exportable',()=>{
 const r=recorder();r.push(event());
 r.push(event({kind:1,ordinal:1,tick:0,slot:0,a:60|90<<8,b:0}));r.push(event({kind:1,ordinal:2,tick:0,slot:1,a:64|100<<8,b:0}));
 r.push(event({kind:2,ordinal:3,tick:50000,slot:0,a:60|90<<8,b:0}));
 r.push(event({kind:3,ordinal:4,tick:100000,a:0,b:3}));
 assert.equal(r.track.notes.length,2);assert.equal(r.track.notes[0].beat,2);assert.equal(r.track.notes[1].beat,2);assert.equal(r.incomplete,false);assert.equal(r.open.size,0);
 assert.ok(Math.abs(r.track.notes[0].duration-2.024)<1e-8);assert.ok(Math.abs(r.track.notes[1].duration-3.048)<1e-8);
 const p=blankProject();p.tempoMap=r.tempoMap;p.tracks=[r.track];validateProject(p);const q=parseMidi(writeMidi(p)).project;assert.equal(q.tracks[0].notes[0].pitch,60);assert.equal(q.tracks[0].notes[1].velocity,100);assert.ok(Math.abs(q.tracks[0].notes[1].duration-r.track.notes[1].duration)<1/480);
});
test('missing events, duplicate frames, stale takes and flagged END cannot masquerade as a complete take',()=>{
 const r=recorder();r.push(event());assert.equal(r.push(event({id:43,ordinal:1})),false);assert.equal(r.push(event()),false);assert.equal(r.duplicates,1);
 r.push(event({kind:1,ordinal:2,a:60|1<<8,b:0}));r.push(event({kind:3,ordinal:3,tick:10,a:0,b:2,flags:1}));assert.equal(r.incomplete,true);assert.equal(r.track.notes[0].velocity,1);assert.equal(r.track.notes[0].duration,1/480);
});
test('recorder rejects bad starts, out-of-bounds data and backward device time; abort never uses arrival time',()=>{
 assert.throws(()=>recorder().push(event({kind:1,ordinal:1,a:60|90<<8,b:0})));
 assert.throws(()=>recorder().push(event({a:48000,b:1})));
 assert.throws(()=>decodePerformance(event({kind:1,a:200|90<<8,b:0})));
 const r=recorder();r.push(event());r.push(event({kind:1,ordinal:1,tick:100,a:60|90<<8,b:0}));assert.throws(()=>r.push(event({kind:2,ordinal:2,tick:50,a:60|90<<8,b:0})));r.abort();assert.equal(r.incomplete,true);assert.equal(r.lastTick,100);
 const other=recorder();other.push(event());assert.throws(()=>other.push(event({kind:3,ordinal:1,tick:30000000,a:0,b:0})));
});
function mock(){let readResolve;const wires=[];const port={open:async()=>{},close:async()=>{},readable:{getReader:()=>({read:()=>new Promise(r=>readResolve=r),cancel:async()=>readResolve?.({done:true}),releaseLock(){}})},writable:{getWriter:()=>({write:async wire=>wires.push(wire),ready:Promise.resolve(),releaseLock(){}})}};const link=new SerialLink(()=>{},()=>{},{addEventListener(){},requestPort:async()=>port});return {link,wires};}
test('v1 CONFIG matches seq/type/command, protects control from panic cancellation, and times out finitely',async()=>{
 const {link,wires}=mock();await link.connect(2000000);const request=link.configure(0x12,recordIdBytes(42));link.cancel();assert.equal(link.pendingConfig.command,0x12);
 link.handleFrame({type:128,seq:0,payload:Uint8Array.from([0x13,0])});assert.ok(link.pendingConfig);
 link.handleFrame({type:128,seq:0,payload:Uint8Array.from([0x12,0])});await request;assert.equal(link.pendingConfig,null);assert.ok(wires.length);
 await assert.rejects(link.configure(0x13,recordIdBytes(42),{timeoutMs:10}),/超时/);await link.disconnect();
});
test('v1 performance dispatch does not log or update UI per frame, non-OK CONFIG rejects',async()=>{
 let updates=0,logs=0,events=0;const link=new SerialLink(()=>updates++,()=>logs++);link.writer={};link.onFrame=()=>events++;
 link.handleFrame(event());assert.equal(events,1);assert.equal(updates,0);assert.equal(logs,0);
 link.writer=null;await assert.rejects(link.configure(0x12,[0,0,0,0]),/未连接/);
});
test('recording UI locks edits, commits one editable take, closes held keys and restores controls',async()=>{
 const {setupRecording}=await import('../src/recording-ui.mjs');
 const originalDocument=globalThis.document,originalWindow=globalThis.window;
 const nodes=new Map(),listeners={},windowEvents={};
 const node=()=>({textContent:'',disabled:false,inert:false,title:'',classList:{toggle(){}},setAttribute(k,v){this[k]=v;}});
 const doc={hidden:false,getElementById(id){if(!nodes.has(id))nodes.set(id,node());return nodes.get(id);},querySelector(){return doc.getElementById('workspace');},addEventListener(k,fn){listeners[k]=fn;}};
 globalThis.document=doc;globalThis.window={addEventListener(k,fn){windowEvents[k]=fn;}};
 const p=blankProject();let currentId,commits=[],stops=0;
 const link={connected:true,configure:async(cmd,bytes)=>{currentId=(bytes[0]|bytes[1]<<8|bytes[2]<<16|bytes[3]<<24)>>>0;return {type:128};}};
 try{
  const ui=setupRecording({getLink:()=>link,supportsRecording:()=>true,getProject:()=>p,getPosition:()=>2,stopPlayback:()=>stops++,toast(){},status(){},commitTrack:(track,incomplete)=>commits.push({track,incomplete})});
  assert.equal(nodes.get('record-performance').disabled,false);await nodes.get('record-performance').onclick();assert.equal(ui.busy,true);assert.equal(nodes.get('workspace').inert,true);assert.equal(stops,1);
  ui.onFrame(event({id:currentId}));ui.onFrame(event({id:currentId,kind:1,ordinal:1,tick:0,a:60|90<<8,b:0}));
  await nodes.get('record-performance').onclick();assert.equal(ui.busy,true);
  ui.onFrame(event({id:currentId,kind:3,ordinal:2,tick:48000,a:0,b:1}));
  assert.equal(ui.busy,false);assert.equal(nodes.get('workspace').inert,false);assert.equal(commits.length,1);assert.equal(commits[0].incomplete,false);assert.ok(Math.abs(commits[0].track.notes[0].beat-2)<1e-9);assert.ok(commits[0].track.notes[0].duration>0);
  ui.onFrame(event({id:currentId,kind:3,ordinal:2,tick:48000,a:0,b:1}));assert.equal(commits.length,1);
 }finally{windowEvents.pagehide?.();globalThis.document=originalDocument;globalThis.window=originalWindow;}
});
test('performance extension matches independent Python CCITT/struct golden vectors',async()=>{
 const {readFile}=await import('node:fs/promises');const {vectors}=JSON.parse(await readFile(new URL('./fixtures/performance_vectors.json',import.meta.url)));
 const bytes=s=>Uint8Array.from(s.split(' ').map(x=>parseInt(x,16)));
 for(const v of vectors)assert.deepEqual(encodeFrame(v.type,v.seq,bytes(v.payload_hex)),bytes(v.wire_hex));
});
test('production RTL TX frame decodes with the documented TYPE82 layout',async()=>{
 // Captured from rtl/comm/performance_frame_tx.sv by build/web_protocol_alignment/tb.sv.
 const {readFile}=await import('node:fs/promises');
 const wire=Uint8Array.from((await readFile(new URL('./fixtures/rtl_tx_start.hex',import.meta.url),'utf8')).trim().split(/\s+/).map(x=>parseInt(x,16)));
 const frames=[];const reader=new FrameReader(f=>frames.push(f),e=>{throw e});reader.feed(wire);
 assert.equal(frames.length,2);
 assert.deepEqual([...frames[0].payload],[0x20,0]);
 assert.deepEqual(decodePerformance(frames[1]),{kind:0,flags:0,channel:7,slot:0,id:42,ordinal:256,tick:0,a:0,b:0});
});

test('recording accepts piano2/guitar2 channels and checks low eight ordinal bits after wrap',()=>{
 for(const channel of [6,7]){
  const recorder=new PerformanceRecorder({id:42,project:blankProject()});
  recorder.push(event({channel}));
  for(let ordinal=1;ordinal<=258;ordinal++)recorder.push(event({channel,kind:ordinal%2?1:2,ordinal,tick:ordinal*100,a:60|100<<8,b:0}));
  recorder.push(event({channel,kind:3,ordinal:259,tick:26000,a:0,b:258}));
  assert.equal(recorder.incomplete,false);assert.equal(recorder.track.channel,channel);assert.equal(recorder.track.notes.length,129);
 }
 assert.throws(()=>decodePerformance({...event({ordinal:256}),seq:1}),/序号/);
});

test('CONFIG retries identical bytes at most three times and wraps request sequence at 255',async()=>{
 const {link,wires}=mock();await link.connect(2000000);link.cfgSeq=255;
 await assert.rejects(link.configure(0x12,recordIdBytes(42),{timeoutMs:5}),/结果未知/);
 assert.equal(wires.length,4);for(const w of wires)assert.deepEqual(w,wires[0]);
 const request=link.configure(0x13,recordIdBytes(42));assert.equal(link.pendingConfig.seq,0);
 link.handleFrame({type:128,seq:0,payload:Uint8Array.from([0x13,0])});await request;await link.disconnect();
});
