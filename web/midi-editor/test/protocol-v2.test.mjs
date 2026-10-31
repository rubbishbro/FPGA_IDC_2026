import test from 'node:test';
import assert from 'node:assert/strict';

import {
  CLIENT_PHASE,
  CONTROL,
  DEVICE_STATE,
  FrameReader,
  PROTOCOL_VERSION,
  REASON,
  ReferenceSessionClient,
  SLIP,
  TYPE,
  crc16,
  decodeBody,
  encodeFrame,
  packMidi,
} from '../src/protocol-v2.mjs';

// ---------------------------------------------------------------------------
// Independent fixtures and small test-only helpers.
// ---------------------------------------------------------------------------

// These wire bytes were produced by a separate Python CRC-16/CCITT-FALSE +
// SLIP implementation, not by encodeFrame(). They deliberately contain escaped
// 0xC0 and 0xDB bytes in header and payload fields.
const MIDI_FIXTURE_HEX = 'c00201dbdc00050012dbdddbdc000100903c4097c7c0';
const PING_FIXTURE_HEX = 'c00203dbdd0006002a0000000301dbdd000100d652c0';

const fixtures = [
  {
    name: 'MIDI note-on, escaped seq/session',
    hex: MIDI_FIXTURE_HEX,
    bodyHex: '0201c000050012dbc0000100903c4097c7',
    fields: {
      type: TYPE.MIDI,
      seq: 0x00c0,
      session: 0x00c0db12,
      payload: [0x01, 0x00, 0x90, 0x3c, 0x40],
    },
  },
  {
    name: 'CONTROL PING, escaped seq/last_midi_seq',
    hex: PING_FIXTURE_HEX,
    bodyHex: '0203db0006002a0000000301db000100d652',
    fields: {
      type: TYPE.CONTROL,
      seq: 0x00db,
      session: 0x0000002a,
      payload: [0x03, 0x01, 0xdb, 0x00, 0x01, 0x00],
    },
  },
];

function bytesFromHex(text) {
  const clean = text.replace(/\s+/g, '');
  assert.equal(clean.length % 2, 0);
  return Uint8Array.from(Buffer.from(clean, 'hex'));
}

function hexFromBytes(bytes) {
  return Buffer.from(bytes).toString('hex');
}

function u16(value) {
  return [value & 0xff, (value >>> 8) & 0xff];
}

function u32(value) {
  return [value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff];
}

function concat(...chunks) {
  const length = chunks.reduce((total, chunk) => total + chunk.length, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

// Test-only SLIP encoder used to build malformed wires. Valid fixture bytes
// above are independent constants, not the output of this helper.
function slipBytes(body) {
  const out = [SLIP.END];
  for (const byte of body) {
    if (byte === SLIP.END) out.push(SLIP.ESC, SLIP.ESC_END);
    else if (byte === SLIP.ESC) out.push(SLIP.ESC, SLIP.ESC_ESC);
    else out.push(byte);
  }
  out.push(SLIP.END);
  return Uint8Array.from(out);
}

function makeBody({
  version = PROTOCOL_VERSION,
  type = TYPE.MIDI,
  seq = 1,
  session = 1,
  payload = [0x01, 0x00, 0x90, 0x3c, 0x40],
  declaredLength = payload.length,
  crc,
} = {}) {
  const header = [version, type, ...u16(seq), ...u16(declaredLength), ...u32(session), ...payload];
  const crcValue = crc === undefined ? crc16(header) : crc;
  return Uint8Array.from([...header, ...u16(crcValue)]);
}

function collect(input) {
  const frames = [];
  const errors = [];
  const reader = new FrameReader(
    (frame) => frames.push(frame),
    (error) => errors.push(error),
  );
  reader.feed(input);
  return {frames, errors};
}

function onlyFrame(wire) {
  const {frames, errors} = collect(wire);
  assert.equal(errors.length, 0, errors[0]?.message);
  assert.equal(frames.length, 1);
  return frames[0];
}

function controlReply(command, seq, session, extra = []) {
  return encodeFrame(TYPE.CONTROL_REPLY, seq, session, [command, ...extra]);
}

function bootActive(nonce = 0x11223344, session = 0x00c0db12, epoch = 0) {
  const client = new ReferenceSessionClient({nonce, now: () => 0});
  const helloWire = client.hello();
  const hello = onlyFrame(helloWire);
  assert.equal(hello.type, TYPE.CONTROL);
  assert.equal(hello.session, 0);
  assert.deepEqual([...hello.payload], [CONTROL.HELLO, ...u32(nonce)]);

  const welcomeWire = controlReply(CONTROL.WELCOME, hello.seq, session, [
    ...u32(nonce),
    ...u16(epoch),
    ...u16(0x000f),
    30,
    16,
  ]);
  const welcome = onlyFrame(welcomeWire);
  const welcomeResult = client.handleFrame(welcome);
  assert.deepEqual(welcomeResult, {accepted: true, event: 'welcome'});
  assert.equal(client.session, session);
  assert.equal(client.phase, CLIENT_PHASE.WELCOME);
  assert.equal(client.epoch, epoch);
  assert.equal(client.maxMidi, 30);
  assert.equal(client.maxConfig, 16);

  const confirmWire = client.confirm();
  const confirm = onlyFrame(confirmWire);
  assert.equal(confirm.session, session);
  assert.deepEqual([...confirm.payload], [CONTROL.CONFIRM, ...u32(nonce)]);

  const readyWire = controlReply(CONTROL.READY, confirm.seq, session, [...u16(epoch), ...u16(0)]);
  const ready = onlyFrame(readyWire);
  const readyResult = client.handleFrame(ready);
  assert.deepEqual(readyResult, {accepted: true, event: 'ready'});
  assert.equal(client.phase, CLIENT_PHASE.ACTIVE);
  assert.equal(client.expectedMidiSeq, 0);
  assert.equal(client.nextMidiSeq, 0);

  return {client, hello, welcome, confirm, ready};
}

// ---------------------------------------------------------------------------
// CRC and independent wire fixtures.
// ---------------------------------------------------------------------------

test('crc16 matches the CCITT-FALSE known vector and fixed reference vectors', () => {
  const ascii = Uint8Array.from(Buffer.from('123456789', 'ascii'));
  assert.equal(crc16(ascii), 0x29b1);
  assert.equal(crc16(new Uint8Array(0)), 0xffff);
  assert.equal(crc16(Uint8Array.from([0x00])), 0xe1f0);
  assert.equal(crc16(Uint8Array.from([0xff, 0xff])), 0x0000);
});

test('manual v2 wire fixtures decode to exact fields and re-encode byte-for-byte', () => {
  for (const fixture of fixtures) {
    const wire = bytesFromHex(fixture.hex);
    const body = bytesFromHex(fixture.bodyHex);
    const decoded = decodeBody(body);

    assert.equal(decoded.version, PROTOCOL_VERSION, fixture.name);
    assert.equal(decoded.type, fixture.fields.type, fixture.name);
    assert.equal(decoded.seq, fixture.fields.seq, fixture.name);
    assert.equal(decoded.session, fixture.fields.session, fixture.name);
    assert.deepEqual([...decoded.payload], fixture.fields.payload, fixture.name);

    const viaReader = onlyFrame(wire);
    assert.deepEqual(
      {...decoded, payload: [...decoded.payload]},
      {...viaReader, payload: [...viaReader.payload]},
      fixture.name,
    );

    const reencoded = encodeFrame(
      fixture.fields.type,
      fixture.fields.seq,
      fixture.fields.session,
      fixture.fields.payload,
    );
    assert.equal(hexFromBytes(reencoded), fixture.hex, fixture.name);
  }
});

test('FrameReader decodes every possible two-chunk split, byte-wise, and coalesced', () => {
  for (const fixture of fixtures) {
    const wire = bytesFromHex(fixture.hex);
    for (let split = 1; split < wire.length; split++) {
      const frames = [];
      const errors = [];
      const reader = new FrameReader(
        (frame) => frames.push(frame),
        (error) => errors.push(error),
      );
      reader.feed(wire.subarray(0, split));
      reader.feed(wire.subarray(split));
      assert.equal(errors.length, 0, `${fixture.name} split ${split}: ${errors[0]?.message}`);
      assert.equal(frames.length, 1, `${fixture.name} split ${split}`);
      assert.deepEqual([...frames[0].payload], fixture.fields.payload);
    }

    const bytewise = collect(wire);
    assert.equal(bytewise.errors.length, 0);
    assert.equal(bytewise.frames.length, 1);
    assert.deepEqual([...bytewise.frames[0].payload], fixture.fields.payload);
  }

  const both = collect(concat(bytesFromHex(MIDI_FIXTURE_HEX), bytesFromHex(PING_FIXTURE_HEX)));
  assert.equal(both.errors.length, 0);
  assert.equal(both.frames.length, 2);
  assert.equal(both.frames[0].type, TYPE.MIDI);
  assert.equal(both.frames[1].type, TYPE.CONTROL);

  // RFC 1055 also permits adjacent frames sharing one C0 delimiter.
  const first = bytesFromHex(MIDI_FIXTURE_HEX);
  const shared = collect(concat(first.subarray(0, first.length - 1), bytesFromHex(PING_FIXTURE_HEX)));
  assert.equal(shared.errors.length, 0);
  assert.equal(shared.frames.length, 2);
});

// ---------------------------------------------------------------------------
// Header, length, and CRC constraints.
// ---------------------------------------------------------------------------

test('decodeBody rejects bad version, type, length, per-type limits, and CRC', () => {
  assert.throws(() => decodeBody(makeBody({version: 1})), /协议版本错误/);
  assert.throws(() => decodeBody(makeBody({type: 0x04})), /协议类型错误/);
  assert.throws(() => decodeBody(makeBody({declaredLength: 0})), /帧长错误/);
  assert.throws(() => decodeBody(makeBody({declaredLength: 0xffff})), /帧长错误/);
  assert.throws(() => decodeBody(makeBody({type: TYPE.MIDI, payload: [0x01, 0x00]})), /帧头错误/);
  assert.throws(() => decodeBody(makeBody({type: TYPE.CONFIG, payload: new Array(17).fill(1)})), /帧头错误/);
  assert.throws(
    () => decodeBody(makeBody({type: TYPE.CONFIG_REPLY, payload: [0x81, 1, 2, 3]})),
    /帧头错误/,
  );
  assert.throws(() => decodeBody(makeBody({crc: 0})), /CRC 错误/);

  const tooLong = Uint8Array.from([...makeBody({type: TYPE.CONTROL, payload: new Array(32).fill(1)}), 0]);
  assert.throws(() => decodeBody(tooLong), /帧长错误/);
  assert.throws(() => decodeBody(makeBody().subarray(0, 8)), /帧长错误/);
});

test('encodeFrame/decodeBody round-trip all types, u32 sessions, and maximum payloads', () => {
  const cases = [
    [TYPE.MIDI, 0x1234, 0x89abcdef, [0x12, 0x34, 0x90, 0x3c, 0x7f]],
    [TYPE.CONFIG, 0, 0, new Array(16).fill(0x7f)],
    [TYPE.CONTROL, 0xffff, 0xffffffff, [0x01, ...new Array(31).fill(0x55)]],
    [TYPE.CONFIG_REPLY, 7, 42, [0x81, 0xaa, 0x55]],
    [TYPE.CONTROL_REPLY, 8, 9, [0x84, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00]],
  ];

  for (const [type, seq, session, payload] of cases) {
    const wire = encodeFrame(type, seq, session, payload);
    assert.equal(wire[0], SLIP.END);
    assert.equal(wire[wire.length - 1], SLIP.END);
    const decoded = onlyFrame(wire);
    assert.equal(decoded.type, type);
    assert.equal(decoded.seq, seq);
    assert.equal(decoded.session, session >>> 0);
    assert.deepEqual([...decoded.payload], payload);
  }

  // 32 control bytes alternating C0/DB produce an escaped wire, but it must
  // remain within the contract's 90-byte worst case and decode intact.
  const escapedPayload = Array.from({length: 32}, (_, index) => (index % 2 ? 0xdb : 0xc0));
  const escapedWire = encodeFrame(TYPE.CONTROL, 0xc0db, 0x00, escapedPayload);
  assert.ok(escapedWire.length <= 90);
  assert.deepEqual([...onlyFrame(escapedWire).payload], escapedPayload);
});

test('encodeFrame rejects invalid types, fields, lengths, and payload bytes', () => {
  const midi = [0x01, 0x00, 0x90, 0x3c, 0x40];
  assert.throws(() => encodeFrame(0x00, 1, 0, midi), /非法协议类型/);
  assert.throws(() => encodeFrame(0x04, 1, 0, midi), /非法协议类型/);
  assert.throws(() => encodeFrame(TYPE.MIDI, -1, 0, midi), /seq/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 0x10000, 0, midi), /seq/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1.5, 0, midi), /seq/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, -1, midi), /session/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, 2 ** 32, midi), /session/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, 0, []), /payload 长度/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, 0, [0x01, 0x00]), /payload 长度/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, 0, [...midi, ...new Array(29).fill(0)]), /payload 长度/);
  assert.throws(() => encodeFrame(TYPE.CONFIG, 1, 0, new Array(17).fill(1)), /payload 长度/);
  assert.throws(() => encodeFrame(TYPE.CONFIG_REPLY, 1, 0, [1, 2]), /payload 长度/);
  assert.throws(() => encodeFrame(TYPE.CONFIG_REPLY, 1, 0, [1, 2, 3, 4]), /payload 长度/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, 0, [0x01, 0x00, 0x90, 0x3c, 256]), /payload/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, 0, [0x01, 0x00, 0x90, 0x3c, -1]), /payload/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, 0, [0x01, 0x00, 0x90, 0x3c, 1.5]), /payload/);
  assert.throws(() => encodeFrame(TYPE.MIDI, 1, 0, '0100903c40'), /payload/);
});

// ---------------------------------------------------------------------------
// SLIP reader robustness.
// ---------------------------------------------------------------------------

test('FrameReader rejects invalid escapes, incomplete escapes, oversize bodies, and CRC errors', () => {
  const invalidEscape = collect(Uint8Array.from([SLIP.END, 0x02, SLIP.ESC, 0x00, SLIP.END]));
  assert.equal(invalidEscape.frames.length, 0);
  assert.equal(invalidEscape.errors.length, 1);
  assert.match(invalidEscape.errors[0].message, /SLIP/);

  const incompleteEscape = collect(Uint8Array.from([SLIP.END, 0x02, SLIP.ESC, SLIP.END]));
  assert.equal(incompleteEscape.frames.length, 0);
  assert.equal(incompleteEscape.errors.length, 1);
  assert.match(incompleteEscape.errors[0].message, /转义不完整/);

  const oversize = collect(Uint8Array.from([SLIP.END, ...new Array(45).fill(0), SLIP.END]));
  assert.equal(oversize.frames.length, 0);
  assert.equal(oversize.errors.length, 1);
  assert.match(oversize.errors[0].message, /帧长|长度/);

  const badCrcWire = bytesFromHex(MIDI_FIXTURE_HEX);
  badCrcWire[badCrcWire.length - 2] ^= 0xff;
  const badCrc = collect(badCrcWire);
  assert.equal(badCrc.frames.length, 0);
  assert.equal(badCrc.errors.length, 1);
  assert.match(badCrc.errors[0].message, /CRC/);

  const splitBadEscape = collect(Uint8Array.from([SLIP.END, 0x02, SLIP.ESC, 0x00, SLIP.END]));
  assert.equal(splitBadEscape.frames.length, 0);
  assert.equal(splitBadEscape.errors.length, 1);
});

test('FrameReader ignores noise/empty frames and recovers after a bad frame', () => {
  const empty = collect(Uint8Array.from([SLIP.END, SLIP.END, SLIP.END]));
  assert.equal(empty.frames.length, 0);
  assert.equal(empty.errors.length, 0);

  const noisy = collect(concat(Uint8Array.from([1, 2, 3, 4]), bytesFromHex(MIDI_FIXTURE_HEX)));
  assert.equal(noisy.errors.length, 0);
  assert.equal(noisy.frames.length, 1);

  const badMiddle = Uint8Array.from([SLIP.END, 0x02, SLIP.ESC, 0x00, SLIP.END]);
  const recovered = collect(
    concat(bytesFromHex(MIDI_FIXTURE_HEX), badMiddle, bytesFromHex(PING_FIXTURE_HEX)),
  );
  assert.equal(recovered.frames.length, 2);
  assert.equal(recovered.errors.length, 1);
  assert.equal(recovered.frames[0].type, TYPE.MIDI);
  assert.equal(recovered.frames[1].type, TYPE.CONTROL);
});

// ---------------------------------------------------------------------------
// MIDI packing.
// ---------------------------------------------------------------------------

test('packMidi adds the epoch prefix to every packet and limits actual MIDI to 30 bytes', () => {
  assert.deepEqual(packMidi([], 0x1234), []);

  const single = packMidi([[0x90, 60, 90]], 0x1234);
  assert.equal(single.length, 1);
  assert.deepEqual([...single[0]], [0x34, 0x12, 0x90, 60, 90]);

  const tenNotes = Array.from({length: 10}, (_, index) => [0x90, 40 + index, 100]);
  const ten = packMidi(tenNotes, 0xffff);
  assert.equal(ten.length, 1);
  assert.equal(ten[0].length, 32); // 2 epoch + 30 MIDI
  assert.deepEqual([...ten[0].subarray(0, 2)], [0xff, 0xff]);
  assert.equal(ten[0].length - 2, 30);

  const eleven = packMidi([...tenNotes, [0x90, 60, 90]], 0);
  assert.equal(eleven.length, 2);
  assert.equal(eleven[0].length, 32);
  assert.equal(eleven[1].length, 5);
  assert.deepEqual([...eleven[1]], [0x00, 0x00, 0x90, 60, 90]);
  for (const packet of eleven) assert.ok(packet.length - 2 <= 30);

  const twoByte = packMidi([[0xc0, 5], [0xd0, 6]], 7);
  assert.equal(twoByte.length, 1);
  assert.deepEqual([...twoByte[0]], [0x07, 0x00, 0xc0, 5, 0xd0, 6]);

  // Never split a message: 27 bytes + a 3-byte message exactly fills a packet.
  const boundary = packMidi([...Array.from({length: 9}, () => [0x90, 1, 2]), [0x80, 1, 0]], 0);
  assert.equal(boundary.length, 1);
  assert.equal(boundary[0].length, 32);
  assert.deepEqual([...boundary[0].subarray(-3)], [0x80, 1, 0]);
});

test('packMidi rejects malformed short messages and bad epochs', () => {
  assert.throws(() => packMidi([[0x90, 60]], 0), /MIDI/);
  assert.throws(() => packMidi([[0x90, 60, 90, 0]], 0), /MIDI/);
  assert.throws(() => packMidi([[0xf0, 60, 90]], 0), /MIDI/);
  assert.throws(() => packMidi([[60, 60, 90]], 0), /MIDI/);
  assert.throws(() => packMidi([[0x90, 60, 128]], 0), /MIDI 数据字节/);
  assert.throws(() => packMidi([[0xc0, 128]], 0), /MIDI 数据字节/);
  assert.throws(() => packMidi([[]], 0), /MIDI/);
  assert.throws(() => packMidi([[0x90, 60, 90]], -1), /epoch/);
  assert.throws(() => packMidi([[0x90, 60, 90]], 0x10000), /epoch/);
  assert.throws(() => packMidi(null, 0), /MIDI 消息列表/);
});

// ---------------------------------------------------------------------------
// Reference session client.
// ---------------------------------------------------------------------------

test('reference client handshake, MIDI sequence, duplicate READY, and heartbeat watermarks', () => {
  const {client, ready} = bootActive();
  assert.equal(client.hasSession, true);
  assert.equal(client.active, true);
  assert.equal(client.deviceState, DEVICE_STATE.ACTIVE);
  assert.equal(client.dueForPing(0), true);

  const firstPingWire = client.ping(1000);
  const firstPing = onlyFrame(firstPingWire);
  assert.equal(firstPing.session, client.session);
  assert.deepEqual([...firstPing.payload], [CONTROL.PING, 0, 0, 0, 0, 0]);
  assert.equal(client.lastPingAt, 1000);
  assert.equal(client.dueForPing(1499), false);
  assert.equal(client.dueForPing(1500), true);

  const pong = onlyFrame(
    controlReply(CONTROL.PONG, firstPing.seq, client.session, [DEVICE_STATE.ACTIVE, ...u16(0), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(pong, 1050), {accepted: true, event: 'pong'});
  assert.equal(client.lastPongAt, 1050);
  assert.equal(client.lastRttMs, 50);
  assert.equal(client.heartbeatAgeMs(1050), 0);
  assert.equal(client.heartbeatAgeMs(2050), 1000);
  assert.equal(client.heartbeatTimedOut(2050, 2000), false);
  assert.equal(client.heartbeatTimedOut(3051, 2000), true);

  const noteFrames = client.midi(Array.from({length: 11}, (_, index) => [0x90, 40 + index, 100]));
  assert.equal(noteFrames.length, 2);
  assert.deepEqual([...onlyFrame(noteFrames[0]).payload.subarray(0, 2)], [0, 0]);
  assert.equal(onlyFrame(noteFrames[0]).seq, 0);
  assert.equal(onlyFrame(noteFrames[1]).seq, 1);
  assert.equal(client.lastMidiSeq, 1);
  assert.equal(client.nextMidiSeq, 2);

  const secondPing = onlyFrame(client.ping(2000));
  assert.deepEqual([...secondPing.payload], [CONTROL.PING, 1, 1, 0, 0, 0]);

  // A duplicate READY is idempotent and must not rewind the host send pointer.
  const duplicateReady = onlyFrame(
    controlReply(CONTROL.READY, ready.seq, client.session, [...u16(0), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(duplicateReady), {accepted: true, event: 'ready'});
  assert.equal(client.nextMidiSeq, 2);
  const nextNote = onlyFrame(client.midi([[0x80, 40, 0]])[0]);
  assert.equal(nextNote.seq, 2);

  const statusWire = client.statusGet();
  const status = onlyFrame(statusWire);
  assert.deepEqual([...status.payload], [CONTROL.STATUS_GET]);
  const statusReply = onlyFrame(
    controlReply(CONTROL.STATUS, status.seq, client.session, [
      DEVICE_STATE.ACTIVE,
      ...u16(0),
      ...u16(3),
      REASON.NONE,
    ]),
  );
  assert.deepEqual(client.handleFrame(statusReply), {accepted: true, event: 'status'});
  assert.equal(client.expectedMidiSeq, 3);
  assert.equal(client.reason, REASON.NONE);
});

test('reference client rejects wrong nonce and stale session replies', () => {
  const preHello = new ReferenceSessionClient({nonce: 0x01020304, now: () => 0});
  const unsolicitedWelcome = onlyFrame(
    controlReply(CONTROL.WELCOME, 1, 7, [...u32(0x01020304), ...u16(0), 0, 0, 30, 16]),
  );
  assert.equal(preHello.handleFrame(unsolicitedWelcome).reason, 'not_awaiting_welcome');
  assert.equal(preHello.session, 0);

  const fresh = new ReferenceSessionClient({nonce: 0x01020304, now: () => 0});
  const hello = onlyFrame(fresh.hello());
  const wrongNonce = onlyFrame(
    controlReply(CONTROL.WELCOME, hello.seq, 7, [...u32(0x01020305), ...u16(0), 0, 0, 30, 16]),
  );
  assert.deepEqual(fresh.handleFrame(wrongNonce), {
    accepted: false,
    event: 'ignored',
    reason: 'nonce_mismatch',
  });
  assert.equal(fresh.session, 0);
  assert.equal(fresh.phase, CLIENT_PHASE.HELLO_SENT);

  const zeroSession = onlyFrame(
    controlReply(CONTROL.WELCOME, hello.seq, 0, [...u32(0x01020304), ...u16(0), 0, 0, 30, 16]),
  );
  assert.equal(fresh.handleFrame(zeroSession).reason, 'bad_fields');

  const {client, confirm} = bootActive(0x11223344, 0x12345678);
  const staleReady = onlyFrame(
    controlReply(CONTROL.READY, confirm.seq, 0x12345679, [...u16(0), ...u16(5)]),
  );
  assert.deepEqual(client.handleFrame(staleReady), {
    accepted: false,
    event: 'ignored',
    reason: 'stale_session',
  });
  assert.equal(client.phase, CLIENT_PHASE.ACTIVE);
  assert.equal(client.expectedMidiSeq, 0);

  const staleResync = onlyFrame(
    controlReply(CONTROL.RESYNC_REQUIRED, 0, 0x12345679, [...u16(1), REASON.MIDI_GAP]),
  );
  assert.equal(client.handleFrame(staleResync).reason, 'stale_session');
  assert.equal(client.phase, CLIENT_PHASE.ACTIVE);
});

test('reference client rejects stale epochs and performs RESUME/PLAYBACK_READY recovery', () => {
  const {client} = bootActive(0x11223344, 0x0000002a, 0);
  const ping = onlyFrame(client.ping(100));

  const stalePong = onlyFrame(
    controlReply(CONTROL.PONG, ping.seq, client.session, [DEVICE_STATE.ACTIVE, ...u16(1), ...u16(99)]),
  );
  assert.deepEqual(client.handleFrame(stalePong, 110), {
    accepted: false,
    event: 'ignored',
    reason: 'stale_epoch',
  });
  assert.equal(client.lastPongAt, null);

  const validPong = onlyFrame(
    controlReply(CONTROL.PONG, ping.seq, client.session, [DEVICE_STATE.ACTIVE, ...u16(0), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(validPong, 120), {accepted: true, event: 'pong'});

  client.midi([[0x90, 60, 90]]);
  assert.equal(client.lastMidiSeq, 0);

  const resync = onlyFrame(
    controlReply(CONTROL.RESYNC_REQUIRED, 0, client.session, [...u16(1), REASON.MIDI_GAP]),
  );
  assert.deepEqual(client.handleFrame(resync), {accepted: true, event: 'resync_required'});
  assert.equal(client.phase, CLIENT_PHASE.RESYNC);
  assert.equal(client.epoch, 1);
  assert.equal(client.nextMidiSeq, 0);
  assert.equal(client.lastMidiSeq, null);
  assert.equal(client.reason, REASON.MIDI_GAP);

  const resumeWire = client.resume();
  const resume = onlyFrame(resumeWire);
  assert.deepEqual([...resume.payload], [CONTROL.RESUME, ...u16(1), ...u16(0)]);
  assert.equal(client.phase, CLIENT_PHASE.RESUME_SENT);

  const stalePlayback = onlyFrame(
    controlReply(CONTROL.PLAYBACK_READY, resume.seq, client.session, [...u16(0), ...u16(0)]),
  );
  assert.equal(client.handleFrame(stalePlayback).reason, 'stale_epoch');
  assert.equal(client.phase, CLIENT_PHASE.RESUME_SENT);

  const playback = onlyFrame(
    controlReply(CONTROL.PLAYBACK_READY, resume.seq, client.session, [...u16(1), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(playback), {accepted: true, event: 'playback_ready'});
  assert.equal(client.phase, CLIENT_PHASE.ACTIVE);
  assert.equal(client.epoch, 1);
  assert.equal(client.nextMidiSeq, 0);

  const recoveredNote = onlyFrame(client.midi([[0x80, 60, 0]])[0]);
  assert.equal(recoveredNote.seq, 0);
  assert.deepEqual([...recoveredNote.payload], [0x01, 0x00, 0x80, 60, 0]);
});

test('reference client handles ERROR, FAULT, config replies, and control seq wrap', () => {
  const {client} = bootActive(0x11223344, 42, 0);

  const config = onlyFrame(client.config([0x01, 0x10, 0x20]));
  assert.equal(config.type, TYPE.CONFIG);
  const configReply = onlyFrame(encodeFrame(TYPE.CONFIG_REPLY, config.seq, client.session, [0x81, 0x00, 0x01]));
  assert.deepEqual(client.handleFrame(configReply), {accepted: true, event: 'config_reply'});
  assert.deepEqual([...client.lastConfigReply], [0x81, 0x00, 0x01]);

  const status = onlyFrame(client.statusGet());
  const error = onlyFrame(controlReply(CONTROL.ERROR, status.seq, client.session, [CONTROL.STATUS_GET, 2]));
  assert.deepEqual(client.handleFrame(error), {accepted: true, event: 'error'});
  assert.deepEqual(client.lastError, {seq: status.seq, command: CONTROL.STATUS_GET, result: 2});

  client.nextControlSeq = 0xffff;
  const wrapStatus = onlyFrame(client.statusGet());
  assert.equal(wrapStatus.seq, 0xffff);
  assert.equal(client.nextControlSeq, 1);

  const fault = onlyFrame(controlReply(CONTROL.FAULT, 0, client.session, [REASON.PHYSICAL_FAULT]));
  assert.deepEqual(client.handleFrame(fault), {accepted: true, event: 'fault'});
  assert.equal(client.phase, CLIENT_PHASE.FAULT);
  assert.throws(() => client.midi([[0x90, 60, 90]]), /ACTIVE/);

  // HELLO after a fault uses header session 0 and resets the client view.
  const hello = onlyFrame(client.hello());
  assert.equal(hello.session, 0);
  assert.equal(client.phase, CLIENT_PHASE.HELLO_SENT);
  assert.equal(client.session, 0);

});

test('completed request cache is bounded but keeps the latest idempotent replay per command', () => {
  const {client} = bootActive();
  const statusSeqs = [];
  for (let index = 0; index < 70; index++) {
    const status = onlyFrame(client.statusGet());
    statusSeqs.push(status.seq);
    const reply = onlyFrame(
      controlReply(CONTROL.STATUS, status.seq, client.session, [
        DEVICE_STATE.ACTIVE,
        ...u16(0),
        ...u16(index),
        REASON.NONE,
      ]),
    );
    assert.deepEqual(client.handleFrame(reply), {accepted: true, event: 'status'});
  }
  assert.equal(client.completed.size, 64);

  const newest = statusSeqs[statusSeqs.length - 1];
  const newestReplay = onlyFrame(
    controlReply(CONTROL.STATUS, newest, client.session, [DEVICE_STATE.ACTIVE, ...u16(0), ...u16(69), REASON.NONE]),
  );
  assert.deepEqual(client.handleFrame(newestReplay), {accepted: true, event: 'status'});
  assert.equal(client.expectedMidiSeq, 69);

  const evicted = statusSeqs[0];
  const evictedReplay = onlyFrame(
    controlReply(CONTROL.STATUS, evicted, client.session, [DEVICE_STATE.ACTIVE, ...u16(0), ...u16(0), REASON.NONE]),
  );
  assert.deepEqual(client.handleFrame(evictedReplay), {
    accepted: false,
    event: 'ignored',
    reason: 'unexpected_reply',
  });
});

test('first PONG timeout is anchored at the first outstanding PING and replays do not refresh it', () => {
  const {client} = bootActive();
  assert.equal(client.heartbeatAgeMs(0), null);
  assert.equal(client.heartbeatTimedOut(5000), false);

  client.ping(100);
  assert.equal(client.heartbeatAgeMs(600), 500);
  assert.equal(client.heartbeatTimedOut(2100), false);
  assert.equal(client.heartbeatTimedOut(2101), true);

  // A second PING while the first PONG is still missing must not hide the
  // missing heartbeat by moving the fallback watermark forward.
  client.ping(700);
  assert.equal(client.heartbeatTimedOut(2101), true);

  const pongWire = onlyFrame(
    controlReply(CONTROL.PONG, client.lastPingSeq, client.session, [DEVICE_STATE.ACTIVE, ...u16(0), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(pongWire, 2200), {accepted: true, event: 'pong'});
  assert.equal(client.heartbeatAgeMs(2200), 0);
  assert.equal(client.heartbeatTimedOut(4200), false);
  assert.equal(client.heartbeatTimedOut(4201), true);

  // A replayed PONG is idempotent but is not new liveness evidence.
  assert.deepEqual(client.handleFrame(pongWire, 9000), {accepted: true, event: 'pong'});
  assert.equal(client.lastPongAt, 2200);
  assert.equal(client.heartbeatTimedOut(9000), true);
});

test('reference client rejects never-issued reply sequences and accepts cached idempotent replays', () => {
  const {client, ready} = bootActive(0x11223344, 0x0000002a, 0);
  const before = client.unexpectedReplies;
  const unsolicitedStatus = onlyFrame(
    controlReply(CONTROL.STATUS, 999, client.session, [DEVICE_STATE.ACTIVE, ...u16(0), ...u16(0), REASON.NONE]),
  );
  assert.deepEqual(client.handleFrame(unsolicitedStatus), {
    accepted: false,
    event: 'ignored',
    reason: 'unexpected_reply',
  });
  assert.equal(client.unexpectedReplies, before + 1);
  assert.equal(client.expectedMidiSeq, 0);

  const unsolicitedReady = onlyFrame(
    controlReply(CONTROL.READY, 1000, client.session, [...u16(0), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(unsolicitedReady), {
    accepted: false,
    event: 'ignored',
    reason: 'unexpected_reply',
  });
  assert.equal(client.phase, CLIENT_PHASE.ACTIVE);

  const unsolicitedConfig = onlyFrame(encodeFrame(TYPE.CONFIG_REPLY, 1001, client.session, [0x81, 0x00, 0x01]));
  assert.deepEqual(client.handleFrame(unsolicitedConfig), {
    accepted: false,
    event: 'ignored',
    reason: 'unexpected_reply',
  });

  client.midi([[0x90, 60, 100]]);
  assert.equal(client.lastMidiSeq, 0);
  assert.equal(client.nextMidiSeq, 1);

  // READY with the completed CONFIRM seq is a legitimate replay, but it must
  // not move the send pointer or expected sequence.
  const status = onlyFrame(client.statusGet());
  const statusReply = onlyFrame(
    controlReply(CONTROL.STATUS, status.seq, client.session, [
      DEVICE_STATE.ACTIVE,
      ...u16(0),
      ...u16(3),
      REASON.NONE,
    ]),
  );
  assert.deepEqual(client.handleFrame(statusReply), {accepted: true, event: 'status'});
  assert.equal(client.expectedMidiSeq, 3);

  const duplicateReady = onlyFrame(
    controlReply(CONTROL.READY, ready.seq, client.session, [...u16(0), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(duplicateReady), {accepted: true, event: 'ready'});
  assert.equal(client.expectedMidiSeq, 3);
  assert.equal(client.nextMidiSeq, 1);

  // A completed seq replayed with the wrong command is not idempotent.
  const wrongCommand = onlyFrame(
    controlReply(CONTROL.PONG, ready.seq, client.session, [DEVICE_STATE.ACTIVE, ...u16(0), ...u16(0)]),
  );
  assert.equal(client.handleFrame(wrongCommand).reason, 'unexpected_reply');
});

test('duplicate PLAYBACK_READY cannot rewind transmitted MIDI', () => {
  const {client} = bootActive(0x11223344, 0x0000002a, 0);
  const resync = onlyFrame(
    controlReply(CONTROL.RESYNC_REQUIRED, 0, client.session, [...u16(1), REASON.MIDI_GAP]),
  );
  assert.deepEqual(client.handleFrame(resync), {accepted: true, event: 'resync_required'});
  const resume = onlyFrame(client.resume(1, 0));
  const ready = onlyFrame(
    controlReply(CONTROL.PLAYBACK_READY, resume.seq, client.session, [...u16(1), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(ready), {accepted: true, event: 'playback_ready'});
  assert.equal(client.nextMidiSeq, 0);

  assert.equal(onlyFrame(client.midi([[0x90, 60, 100]])[0]).seq, 0);
  assert.equal(client.nextMidiSeq, 1);
  assert.deepEqual(client.handleFrame(ready), {accepted: true, event: 'playback_ready'});
  assert.equal(client.nextMidiSeq, 1);
  assert.equal(client.expectedMidiSeq, 0);
  assert.equal(onlyFrame(client.midi([[0x80, 60, 0]])[0]).seq, 1);
});

test('stale RESYNC and stale READY cannot roll epoch or MIDI state backwards', () => {
  const {client, ready} = bootActive(0x11223344, 0x0000002a, 0);
  const resync = onlyFrame(
    controlReply(CONTROL.RESYNC_REQUIRED, 0, client.session, [...u16(1), REASON.MIDI_GAP]),
  );
  assert.deepEqual(client.handleFrame(resync), {accepted: true, event: 'resync_required'});
  const resume = onlyFrame(client.resume(1, 0));
  const playback = onlyFrame(
    controlReply(CONTROL.PLAYBACK_READY, resume.seq, client.session, [...u16(1), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(playback), {accepted: true, event: 'playback_ready'});
  client.midi([[0x90, 60, 100]]);
  assert.equal(client.nextMidiSeq, 1);

  const staleResync = onlyFrame(
    controlReply(CONTROL.RESYNC_REQUIRED, 0, client.session, [...u16(0), REASON.MIDI_GAP]),
  );
  assert.deepEqual(client.handleFrame(staleResync), {
    accepted: false,
    event: 'ignored',
    reason: 'stale_epoch',
  });
  assert.equal(client.epoch, 1);
  assert.equal(client.active, true);
  assert.equal(client.nextMidiSeq, 1);

  // A replayed READY from the pre-resync epoch is stale too.
  const staleReady = onlyFrame(
    controlReply(CONTROL.READY, ready.seq, client.session, [...u16(0), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(staleReady), {
    accepted: false,
    event: 'ignored',
    reason: 'stale_epoch',
  });
  assert.equal(client.epoch, 1);
  assert.equal(client.nextMidiSeq, 1);
  assert.equal(onlyFrame(client.midi([[0x80, 60, 0]])[0]).seq, 1);
});

test('hello restart binds WELCOME to the nonce actually sent and clears old request ids', () => {
  const client = new ReferenceSessionClient({nonce: 0x01020304, now: () => 0});
  assert.equal(onlyFrame(client.hello()).payload[1], 0x04);
  assert.equal(onlyFrame(client.hello()).payload[1], 0x04);

  client.nonce = 0x0a0b0c0d;
  const retried = onlyFrame(client.hello());
  assert.deepEqual([...retried.payload], [CONTROL.HELLO, ...u32(0x0a0b0c0d)]);

  const oldNonceWelcome = onlyFrame(
    controlReply(CONTROL.WELCOME, retried.seq, 9, [...u32(0x01020304), ...u16(0), 0, 0, 30, 16]),
  );
  assert.deepEqual(client.handleFrame(oldNonceWelcome), {
    accepted: false,
    event: 'ignored',
    reason: 'nonce_mismatch',
  });
  assert.equal(client.session, 0);
  assert.equal(client.phase, CLIENT_PHASE.HELLO_SENT);

  const welcome = onlyFrame(
    controlReply(CONTROL.WELCOME, retried.seq, 9, [...u32(0x0a0b0c0d), ...u16(0), 0, 0, 30, 16]),
  );
  assert.deepEqual(client.handleFrame(welcome), {accepted: true, event: 'welcome'});
  assert.equal(client.session, 9);
});

test('CONFIG is single-flight and retryConfig reuses the exact SEQ and payload', () => {
  const {client} = bootActive();
  const payload = [0x01, 0x10, 0x20];
  const config = onlyFrame(client.config(payload));
  assert.equal(client.configInFlight, true);
  assert.equal(config.type, TYPE.CONFIG);
  assert.deepEqual([...config.payload], payload);

  assert.throws(() => client.config([0x02, 0x30]), /在途/);
  assert.equal(client.pendingConfig.seq, config.seq);

  const retry = onlyFrame(client.retryConfig());
  assert.equal(retry.seq, config.seq);
  assert.deepEqual([...retry.payload], payload);
  const explicitRetry = onlyFrame(client.retryConfig(config.seq, payload));
  assert.equal(explicitRetry.seq, config.seq);
  assert.deepEqual([...explicitRetry.payload], payload);
  assert.throws(() => client.retryConfig(config.seq, [0x01, 0x10, 0x21]), /原 payload/);
  assert.throws(() => client.retryConfig((config.seq + 1) & 0xffff), /原 SEQ/);

  const reply = onlyFrame(encodeFrame(TYPE.CONFIG_REPLY, config.seq, client.session, [0x81, 0x00, 0x01]));
  assert.deepEqual(client.handleFrame(reply), {accepted: true, event: 'config_reply'});
  assert.equal(client.configInFlight, false);
  assert.equal(client.lastConfigResult.status, 'ok');
  assert.equal(client.lastConfigResult.seq, config.seq);
  assert.deepEqual([...client.lastConfigResult.reply], [0x81, 0x00, 0x01]);
  assert.throws(() => client.retryConfig(), /没有在途/);

  // The next config is a new request with a new sequence number.
  const next = onlyFrame(client.config([0x03, 0x40]));
  assert.notEqual(next.seq, config.seq);
  assert.equal(client.configInFlight, true);
});

test('RESYNC abandons pending CONFIG as unknown and never retransmits it automatically', () => {
  const {client} = bootActive(0x11223344, 0x0000002a, 0);
  const payload = [0x01, 0x10, 0x20];
  const config = onlyFrame(client.config(payload));
  assert.equal(client.configInFlight, true);

  const resync = onlyFrame(
    controlReply(CONTROL.RESYNC_REQUIRED, 0, client.session, [...u16(1), REASON.MIDI_GAP]),
  );
  assert.deepEqual(client.handleFrame(resync), {accepted: true, event: 'resync_required'});
  assert.equal(client.configInFlight, false);
  assert.equal(client.pending.has(config.seq), false);
  assert.equal(client.lastConfigResult.status, 'unknown');
  assert.equal(client.lastConfigResult.reason, 'epoch_resync');
  assert.equal(client.lastConfigResult.seq, config.seq);
  assert.deepEqual([...client.lastConfigResult.payload], payload);
  assert.throws(() => client.retryConfig(), /没有在途/);

  // The superseded reply is not accepted as a result for the new epoch.
  const staleReply = onlyFrame(encodeFrame(TYPE.CONFIG_REPLY, config.seq, client.session, [0x81, 0x00, 0x01]));
  assert.deepEqual(client.handleFrame(staleReply), {
    accepted: false,
    event: 'ignored',
    reason: 'unexpected_reply',
  });
  assert.equal(client.lastConfigResult.status, 'unknown');

  // Only an explicit new CONFIG after recovery may proceed; there is no
  // automatic resend queue.
  const resume = onlyFrame(client.resume(1, 0));
  const playback = onlyFrame(
    controlReply(CONTROL.PLAYBACK_READY, resume.seq, client.session, [...u16(1), ...u16(0)]),
  );
  assert.deepEqual(client.handleFrame(playback), {accepted: true, event: 'playback_ready'});
  const fresh = onlyFrame(client.config(payload));
  assert.notEqual(fresh.seq, config.seq);
  assert.equal(client.configInFlight, true);
});
