import test from 'node:test';
import assert from 'node:assert/strict';
import {ReferenceSessionClient, FrameReader, TYPE, CONTROL} from '../src/protocol-v2.mjs';

const u16=n=>[n&255,n>>>8&255];
const u32=n=>[n&255,n>>>8&255,n>>>16&255,n>>>24&255];
function frame(wire) { let result; new FrameReader(f=>result=f).feed(wire); return result; }
function reply(client, command, seq, bytes) {
  return {type:TYPE.CONTROL_REPLY,seq,session:client.session,payload:Uint8Array.from([command,...bytes])};
}
function active() {
  const c=new ReferenceSessionClient({nonce:123,now:()=>0});
  const hello=frame(c.hello());
  c.handleFrame({type:TYPE.CONTROL_REPLY,seq:hello.seq,session:42,
    payload:Uint8Array.from([CONTROL.WELCOME,...u32(123),0,0,15,0,30,16])},0);
  const confirm=frame(c.confirm());
  c.handleFrame(reply(c,CONTROL.READY,confirm.seq,[0,0,0,0]),0);
  return c;
}
test('v2 phone times out even when the first PONG never arrives',()=>{
  const c=active();c.ping(0);
  assert.equal(c.heartbeatTimedOut(2001),true);
});
test('v2 duplicate PLAYBACK_READY cannot rewind transmitted MIDI',()=>{
  const c=active();
  c.handleFrame(reply(c,CONTROL.RESYNC_REQUIRED,0,[...u16(1),1]));
  const resume=frame(c.resume(1,0));
  const ready=reply(c,CONTROL.PLAYBACK_READY,resume.seq,[...u16(1),...u16(0)]);
  c.handleFrame(ready);c.midi([[0x90,60,100]]);
  c.handleFrame(ready);
  assert.equal(frame(c.midi([[0x80,60,0]])[0]).seq,1);
});
test('v2 old RESYNC notification cannot roll playback epoch backwards',()=>{
  const c=active();
  c.handleFrame(reply(c,CONTROL.RESYNC_REQUIRED,0,[...u16(1),1]));
  const resume=frame(c.resume(1,0));
  c.handleFrame(reply(c,CONTROL.PLAYBACK_READY,resume.seq,[...u16(1),...u16(0)]));
  c.midi([[0x90,60,100]]);
  c.handleFrame(reply(c,CONTROL.RESYNC_REQUIRED,0,[...u16(0),1]));
  assert.equal(c.epoch,1);assert.equal(c.active,true);assert.equal(c.nextMidiSeq,1);
});
