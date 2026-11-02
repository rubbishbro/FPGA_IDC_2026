import test from 'node:test';
import assert from 'node:assert/strict';
import {SerialLink} from '../src/serial.mjs';
import {FrameReader,encodeFrame} from '../src/protocol.mjs';
function mockLink(){
  const wires=[],frames=[];let closeCount=0,cancelCount=0,pendingRead;
  const api={addEventListener(){},requestPort:async()=>port};
  const writer={write:async wire=>wires.push(wire),ready:Promise.resolve(),releaseLock(){}};
  const port={open:async()=>{},writable:{getWriter:()=>writer},readable:{getReader:()=>({read:()=>new Promise(r=>pendingRead=r),cancel:async()=>{cancelCount++;pendingRead?.({done:true});},releaseLock(){}})},close:async()=>{closeCount++;}};
  const link=new SerialLink(()=>{},()=>{},api);link.baud=2000000;
  const decode=()=>{const reader=new FrameReader(f=>frames.push(f));for(const w of wires)reader.feed(w);return frames;};
  return {link,writer,wires,decode,receive(value){pendingRead({value,done:false});},get closeCount(){return closeCount;},get cancelCount(){return cancelCount;}};
}
test('serial writes valid independently decodable frames and disconnects the stream',async()=>{
  const m=mockLink();await m.link.connect(2000000);await m.link.send([[0x91,60,90],[0x81,60,0]]);assert.equal(m.wires.length,1);const [f]=m.decode();assert.deepEqual([...f.payload],[0x91,60,90,0x81,60,0]);assert.equal(m.link.txBytes,m.wires[0].length);await m.link.disconnect();assert.equal(m.cancelCount,1);assert.equal(m.closeCount,1);assert.equal(m.link.connected,false);
});
test('panic cancels unsent note frames, then queues complete all-sound-off messages',async()=>{
  const m=mockLink();await m.link.connect(2000000);
  let release; m.writer.write=wire=>{m.wires.push(wire);return new Promise(r=>release=r);};
  const notes=m.link.send(Array.from({length:25},(_,i)=>[0x91,40+i,100])).catch(e=>e);
  const panic=m.link.panic([1]);release();await new Promise(r=>setTimeout(r,5));release();await panic;
  assert.equal((await notes).name,'AbortError');const frames=m.decode();assert.equal(frames.length,2);assert.deepEqual([...frames[1].payload],[0xb1,64,0,0xb1,120,0]);await m.link.disconnect();
});
test('disconnect waits for a current frame and cancels its unsent successors',async()=>{
  const m=mockLink();await m.link.connect(2000000);let release,lockReleased=false;
  m.writer.write=wire=>{m.wires.push(wire);return new Promise(r=>release=r);};m.writer.releaseLock=()=>lockReleased=true;
  const sent=m.link.send(Array.from({length:30},()=>[0x91,60,90])).catch(e=>e);const disconnect=m.link.disconnect();
  await Promise.resolve();assert.equal(lockReleased,false);release();await disconnect;assert.equal(lockReleased,true);assert.equal(m.wires.length,1);assert.equal((await sent).name,'AbortError');
});
test('write failure cancels the queue and makes the link unavailable without retry',async()=>{
  const m=mockLink();await m.link.connect(2000000);let faults=0;m.link.onFault=()=>faults++;
  m.writer.write=async()=>{throw Error('USB removed');};await assert.rejects(m.link.send([[0x91,60,90]]));assert.equal(faults,1);assert.equal(m.link.connected,false);await assert.rejects(m.link.send([[0x81,60,0]]));await m.link.disconnect();
});
test('diagnostics distinguish raw RX bytes, rejected CRC and valid performance frames',async()=>{
  const m=mockLink();await m.link.connect(115200);
  const ack=encodeFrame(128,1,[0x12,0]),bad=Uint8Array.from(ack);bad[4]^=1;
  const perf=encodeFrame(130,0,new Uint8Array(24));
  const bytes=Uint8Array.from([...ack,...bad,...perf]);m.receive(bytes);
  await new Promise(resolve=>setImmediate(resolve));
  const report=m.link.diagnostics();
  assert.equal(report.rxBytes,bytes.length);assert.equal(report.rxFrames,2);
  assert.equal(report.rxErrors,1);assert.match(report.lastRxError,/CRC/);
  assert.equal(report.performanceFrames,1);assert.equal(report.trace[0].direction,'RX');
  assert.deepEqual(report.trace[0].hex.split(' ').map(x=>parseInt(x,16)),[...bytes]);
  await m.link.send([[0x91,21,64]]);assert.equal(m.link.diagnostics().trace.at(-1).direction,'TX');
  await m.link.disconnect();assert.equal(m.link.diagnostics().connected,false);
});
test('wire diagnostic history stays bounded and exports a detached snapshot',()=>{
  const m=mockLink();for(let i=0;i<200;i++)m.link.traceWire('RX',new Uint8Array(100).fill(i&255));
  let report=m.link.diagnostics();assert.ok(report.trace.length<=128);
  assert.ok(report.trace.reduce((sum,x)=>sum+x.bytes,0)<=8192);
  report.trace[0].hex='changed';assert.notEqual(m.link.diagnostics().trace[0].hex,'changed');
  m.link.traceWire('RX',new Uint8Array(20000));report=m.link.diagnostics();
  assert.equal(report.trace.length,1);assert.equal(report.trace[0].bytes,8192);
});
