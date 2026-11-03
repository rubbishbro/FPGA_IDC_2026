// Consume bytes decoded from actual RTL UART pins; no model invents note timing.
import {existsSync} from 'node:fs';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {dirname,join} from 'node:path';
import assert from 'node:assert/strict';
import {FrameReader} from '../src/protocol.mjs';
import {PerformanceRecorder} from '../src/performance-recorder.mjs';
import {blankProject,validateProject} from '../src/model.mjs';
import {writeMidi,parseMidi} from '../src/midi-file.mjs';
// Resolve the default artifact paths from the repository root, not the caller's cwd.
const ROOT=fileURLToPath(new URL('../../../',import.meta.url));
const performancePath=join(ROOT,'build/performance_record/board_record/recording_uart.hex');
const boardSimPath=join(ROOT,'build/board_sim/recording_uart.hex');
// `run_board.py --test record` writes recording_uart.hex into its --out directory.
// Prefer the documented performance path, then fall back to the default board_sim path.
const input=process.argv[2]??(existsSync(performancePath)?performancePath:boardSimPath);
const output=process.argv[3]??join(ROOT,'build/performance_record/recorded-rtl.mid');
if(!existsSync(input))throw Error(`找不到 RTL UART 录制文件：${input}\n先运行：python3 sim/run_board.py --out build/performance_record/board_record --test record`);
const hex=await readFile(input,'utf8'),wire=Uint8Array.from(hex.trim().split(/\s+/).map(x=>parseInt(x,16)));
const project=blankProject(),recorder=new PerformanceRecorder({id:0xdbc01234,project});
let frames=0;const reader=new FrameReader(frame=>{frames++;if(frame.type===130)recorder.push(frame);},e=>{throw e;});
// Deliberately fragment the real pin stream to exercise browser read boundaries.
for(let i=0;i<wire.length;i+=7)reader.feed(wire.subarray(i,i+7));
assert.equal(recorder.ended,true);assert.equal(recorder.incomplete,false);assert.equal(recorder.track.notes.length,2);
// Current production default is piano low bank: router_pkg::note_first(INST_PIANO)=44,
// resources.json low group 44..59, and tb_instrument_board checks the same 44/64.
// Do not use the retired 40..76 legacy map here.
assert.deepEqual(recorder.track.notes.map(n=>[n.pitch,n.velocity]),[[44,64],[44,64]]);
assert.equal(recorder.track.channel,1);
project.tracks=[recorder.track];validateProject(project);
const midi=writeMidi(project);await mkdir(dirname(output),{recursive:true});await writeFile(output,midi);const parsed=parseMidi(midi).project;
assert.equal(parsed.tracks[0].notes.length,2);assert.equal(parsed.tracks[0].channel,1);
console.log(`PASS RTL UART → FrameReader → new track → MIDI roundtrip; ${frames} frames, ${recorder.track.notes.length} notes; ${output}`);
