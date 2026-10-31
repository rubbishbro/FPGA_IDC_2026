import test from 'node:test';
import assert from 'node:assert/strict';

import {V2SerialLink} from '../src/serial-v2.mjs';
import {CLIENT_PHASE, CONTROL, REASON, TYPE} from '../src/protocol-v2.mjs';

// ---------------------------------------------------------------------------
// Independent v2 wire codec for the mock device. Deliberately does not import
// encodeFrame/decodeBody from protocol-v2.mjs, so a serializer bug on either
// side is visible as a test failure instead of being mirrored by the fixture.
// ---------------------------------------------------------------------------

const END = 0xc0;
const ESC = 0xdb;
const ESC_END = 0xdc;
const ESC_ESC = 0xdd;

function crc16(bytes) {
  let crc = 0xffff;
  for (const byte of bytes) {
    crc ^= (byte & 0xff) << 8;
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc & 0xffff;
}

function u16(value) {
  return [value & 0xff, (value >>> 8) & 0xff];
}

function u32(value) {
  return [value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff];
}

function readU16(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function readU32(bytes, offset) {
  return (
    (bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24)) >>>
    0
  );
}

function encodeFrame(type, seq, session, payload) {
  const body = [0x02, type, ...u16(seq), ...u16(payload.length), ...u32(session), ...payload];
  const crc = crc16(body);
  body.push(crc & 0xff, (crc >>> 8) & 0xff);
  const wire = [END];
  for (const byte of body) {
    if (byte === END) wire.push(ESC, ESC_END);
    else if (byte === ESC) wire.push(ESC, ESC_ESC);
    else wire.push(byte);
  }
  wire.push(END);
  return Uint8Array.from(wire);
}

function decodeBody(body) {
  if (body.length < 13 || body.length > 44) throw Error('帧长错误');
  if (body[0] !== 0x02) throw Error('协议版本错误');
  if (![1, 2, 3, 0x80, 0x81].includes(body[1])) throw Error('协议类型错误');
  const length = readU16(body, 4);
  if (body.length !== length + 12) throw Error('帧长错误');
  const expected = readU16(body, 10 + length);
  if (crc16(body.slice(0, 10 + length)) !== expected) throw Error('CRC 错误');
  return {
    version: body[0],
    type: body[1],
    seq: readU16(body, 2),
    session: readU32(body, 6),
    payload: Uint8Array.from(body.slice(10, 10 + length)),
  };
}

function bodyOf(wire) {
  const body = [];
  let escaped = false;
  for (let index = 1; index < wire.length - 1; index++) {
    const byte = wire[index];
    if (escaped) {
      if (byte === ESC_END) body.push(END);
      else if (byte === ESC_ESC) body.push(ESC);
      else throw Error('SLIP 转义错误');
      escaped = false;
    } else if (byte === ESC) {
      escaped = true;
    } else {
      body.push(byte);
    }
  }
  return Uint8Array.from(body);
}

class DeviceWireReader {
  constructor(onFrame, onError) {
    this.onFrame = onFrame;
    this.onError = onError;
    this.started = false;
    this.escape = false;
    this.bad = false;
    this.body = [];
  }

  feed(bytes) {
    for (const raw of bytes) {
      const byte = raw & 0xff;
      if (byte === END) {
        const candidate = this.body;
        const bad = this.bad || this.escape;
        const hasCandidate = this.started && (candidate.length > 0 || this.bad || this.escape);
        this.started = true;
        this.escape = false;
        this.bad = false;
        this.body = [];
        if (!hasCandidate) continue;
        if (bad) {
          this.onError(Error('SLIP 转义或帧长错误'));
          continue;
        }
        try {
          this.onFrame(decodeBody(candidate));
        } catch (error) {
          this.onError(error);
        }
      } else if (this.started && !this.bad) {
        if (this.escape) {
          if (byte === ESC_END) this.body.push(END);
          else if (byte === ESC_ESC) this.body.push(ESC);
          else this.bad = true;
          this.escape = false;
        } else if (byte === ESC) {
          this.escape = true;
        } else {
          this.body.push(byte);
          if (this.body.length > 44) this.bad = true;
        }
      }
    }
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(predicate, timeoutMs = 1500, label = 'condition') {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (predicate()) return;
    await sleep(2);
  }
  throw Error(`timeout waiting for ${label}`);
}

function fast(overrides = {}) {
  return {
    pingIntervalMs: 15,
    pongTimeoutMs: 100,
    handshakeTimeoutMs: 250,
    configTimeoutMs: 80,
    statusTimeoutMs: 80,
    recoveryTimeoutMs: 250,
    maxQueue: 64,
    pacing: false,
    ...overrides,
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return {promise, resolve, reject};
}

class FakeDevice {
  constructor(options = {}) {
    this.session = options.session ?? 0x12345678;
    this.epoch = options.epoch ?? 0;
    this.expected = 0;
    this.nonce = null;

    this.autoWelcome = options.autoWelcome ?? true;
    this.autoReady = options.autoReady ?? true;
    this.autoPlaybackReady = options.autoPlaybackReady ?? true;
    this.ignorePing = options.ignorePing ?? false;
    this.dropConfigReply = options.dropConfigReply ?? false;
    this.configResult = options.configResult ?? 0;
    this.replyDelayMs = options.replyDelayMs ?? 0;

    this.frames = [];
    this.errors = [];
    this.writes = [];
    this.received = [];
    this.readQueue = [];
    this.pendingRead = null;
    this.cancelCount = 0;
    this.closeCount = 0;
    this.openCount = 0;
    this.writerReleaseCount = 0;
    this.readerReleaseCount = 0;
    this.writeEntered = 0;
    this.blocked = false;
    this.blockNext = null;

    this.hellos = 0;
    this.confirms = 0;
    this.pings = [];
    this.midi = [];
    this.midiErrors = [];
    this.staleMidi = 0;
    this.configs = [];
    this.statusRequests = [];
    this.resumes = [];
    this.resumeEpoch = null;

    this.decoder = new DeviceWireReader(
      (frame) => this._onFrame(frame),
      (error) => this.errors.push(error),
    );

    this.reader = {
      read: () => this._read(),
      cancel: async () => {
        this.cancelCount++;
        this.canceled = true;
        this._finishRead();
      },
      releaseLock: () => {
        this.readerReleaseCount++;
      },
    };
    this.writer = {
      write: async (wire) => {
        this.writes.push(wire);
        this.writeEntered++;
        if (this.blockNext) {
          this.blocked = true;
          const gate = this.blockNext;
          this.blockNext = null;
          await gate;
        }
        this.received.push(wire);
        this.decoder.feed(wire);
      },
      ready: Promise.resolve(),
      releaseLock: () => {
        this.writerReleaseCount++;
      },
    };
    this.port = {
      open: async () => {
        this.openCount++;
      },
      writable: {getWriter: () => this.writer},
      readable: {getReader: () => this.reader},
      close: async () => {
        this.closeCount++;
        this._finishRead();
      },
    };
    this.api = {
      addEventListener: () => {},
      requestPort: async () => this.port,
    };
  }

  _read() {
    if (this.readQueue.length > 0) return Promise.resolve({value: this.readQueue.shift(), done: false});
    if (this.canceled) return Promise.resolve({done: true});
    return new Promise((resolve) => {
      this.pendingRead = resolve;
    });
  }

  _finishRead() {
    if (this.pendingRead) {
      const resolve = this.pendingRead;
      this.pendingRead = null;
      resolve({done: true});
    }
  }

  send(bytes) {
    if (this.canceled) return;
    this.readQueue.push(Uint8Array.from(bytes));
    if (this.pendingRead) {
      const resolve = this.pendingRead;
      this.pendingRead = null;
      resolve({value: this.readQueue.shift(), done: false});
    }
  }

  emit(type, seq, session, payload) {
    this.send(encodeFrame(type, seq, session, payload));
  }

  reply(type, seq, payload) {
    this.emit(type, seq, this.session, payload);
  }

  _onFrame(frame) {
    this.frames.push(frame);
    setTimeout(() => {
      try {
        this._respond(frame);
      } catch (error) {
        this.errors.push(error);
      }
    }, this.replyDelayMs);
  }

  _respond(frame) {
    if (frame.type === TYPE.MIDI) {
      if (frame.session !== this.session) return;
      if (readU16(frame.payload, 0) !== this.epoch) {
        this.staleMidi++;
        return;
      }
      if (frame.seq !== this.expected) {
        this.midiErrors.push({seq: frame.seq, expected: this.expected});
        return;
      }
      this.midi.push({
        seq: frame.seq,
        epoch: this.epoch,
        messages: [...frame.payload.subarray(2)],
      });
      this.expected = (this.expected + 1) & 0xffff;
      return;
    }

    if (frame.type === TYPE.CONFIG) {
      this.configs.push({seq: frame.seq, payload: [...frame.payload]});
      if (!this.dropConfigReply) {
        this.reply(TYPE.CONFIG_REPLY, frame.seq, [0x02, frame.payload[0], this.configResult]);
      }
      return;
    }

    if (frame.type !== TYPE.CONTROL) return;
    const command = frame.payload[0];
    if (command === CONTROL.HELLO) {
      this.hellos++;
      this.nonce = readU32(frame.payload, 1);
      if (this.autoWelcome) {
        this.reply(TYPE.CONTROL_REPLY, frame.seq, [
          CONTROL.WELCOME,
          ...u32(this.nonce),
          ...u16(this.epoch),
          ...u16(0x000f),
          30,
          16,
        ]);
      }
      return;
    }
    if (frame.session !== this.session) return;
    if (command === CONTROL.CONFIRM) {
      this.confirms++;
      if (this.autoReady && readU32(frame.payload, 1) === this.nonce) {
        this.reply(TYPE.CONTROL_REPLY, frame.seq, [CONTROL.READY, ...u16(this.epoch), ...u16(this.expected)]);
      }
      return;
    }
    if (command === CONTROL.PING) {
      const ping = {
        seq: frame.seq,
        hasMidi: frame.payload[1],
        lastMidiSeq: readU16(frame.payload, 2),
        epoch: readU16(frame.payload, 4),
      };
      this.pings.push(ping);
      if (!this.ignorePing && ping.epoch === this.epoch) {
        this.reply(TYPE.CONTROL_REPLY, frame.seq, [
          CONTROL.PONG,
          3,
          ...u16(this.epoch),
          ...u16(this.expected),
        ]);
      }
      return;
    }
    if (command === CONTROL.STATUS_GET) {
      this.statusRequests.push({seq: frame.seq});
      this.reply(TYPE.CONTROL_REPLY, frame.seq, [
        CONTROL.STATUS,
        3,
        ...u16(this.epoch),
        ...u16(this.expected),
        REASON.NONE,
      ]);
      return;
    }
    if (command === CONTROL.RESUME) {
      const epoch = readU16(frame.payload, 1);
      const first = readU16(frame.payload, 3);
      this.resumes.push({seq: frame.seq, epoch, first});
      this.resumeEpoch = epoch;
      this.epoch = epoch;
      this.expected = first;
      if (this.autoPlaybackReady) {
        this.reply(TYPE.CONTROL_REPLY, frame.seq, [
          CONTROL.PLAYBACK_READY,
          ...u16(epoch),
          ...u16(first),
        ]);
      }
    }
  }

  sendReady() {
    const confirm = this.frames.filter(
      (frame) => frame.type === TYPE.CONTROL && frame.payload[0] === CONTROL.CONFIRM,
    ).at(-1);
    assert.ok(confirm, 'device did not receive CONFIRM');
    this.reply(TYPE.CONTROL_REPLY, confirm.seq, [CONTROL.READY, ...u16(this.epoch), ...u16(this.expected)]);
  }

  sendResync(epoch, reason = REASON.MIDI_GAP) {
    this.emit(TYPE.CONTROL_REPLY, 0, this.session, [
      CONTROL.RESYNC_REQUIRED,
      ...u16(epoch),
      reason,
    ]);
  }

  sendFault(reason = REASON.PHYSICAL_FAULT) {
    this.emit(TYPE.CONTROL_REPLY, 0, this.session, [CONTROL.FAULT, reason]);
  }
}

async function activeLink(options = {}, deviceOptions = {}) {
  const device = new FakeDevice(deviceOptions);
  const link = new V2SerialLink(() => {}, () => {}, device.api, fast(options));
  await link.connect(115200);
  return {device, link};
}

// ---------------------------------------------------------------------------
// Handshake and readiness gate
// ---------------------------------------------------------------------------

test('v2 handshake gates connected/send on READY, not on open or WELCOME', async () => {
  const device = new FakeDevice({autoReady: false});
  const link = new V2SerialLink(() => {}, () => {}, device.api, fast());
  const connecting = link.connect(115200);

  await waitFor(() => device.confirms === 1, 1500, 'CONFIRM');
  assert.equal(device.openCount, 1);
  assert.equal(link.connected, false);
  assert.equal(link.phase, CLIENT_PHASE.CONFIRM_SENT);
  assert.equal(link.sessionId, device.session);
  await assert.rejects(link.send([[0x90, 60, 100]]), /未连接|未就绪/);

  device.sendReady();
  await connecting;
  assert.equal(link.connected, true);
  assert.equal(link.phase, CLIENT_PHASE.ACTIVE);
  assert.equal(link.sessionId, device.session);
  assert.equal(link.playbackEpoch, 0);
  await link.disconnect();
});

test('v2 handshake has a finite timeout and releases the opened port', async () => {
  const device = new FakeDevice({autoWelcome: false});
  const link = new V2SerialLink(() => {}, () => {}, device.api, fast({handshakeTimeoutMs: 60}));
  let faults = 0;
  link.onFault = () => {
    faults++;
  };
  await assert.rejects(link.connect(115200), /握手超时/);
  assert.equal(faults, 1);
  assert.equal(link.connected, false);
  assert.equal(link.port, null);
  assert.equal(device.closeCount, 1);
  assert.equal(device.writerReleaseCount, 1);
});

// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------

test('v2 CONFIG resolves the matching final result and times out as unknown', async () => {
  const {device, link} = await activeLink();
  const first = await link.configure([0x01, 0x7f]);
  assert.deepEqual(first, {result: 0, command: 0x01, seq: device.configs[0].seq});
  assert.equal(link.configPending, false);

  device.dropConfigReply = true;
  const pending = link.configure([0x02, 0x03]);
  await waitFor(() => device.configs.length === 2, 1500, 'second CONFIG');
  const error = await pending.catch((reason) => reason);
  assert.equal(error.result.status, 'unknown');
  assert.equal(error.result.reason, 'timeout');
  assert.equal(error.result.seq, device.configs[1].seq);
  assert.equal(link.configPending, false);

  device.dropConfigReply = false;
  const next = await link.configure([0x01, 0x00]);
  assert.notEqual(next.seq, first.seq);
  assert.equal(next.result, 0);
  await link.disconnect();
});

test('v2 retryConfig reuses exactly the same SEQ and payload', async () => {
  const {device, link} = await activeLink({configTimeoutMs: 300});
  device.dropConfigReply = true;
  const original = link.configure([0x01, 0x22]);
  await waitFor(() => device.configs.length === 1, 1500, 'first CONFIG');
  device.dropConfigReply = false;

  const retried = link.retryConfig();
  assert.equal(retried, original, 'retry resolves the original configure() promise');
  const result = await retried;
  assert.equal(device.configs.length, 2);
  assert.equal(device.configs[1].seq, device.configs[0].seq);
  assert.deepEqual(device.configs[1].payload, device.configs[0].payload);
  assert.equal(result.seq, device.configs[0].seq);
  await link.disconnect();
});

test('v2 slow CONFIG neither blocks timer PING nor admits MIDI past the barrier', async () => {
  const {device, link} = await activeLink({configTimeoutMs: 250});
  device.dropConfigReply = true;
  const configErrorPromise = link.configure([0x01, 0x00]).catch((error) => error);
  await waitFor(() => device.configs.length === 1, 1500, 'CONFIG write');

  const pingsBefore = device.pings.length;
  await waitFor(() => device.pings.length > pingsBefore, 1500, 'PING during CONFIG');
  await assert.rejects(link.send([[0x90, 60, 100]]), /CONFIG 在途/);

  const error = await configErrorPromise;
  assert.equal(error.result.status, 'unknown');
  await link.disconnect();
});

// ---------------------------------------------------------------------------
// MIDI ordering, PING watermark, and cancel
// ---------------------------------------------------------------------------

test('v2 timer PING carries the watermark of MIDI already written', async () => {
  const {device, link} = await activeLink();
  const sent = link.send(Array.from({length: 11}, (_, index) => [0x90, 40 + index, 100]));
  await sent;
  await waitFor(() => device.midi.length === 2, 1500, 'two MIDI frames');
  await waitFor(() => device.pings.length >= 1, 1500, 'PING');
  const ping = device.pings.at(-1);
  assert.equal(ping.hasMidi, 1);
  assert.equal(ping.lastMidiSeq, 1);
  assert.equal(ping.epoch, 0);
  await link.disconnect();
});

test('v2 cancel while a writer is blocked drops unsent MIDI without a sequence hole', async () => {
  const {device, link} = await activeLink();
  const gate = deferred();
  device.blockNext = gate.promise;

  const firstBatch = Array.from({length: 11}, (_, index) => [0x90, 40 + index, 100]);
  const pending = link.send(firstBatch).catch((error) => error);
  await waitFor(() => device.blocked, 1500, 'first write entered');

  link.cancel();
  gate.resolve();
  const cancelled = await pending;
  assert.equal(cancelled.name, 'AbortError');
  await waitFor(
    () => device.frames.filter((frame) => frame.type === TYPE.MIDI).length === 1,
    1500,
    'first MIDI frame at device',
  );
  await sleep(25);
  assert.equal(
    device.frames.filter((frame) => frame.type === TYPE.MIDI).length,
    1,
    'second MIDI frame must not be attempted',
  );
  assert.equal(device.midi.length, 1);
  assert.equal(device.midi[0].seq, 0);

  await link.send([[0x80, 40, 0]]);
  await waitFor(() => device.midi.length === 2, 1500, 'post-cancel MIDI');
  assert.equal(device.midi[1].seq, 1, 'no sequence hole after cancel');
  assert.equal(device.midiErrors.length, 0);

  await waitFor(() => device.pings.some((ping) => ping.lastMidiSeq === 1), 1500, 'post-cancel PING');
  await link.disconnect();
});

test('v2 PING is dispatched between groups of a large MIDI batch', async () => {
  const {device, link} = await activeLink({pingIntervalMs: 15, pongTimeoutMs: 2000});
  const gate = deferred();
  device.blockNext = gate.promise;

  // 21 three-byte messages = ten + ten + one, i.e. three v2 MIDI frames.
  const pending = link.send(Array.from({length: 21}, (_, index) => [0x90, 40 + index, 100]));
  await waitFor(() => device.blocked, 1500, 'first MIDI group blocked');
  const frameStart = device.frames.length;
  await sleep(45); // let the PING timer enqueue while the writer is blocked
  gate.resolve();
  await pending;
  await waitFor(() => device.midi.length === 3, 1500, 'three MIDI groups');

  const sequence = device.frames.slice(frameStart).map((frame) => {
    if (frame.type === TYPE.MIDI) return 'M';
    if (frame.type === TYPE.CONTROL && frame.payload[0] === CONTROL.PING) return 'P';
    return '?';
  });
  assert.equal(sequence[0], 'M');
  const pingIndex = sequence.indexOf('P');
  assert.ok(pingIndex > 0, `expected an interleaved PING, got ${sequence.join('')}`);
  assert.ok(pingIndex < sequence.lastIndexOf('M'), `PING must precede remaining MIDI: ${sequence.join('')}`);
  await link.disconnect();
});

test('v2 stale queued MIDI stops playback instead of replaying late notes', async () => {
  const {device, link} = await activeLink({
    queueTimeoutMs: 20,
    pingIntervalMs: 1000,
    pongTimeoutMs: 2000,
  });
  let fault = null;
  link.onFault = (error) => {
    fault = error;
  };
  const gate = deferred();
  device.blockNext = gate.promise;
  const pending = link.send(Array.from({length: 21}, (_, index) => [0x90, 40 + index, 100])).catch(
    (error) => error,
  );
  await waitFor(() => device.blocked, 1500, 'first MIDI group blocked');
  await sleep(45);
  gate.resolve();
  const error = await pending;
  assert.match(error.message, /队列延迟超过/);
  assert.ok(fault, 'queue delay must invoke onFault');
  assert.equal(link.connected, false);
  await link.disconnect();
});

test('v2 maxQueue bounds all pending MIDI groups, not just send() calls', async () => {
  const {device, link} = await activeLink({maxQueue: 4, pingIntervalMs: 1000, pongTimeoutMs: 2000});
  const gate = deferred();
  device.blockNext = gate.promise;
  const first = link.send(Array.from({length: 21}, (_, index) => [0x90, 40 + index, 100])).catch((error) => error);
  await waitFor(() => device.blocked, 1500, 'first batch blocked');

  const second = link.send(Array.from({length: 11}, (_, index) => [0x90, 40 + index, 100]));
  await assert.rejects(second, /积压/);
  const firstError = await first;
  assert.match(firstError.message, /积压/);
  assert.equal(link.connected, false);
  gate.resolve();
  await link.disconnect();
});

// ---------------------------------------------------------------------------
// Heartbeat faults
// ---------------------------------------------------------------------------

test('v2 missing PONG faults and stops business traffic', async () => {
  const {device, link} = await activeLink({pongTimeoutMs: 90}, {ignorePing: true});
  let fault = null;
  link.onFault = (error) => {
    fault = error;
  };
  await waitFor(() => fault !== null, 1500, 'heartbeat fault');
  assert.match(fault.message, /心跳超时/);
  assert.equal(link.connected, false);
  await assert.rejects(link.send([[0x90, 60, 1]]), /未连接|未就绪/);
  await link.disconnect();
});

test('v2 paused heartbeat sends no PING but the local watchdog still faults', async () => {
  const {device, link} = await activeLink({pongTimeoutMs: 90}, {ignorePing: true});
  let fault = null;
  link.onFault = (error) => {
    fault = error;
  };
  link.pauseHeartbeatForTest();
  const pingsAtPause = device.pings.length;
  await waitFor(() => fault !== null, 1500, 'paused heartbeat fault');
  assert.equal(device.pings.length, pingsAtPause, 'paused PING must not be transmitted');
  assert.equal(link.connected, false);
  await link.disconnect();
});

// ---------------------------------------------------------------------------
// RESYNC / playback recovery
// ---------------------------------------------------------------------------

test('v2 RESYNC drops old MIDI, marks CONFIG unknown, and orders recovery callbacks', async () => {
  const {device, link} = await activeLink();
  const events = [];
  let recoveryInfo = null;
  link.onRecovery = (info) => {
    events.push('recovery');
    recoveryInfo = info;
    assert.equal(link.connected, false, 'onRecovery must run while not connected');
    assert.equal(link.phase, CLIENT_PHASE.RESUME_SENT);
    assert.equal(info.epoch, 1);
  };
  link.onRecovered = (info) => {
    events.push('recovered');
    assert.equal(link.connected, true, 'onRecovered runs only after PLAYBACK_READY');
    assert.equal(link.playbackEpoch, 1);
    assert.equal(info.epoch, 1);
  };

  await link.send([[0x90, 60, 100]]);
  await waitFor(() => device.midi.length === 1, 1500, 'initial MIDI frame');

  device.dropConfigReply = true;
  const configResult = link.configure([0x01, 0x00]).catch((error) => error);
  await waitFor(() => device.configs.length === 1, 1500, 'CONFIG before RESYNC');

  device.sendResync(1, REASON.MIDI_GAP);
  const configError = await configResult;
  assert.equal(configError.result.status, 'unknown');
  assert.equal(configError.result.reason, 'epoch_resync');
  assert.equal(link.configPending, false);

  await waitFor(() => events.length === 2, 1500, 'recovery callbacks');
  assert.deepEqual(events, ['recovery', 'recovered']);
  assert.equal(recoveryInfo.reason, REASON.MIDI_GAP);
  assert.equal(device.resumeEpoch, 1);
  assert.equal(device.resumes.length, 1);
  assert.equal(device.staleMidi, 0, 'no old-epoch MIDI may be retransmitted');
  assert.equal(device.midi.length, 1, 'no automatic MIDI retransmission');

  await link.send([[0x80, 60, 0]]);
  await waitFor(() => device.midi.length === 2, 1500, 'new-epoch MIDI');
  assert.equal(device.midi.at(-1).epoch, 1);
  assert.equal(device.midi.at(-1).seq, 0, 'new epoch restarts MIDI sequence at zero');
  assert.equal(device.midiErrors.length, 0);
  await link.disconnect();
});

test('v2 recovery timeout faults if PLAYBACK_READY never arrives', async () => {
  const {device, link} = await activeLink({recoveryTimeoutMs: 60}, {autoPlaybackReady: false});
  let fault = null;
  link.onFault = (error) => {
    fault = error;
  };
  device.sendResync(1, REASON.MIDI_GAP);
  await waitFor(() => fault !== null, 1500, 'recovery timeout fault');
  assert.match(fault.message, /PLAYBACK_READY 超时/);
  assert.equal(link.connected, false);
  await link.disconnect();
});

// ---------------------------------------------------------------------------
// STATUS and test-only hooks
// ---------------------------------------------------------------------------

test('v2 requestStatus matches the actual control request and decodes STATUS', async () => {
  const {device, link} = await activeLink();
  await link.send([[0x90, 61, 90]]);
  const pending = link.requestStatus();
  await assert.rejects(link.requestStatus(), /状态查询在途/);
  const status = await pending;
  assert.equal(device.statusRequests.length, 1);
  assert.equal(status.seq, device.statusRequests[0].seq);
  assert.equal(status.state, 3);
  assert.equal(status.epoch, 0);
  assert.equal(status.expectedMidiSeq, 1);
  assert.equal(status.reason, REASON.NONE);
  assert.deepEqual(link.lastStatus, status);
  await link.disconnect();
});

test('v2 deliberate bad CRC corrupts only the CRC of a well-formed CONFIG', async () => {
  const device = new FakeDevice();
  const link = new V2SerialLink(() => {}, () => {}, device.api, fast());
  assert.throws(() => link.sendBadCrcForTest(), /ACTIVE/);
  await link.connect(115200);
  const before = device.errors.length;

  const {seq, wire} = await link.sendBadCrcForTest();
  await waitFor(() => device.errors.length > before, 1500, 'bad CRC device error');
  assert.match(device.errors.at(-1).message, /CRC/);
  assert.equal(device.configs.length, 0, 'device must not apply a bad-CRC CONFIG');
  assert.equal(link.configPending, false, 'bad-CRC test must not claim a config result');
  assert.equal(link.connected, true);

  const body = bodyOf(wire);
  assert.equal(body[0], 0x02);
  assert.equal(body[1], TYPE.CONFIG);
  assert.equal(readU16(body, 2), seq);
  const length = readU16(body, 4);
  assert.equal(body.length, length + 12);
  assert.deepEqual([...body.slice(10, 10 + length)], [0x01, 0x00, 0x00]);
  assert.throws(() => decodeBody(body), /CRC/);

  // The port is still usable for a normal CONFIG after the test frame.
  const result = await link.configure([0x01, 0x05]);
  assert.equal(result.result, 0);
  await link.disconnect();
});

test('v2 writer failure rejects the pending MIDI promise before fault', async () => {
  const {device, link} = await activeLink({pingIntervalMs: 1000, pongTimeoutMs: 2000});
  let faults = 0;
  link.onFault = () => {
    faults++;
  };
  device.writer.write = async () => {
    throw Error('USB removed');
  };
  await assert.rejects(link.send([[0x90, 60, 90]]), /USB removed/);
  assert.equal(faults, 1);
  assert.equal(link.connected, false);
  await link.disconnect();
});

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

test('v2 disconnect cancels timers, unsent MIDI, reader/writer locks and port', async () => {
  const {device, link} = await activeLink();
  const writesBefore = device.writes.length;
  const pending = link.send([[0x90, 60, 100], [0x80, 60, 0]]).catch((error) => error);
  await link.disconnect();
  const cancelled = await pending;
  assert.equal(link.connected, false);
  assert.equal(link.port, null);
  assert.equal(device.cancelCount, 1);
  assert.equal(device.closeCount, 1);
  assert.equal(device.writerReleaseCount, 1);
  assert.equal(device.readerReleaseCount, 1);
  assert.equal(cancelled.name, 'AbortError');
  const writesAfterDisconnect = device.writes.length;
  await sleep(60);
  assert.equal(device.writes.length, writesAfterDisconnect, 'no timer traffic after disconnect');
  assert.ok(writesAfterDisconnect >= writesBefore);
});

test('v2 device FAULT invokes onFault and stops business', async () => {
  const {device, link} = await activeLink();
  let fault = null;
  link.onFault = (error) => {
    fault = error;
  };
  device.sendFault(REASON.PHYSICAL_FAULT);
  await waitFor(() => fault !== null, 1500, 'device FAULT callback');
  assert.equal(fault.reason, REASON.PHYSICAL_FAULT);
  assert.equal(link.connected, false);
  assert.equal(link.phase, CLIENT_PHASE.FAULT, 'local fault must override stale client ACTIVE');
  await link.disconnect();
  assert.equal(link.phase, CLIENT_PHASE.IDLE, 'disconnect must return UI phase to idle');
});

test('v2 repeated diagnostic clicks cannot grow a blocked control queue indefinitely', async () => {
  const {device, link} = await activeLink({maxQueue: 1, pingIntervalMs: 1000});
  const gate = deferred();
  device.blockNext = gate.promise;
  const first = link.sendBadCrcForTest();
  await waitFor(() => device.blocked, 1500, 'diagnostic write blocked');
  const second = link.sendBadCrcForTest();
  assert.throws(() => link.sendBadCrcForTest(), /队列已满/);
  gate.resolve();
  await Promise.all([first, second]);
  await link.disconnect();
});
