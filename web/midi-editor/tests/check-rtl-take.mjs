// Consume bytes decoded from actual RTL UART pins; no model invents note timing.
import {readFile,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {FrameReader} from '../src/protocol.mjs';
import {PerformanceRecorder} from '../src/performance-recorder.mjs';
import {blankProject,validateProject} from '../src/model.mjs';
import {writeMidi,parseMidi} from '../src/midi-file.mjs';
const input=process.argv[2]??'build/performance_record/board_record/recording_uart.hex';
const output=process.argv[3]??'build/performance_record/recorded-rtl.mid';
const hex=await readFile(input,'utf8'),wire=Uint8Array.from(hex.trim().split(/\s+/).map(x=>parseInt(x,16)));
const project=blankProject(),recorder=new PerformanceRecorder({id:0xdbc01234,project});
let frames=0;const reader=new FrameReader(frame=>{frames++;if(frame.type===130)recorder.push(frame);},e=>{throw e;});
// Deliberately fragment the real pin stream to exercise browser read boundaries.
for(let i=0;i<wire.length;i+=7)reader.feed(wire.subarray(i,i+7));
assert.equal(recorder.ended,true);assert.equal(recorder.incomplete,false);assert.equal(recorder.track.notes.length,2);
assert.deepEqual(recorder.track.notes.map(n=>[n.pitch,n.velocity]),[[40,64],[40,64]]);
project.tracks=[recorder.track];validateProject(project);
const midi=writeMidi(project);await writeFile(output,midi);const parsed=parseMidi(midi).project;
assert.equal(parsed.tracks[0].notes.length,2);assert.equal(parsed.tracks[0].channel,1);
console.log(`PASS RTL UART → FrameReader → new track → MIDI roundtrip; ${frames} frames, ${recorder.track.notes.length} notes; ${output}`);
