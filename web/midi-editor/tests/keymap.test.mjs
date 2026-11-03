import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {KEYMAP_INSTRUMENTS,keymapData,applyKeymap} from '../src/keymap.mjs';
import {SerialLink} from '../src/serial.mjs';
import {FrameReader,encodeFrame} from '../src/protocol.mjs';
const pause=()=>new Promise(r=>setTimeout(r,1));
test('keymap ranges match production resource manifest for all 12 instruments',async()=>{
  const manifest=JSON.parse(await readFile(new URL('../../../rtl/router/tools/performance/resources.json',import.meta.url)));
  const names=['piano','guitar','flute','trumpet','cello','violin','oboe','drums','banjo','mandolin','piano_abc','guitar_abc'];
  for(const spec of KEYMAP_INSTRUMENTS){
    const actual=manifest.entries.filter(r=>r.name===names[spec.id]).map(r=>r.midi).sort((a,b)=>a-b);
    assert.deepEqual(spec.notes,actual);assert.equal(keymapData(spec.id,Array(16).fill(spec.notes[0])).length,32);
  }
  assert.throws(()=>keymapData(0,Array(16).fill(76)),/范围/);
  assert.throws(()=>keymapData(7,Array(16).fill(37)),/范围/);
  assert.throws(()=>keymapData(0,[60]),/16/);
  assert.throws(()=>keymapData(0,Array(16).fill(NaN)),/范围/);
});
test('keymap goes through serial CONFIG 0x20 and only matching device ACK completes it',async()=>{
  const frames=[];const link=new SerialLink();link.baud=2000000;
  const decoder=new FrameReader(f=>frames.push(f));link.writer={write:async wire=>decoder.feed(wire)};
  let complete=false;const promise=applyKeymap(link,10,Array.from({length:16},(_,i)=>44+i)).then(()=>complete=true);
  while(!frames.length)await pause();
  const frame=frames[0];assert.equal(frame.type,2);assert.equal(frame.payload.length,33);
  assert.deepEqual([...frame.payload],[0x20,...Array.from({length:16},(_,i)=>[10,44+i]).flat()]);
  assert.equal(complete,false);
  link.decoder.feed(encodeFrame(128,(frame.seq+1)&255,[0x20,0]));assert.equal(complete,false);
  link.decoder.feed(encodeFrame(128,frame.seq,[0x02,0]));assert.equal(complete,false);
  link.decoder.feed(encodeFrame(128,frame.seq,[0x20,0]));await promise;assert.equal(complete,true);
  await link.pumpTask;
});
test('keymap reports board rejection and disconnect instead of claiming success',async()=>{
  for(const result of [3,4,6,'disconnect']){
    const frames=[];const link=new SerialLink();link.baud=2000000;
    const decoder=new FrameReader(f=>frames.push(f));link.writer={write:async wire=>decoder.feed(wire)};
    const p=applyKeymap(link,7,Array(16).fill(36));const rejected=assert.rejects(p,/设备配置失败|断开/);
    while(!frames.length)await pause();
    if(result==='disconnect')link.failConfig(Error('串口已断开'));
    else link.decoder.feed(encodeFrame(128,frames[0].seq,[0x20,result]));
    await rejected;await link.pumpTask;assert.equal(link.pendingConfig,null);
  }
});
