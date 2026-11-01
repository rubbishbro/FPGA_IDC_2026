/**
 * Bluetooth session protocol v2 — mobile-facing JavaScript reference.
 *
 * Fixed contract: docs/蓝牙协议.md (2026-10-31). This file is a
 * host/mobile-side codec and a small reference session client only. It makes
 * no claim about RTL or real-board behaviour.
 *
 * Wire format (all integers little-endian):
 *
 *   C0  02  TYPE  SEQ:u16  LEN:u16  SESSION:u32  PAYLOAD[LEN]  CRC:u16  C0
 *       |<---------------- CRC covers these 10+LEN bytes --------------->|
 *
 *   body length = LEN + 12, 1 <= LEN <= 32, body <= 44 bytes.
 *   MIDI payload = epoch:u16 + one or more complete MIDI short messages,
 *   total 3..32 bytes, so at most 30 *actual* MIDI bytes per frame.
 *   CONFIG payload <= 16; CONFIG_REPLY (0x80) payload exactly 3.
 *
 * SLIP: END=0xC0, ESC=0xDB, ESC_END=0xDC, ESC_ESC=0xDD.
 * CRC: CRC-16/CCITT-FALSE, init 0xFFFF, poly 0x1021, no reflection/xorout.
 * Known vector: crc16(ASCII "123456789") === 0x29B1.
 *
 * Public exports
 * --------------
 * crc16(bytes) -> u16
 *     CRC-16/CCITT-FALSE over an iterable of bytes.
 *
 * encodeFrame(type, seq, session, payload) -> Uint8Array
 *     Validate a v2 frame and return the complete SLIP wire bytes, including
 *     the leading and trailing 0xC0. Throws on invalid type/field/length.
 *
 * decodeBody(body) -> {version, type, seq, session, payload}
 *     Validate one unescaped body (header + payload + CRC) and return a copy
 *     of the payload as Uint8Array. Throws on version/type/length/CRC errors.
 *
 * class FrameReader(onFrame = () => {}, onError = () => {})
 *     Incremental SLIP + v2 body decoder. feed(bytes) accepts arbitrary
 *     split/coalesced chunks. A frame is delivered only after its closing
 *     0xC0. Malformed escapes, oversize bodies, and body validation errors
 *     are reported through onError and never through onFrame. Empty frames
 *     between delimiters and bytes before the first 0xC0 are ignored.
 *     reset() discards any partial candidate.
 *
 * packMidi(messages, epoch) -> Uint8Array[]
 *     Pack an iterable of complete MIDI short messages into v2 MIDI payloads.
 *     Each returned payload is `epoch:u16LE + messages`; a packet carries at
 *     most 30 actual MIDI bytes and never splits a message. Returns [] for no
 *     messages. Throws for an invalid epoch or malformed MIDI message.
 *
 * class ReferenceSessionClient({nonce, now})
 *     Pure, timer-free reference client for HELLO/WELCOME, CONFIRM/READY,
 *     PING/PONG, STATUS, RESUME/PLAYBACK_READY, RESYNC_REQUIRED/FAULT, and
 *     error replies. It tracks nonce/session/epoch, per-epoch MIDI sequences,
 *     stale-session/stale-epoch rejection, and heartbeat watermarks.
 *     Methods returning Uint8Array are wire frames ready for a serial link;
 *     handleFrame() consumes decoded {type,seq,session,payload} objects, as
 *     delivered by decodeBody() or a FrameReader onFrame callback. See the
 *     method comments below. No wall-clock timers are started.
 *
 *     Replies are accepted only for request sequence numbers this client has
 *     actually issued. A small bounded cache remembers recently completed
 *     requests so a legitimate idempotent replay (for example READY after a
 *     repeated CONFIRM) is accepted without rewinding MIDI state, while an
 *     unsolicited reply with a never-issued sequence number is rejected.
 *
 *     CONFIG is single-flight and has an explicit same-seq/same-payload retry
 *     helper. If an epoch-changing RESYNC_REQUIRED arrives while CONFIG is in
 *     flight, the old request is abandoned and its result is recorded as
 *     unknown; it is never retransmitted automatically.
 *
 * Type/control constants are exported for callers and tests.
 */

export const PROTOCOL_VERSION = 0x02;
export const SLIP = Object.freeze({END: 0xc0, ESC: 0xdb, ESC_END: 0xdc, ESC_ESC: 0xdd});

export const TYPE = Object.freeze({
  MIDI: 0x01,
  CONFIG: 0x02,
  CONTROL: 0x03,
  CONFIG_REPLY: 0x80,
  CONTROL_REPLY: 0x81,
});

export const CONTROL = Object.freeze({
  HELLO: 0x01,
  CONFIRM: 0x02,
  PING: 0x03,
  STATUS_GET: 0x04,
  RESUME: 0x05,
  WELCOME: 0x81,
  READY: 0x82,
  PONG: 0x83,
  STATUS: 0x84,
  PLAYBACK_READY: 0x85,
  RESYNC_REQUIRED: 0x86,
  FAULT: 0x87,
  ERROR: 0xff,
});

export const DEVICE_STATE = Object.freeze({
  WAIT_HELLO: 0,
  CLEANUP: 1,
  WAIT_CONFIRM: 2,
  ACTIVE: 3,
  RESYNC: 4,
});

export const REASON = Object.freeze({
  NONE: 0,
  MIDI_GAP: 1,
  MIDI_SYNTAX: 2,
  HEARTBEAT_TIMEOUT: 3,
  PHYSICAL_DISCONNECT: 4,
  PHYSICAL_FAULT: 5,
  PROTOCOL_ERROR_LIMIT: 6,
  PROGRESS_TIMEOUT: 7,
});

export const CLIENT_PHASE = Object.freeze({
  IDLE: 'idle',
  HELLO_SENT: 'hello_sent',
  WELCOME: 'welcome',
  CONFIRM_SENT: 'confirm_sent',
  ACTIVE: 'active',
  RESYNC: 'resync',
  RESUME_SENT: 'resume_sent',
  FAULT: 'fault',
});

const BODY_HEADER_BYTES = 10;
const BODY_OVERHEAD = 12; // header (10) + CRC (2)
const MAX_BODY_BYTES = 44;
const MAX_PAYLOAD_BYTES = 32;
const MAX_MIDI_BYTES = 30; // inside a MIDI payload, after the 2-byte epoch
const MAX_CONFIG_BYTES = 16;
const CONFIG_REPLY_BYTES = 3;
const MAX_COMPLETED_REQUESTS = 64;

// Per-type payload limits from the contract. min/max are payload bytes.
const TYPE_LIMITS = Object.freeze({
  [TYPE.MIDI]: Object.freeze({min: 3, max: MAX_PAYLOAD_BYTES}),
  [TYPE.CONFIG]: Object.freeze({min: 1, max: MAX_CONFIG_BYTES}),
  [TYPE.CONTROL]: Object.freeze({min: 1, max: MAX_PAYLOAD_BYTES}),
  [TYPE.CONFIG_REPLY]: Object.freeze({min: CONFIG_REPLY_BYTES, max: CONFIG_REPLY_BYTES}),
  [TYPE.CONTROL_REPLY]: Object.freeze({min: 1, max: MAX_PAYLOAD_BYTES}),
});

function typeLimit(type) {
  return Object.prototype.hasOwnProperty.call(TYPE_LIMITS, type) ? TYPE_LIMITS[type] : null;
}

function checkUint(value, bits, label) {
  const max = 2 ** bits - 1;
  if (!Number.isInteger(value) || value < 0 || value > max) throw new Error(`非法协议字段: ${label}`);
  return value;
}

// Strict byte-array conversion: unlike Uint8Array.from([undefined]), this never
// silently turns invalid payload fields into zero.
function toBytes(value, label) {
  if (value == null || typeof value === 'string') throw new Error(`非法协议字段: ${label}`);
  let values;
  try {
    values = Array.from(value);
  } catch {
    throw new Error(`非法协议字段: ${label}`);
  }
  for (const byte of values) {
    if (!Number.isInteger(byte) || byte < 0 || byte > 255) throw new Error(`非法协议字段: ${label}`);
  }
  return Uint8Array.from(values);
}

function validatePayloadLength(type, length) {
  const limit = typeLimit(type);
  if (!limit) throw new Error('非法协议类型');
  if (length < limit.min || length > limit.max) throw new Error('非法协议 payload 长度');
}

function u16le(value) {
  return [value & 0xff, (value >>> 8) & 0xff];
}

function u32le(value) {
  return [value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff];
}

function readU16le(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function readU32le(bytes, offset) {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

function sameBytes(left, right) {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

/** CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021, no reflection, xorout 0). */
export function crc16(bytes) {
  let crc = 0xffff;
  for (const byte of bytes) {
    crc ^= (byte & 0xff) << 8;
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc & 0xffff;
}

/**
 * Encode a complete v2 SLIP frame.
 * @param {number} type one of TYPE.*
 * @param {number} seq u16
 * @param {number} session u32 (0 only for HELLO from the phone)
 * @param {Iterable<number>} payload 1..32 bytes, with per-type limits
 * @returns {Uint8Array} leading 0xC0, escaped body, trailing 0xC0
 */
export function encodeFrame(type, seq, session, payload) {
  if (!Number.isInteger(type) || !typeLimit(type)) throw new Error('非法协议类型');
  checkUint(seq, 16, 'seq');
  checkUint(session, 32, 'session');
  const bytes = toBytes(payload, 'payload');
  validatePayloadLength(type, bytes.length);

  const body = new Uint8Array(BODY_HEADER_BYTES + bytes.length + 2);
  body[0] = PROTOCOL_VERSION;
  body[1] = type;
  body[2] = seq & 0xff;
  body[3] = (seq >>> 8) & 0xff;
  body[4] = bytes.length & 0xff;
  body[5] = (bytes.length >>> 8) & 0xff;
  body[6] = session & 0xff;
  body[7] = (session >>> 8) & 0xff;
  body[8] = (session >>> 16) & 0xff;
  body[9] = (session >>> 24) & 0xff;
  body.set(bytes, BODY_HEADER_BYTES);
  const crc = crc16(body.subarray(0, BODY_HEADER_BYTES + bytes.length));
  body[BODY_HEADER_BYTES + bytes.length] = crc & 0xff;
  body[BODY_HEADER_BYTES + bytes.length + 1] = (crc >>> 8) & 0xff;

  let escapedBytes = 0;
  for (const byte of body) {
    if (byte === SLIP.END || byte === SLIP.ESC) escapedBytes++;
  }
  const wire = new Uint8Array(body.length + escapedBytes + 2);
  let offset = 0;
  wire[offset++] = SLIP.END;
  for (const byte of body) {
    if (byte === SLIP.END) {
      wire[offset++] = SLIP.ESC;
      wire[offset++] = SLIP.ESC_END;
    } else if (byte === SLIP.ESC) {
      wire[offset++] = SLIP.ESC;
      wire[offset++] = SLIP.ESC_ESC;
    } else {
      wire[offset++] = byte;
    }
  }
  wire[offset++] = SLIP.END;
  return wire;
}

/**
 * Validate and decode one unescaped v2 body.
 * @param {Iterable<number>} body header + payload + LE CRC (no SLIP bytes)
 * @returns {{version:number,type:number,seq:number,session:number,payload:Uint8Array}}
 */
export function decodeBody(body) {
  const bytes = toBytes(body, 'body');
  if (bytes.length < BODY_OVERHEAD + 1 || bytes.length > MAX_BODY_BYTES) throw new Error('帧长错误');
  if (bytes[0] !== PROTOCOL_VERSION) throw new Error('协议版本错误');

  const type = bytes[1];
  const limit = typeLimit(type);
  if (!limit) throw new Error('协议类型错误');

  const length = readU16le(bytes, 4);
  if (length < 1 || length > MAX_PAYLOAD_BYTES || bytes.length !== length + BODY_OVERHEAD) {
    throw new Error('帧长错误');
  }
  if (length < limit.min || length > limit.max) throw new Error('帧头错误');

  const expectedCrc = readU16le(bytes, BODY_HEADER_BYTES + length);
  const actualCrc = crc16(bytes.subarray(0, BODY_HEADER_BYTES + length));
  if (actualCrc !== expectedCrc) throw new Error('CRC 错误');

  return {
    version: PROTOCOL_VERSION,
    type,
    seq: readU16le(bytes, 2),
    session: readU32le(bytes, 6),
    payload: bytes.slice(BODY_HEADER_BYTES, BODY_HEADER_BYTES + length),
  };
}

/**
 * Incremental SLIP + v2 frame reader. See module documentation for semantics.
 */
export class FrameReader {
  constructor(onFrame = () => {}, onError = () => {}) {
    if (typeof onFrame !== 'function' || typeof onError !== 'function') throw new TypeError('回调必须是函数');
    this.onFrame = onFrame;
    this.onError = onError;
    this.reset();
  }

  reset() {
    this.started = false;
    this.escape = false;
    this.bad = false;
    this.body = [];
  }

  feed(bytes) {
    if (bytes == null) return;
    if (typeof bytes === 'string') throw new TypeError('feed 需要字节序列');
    for (const value of bytes) {
      const byte = value & 0xff;
      if (byte === SLIP.END) {
        const hasCandidate = this.started && (this.body.length > 0 || this.bad || this.escape);
        const candidate = this.body;
        const bad = this.bad;
        const escape = this.escape;
        // Reset before invoking callbacks so a throwing callback cannot corrupt
        // the stream state.
        this.started = true;
        this.escape = false;
        this.bad = false;
        this.body = [];

        if (!hasCandidate) continue;
        if (escape) {
          this.onError(new Error('SLIP 转义不完整'));
        } else if (bad) {
          this.onError(new Error('SLIP 转义或帧长错误'));
        } else {
          let frame;
          try {
            frame = decodeBody(Uint8Array.from(candidate));
          } catch (error) {
            this.onError(error);
          }
          if (frame) this.onFrame(frame);
        }
      } else if (this.started && !this.bad) {
        if (this.escape) {
          if (byte === SLIP.ESC_END) {
            this.body.push(SLIP.END);
          } else if (byte === SLIP.ESC_ESC) {
            this.body.push(SLIP.ESC);
          } else {
            this.bad = true;
          }
          this.escape = false;
        } else if (byte === SLIP.ESC) {
          this.escape = true;
        } else {
          this.body.push(byte);
          if (this.body.length > MAX_BODY_BYTES) this.bad = true;
        }
      }
    }
  }
}

function normalizeMidiMessage(message) {
  let values;
  try {
    values = Array.from(message);
  } catch {
    throw new Error('MIDI 短消息必须完整并带 status');
  }
  if (values.length === 0) throw new Error('MIDI 短消息必须完整并带 status');
  const status = values[0];
  if (!Number.isInteger(status) || status < 0x80 || status >= 0xf0) {
    throw new Error('MIDI 短消息必须完整并带 status');
  }
  const kind = status & 0xf0;
  const expectedLength = kind === 0xc0 || kind === 0xd0 ? 2 : 3;
  if (values.length !== expectedLength) throw new Error('MIDI 短消息必须完整并带 status');
  for (let index = 1; index < values.length; index++) {
    const data = values[index];
    if (!Number.isInteger(data) || data < 0 || data > 127) throw new Error('非法 MIDI 数据字节');
  }
  return Uint8Array.from(values);
}

/**
 * Pack complete MIDI short messages into v2 MIDI payloads (epoch prefix
 * included). Each payload carries at most 30 actual MIDI bytes; a MIDI message
 * is never split between packets.
 * @param {Iterable<Iterable<number>>} messages
 * @param {number} epoch u16
 * @returns {Uint8Array[]}
 */
export function packMidi(messages, epoch) {
  checkUint(epoch, 16, 'epoch');
  if (messages == null || typeof messages === 'string') throw new Error('非法 MIDI 消息列表');
  const packets = [];
  let chunk = [];
  const flush = () => {
    if (chunk.length === 0) return;
    const payload = new Uint8Array(2 + chunk.length);
    payload[0] = epoch & 0xff;
    payload[1] = (epoch >>> 8) & 0xff;
    payload.set(chunk, 2);
    packets.push(payload);
    chunk = [];
  };

  for (const message of messages) {
    const bytes = normalizeMidiMessage(message);
    if (chunk.length + bytes.length > MAX_MIDI_BYTES) flush();
    chunk.push(...bytes);
  }
  flush();
  return packets;
}

/**
 * Timer-free reference session client. It is intentionally small: it owns the
 * host-side view of nonce/session/epoch and emits complete v2 wire frames, but
 * leaves linking, retries, and scheduling to the caller. Callers should feed
 * frames returned by FrameReader into handleFrame() and send returned frames
 * over their transport.
 */
export class ReferenceSessionClient {
  constructor({nonce = 0, now = () => Date.now()} = {}) {
    checkUint(nonce, 32, 'nonce');
    if (typeof now !== 'function') throw new TypeError('now 必须是函数');
    this.nonce = nonce;
    this.now = now;
    this.helloSentNonce = null;

    this.session = 0;
    this.epoch = 0;
    this.phase = CLIENT_PHASE.IDLE;
    this.reason = null;
    this.lastError = null;
    this.deviceState = null;
    this.caps = 0;
    this.maxMidi = 0;
    this.maxConfig = 0;
    this.lastConfigReply = null;
    this.pendingConfig = null;
    this.lastConfigRequest = null;
    this.lastConfigResult = null;

    this.expectedMidiSeq = 0;
    this.nextMidiSeq = 0;
    this.lastMidiSeq = null;
    this.resumeEpoch = null;
    this.resumeFirstMidiSeq = null;

    this.nextControlSeq = 1;
    this.lastRequestSeq = null;
    this.pending = new Map();
    this.completed = new Map();
    this.lastCompleted = new Map();
    this.unexpectedReplies = 0;
    this.ignoredFrames = 0;

    this.lastRxAt = null;
    this.lastPingAt = null;
    this.lastPingSeq = null;
    this.firstPingAt = null;
    this.lastPongAt = null;
    this.lastPongSeq = null;
    this.lastRttMs = null;
  }

  get hasSession() {
    return this.session !== 0;
  }

  get active() {
    return this.phase === CLIENT_PHASE.ACTIVE;
  }

  _allocControlSeq() {
    for (let attempts = 0; attempts < 0xffff; attempts++) {
      const seq = this.nextControlSeq;
      this.nextControlSeq = seq >= 0xffff ? 1 : seq + 1;
      if (!this.pending.has(seq)) return seq;
    }
    throw new Error('控制序号耗尽');
  }

  _request(command, payload, session) {
    const seq = this._allocControlSeq();
    this.pending.set(seq, command);
    this.lastRequestSeq = seq;
    return encodeFrame(TYPE.CONTROL, seq, session, [command, ...payload]);
  }

  _resetMidi(epoch = 0) {
    this.epoch = epoch & 0xffff;
    this.expectedMidiSeq = 0;
    this.nextMidiSeq = 0;
    this.lastMidiSeq = null;
    this.resumeEpoch = null;
    this.resumeFirstMidiSeq = null;
  }

  _resetHeartbeat() {
    this.lastPingAt = null;
    this.lastPingSeq = null;
    this.firstPingAt = null;
    this.lastPongAt = null;
    this.lastPongSeq = null;
    this.lastRttMs = null;
  }

  _rememberCompleted(seq, command) {
    // Map insertion order doubles as the eviction queue. Re-inserting a reused
    // sequence number moves it to the newest position.
    this.completed.delete(seq);
    this.completed.set(seq, command);
    this.lastCompleted.set(command, seq);
    while (this.completed.size > MAX_COMPLETED_REQUESTS) {
      const oldest = this.completed.keys().next().value;
      this.completed.delete(oldest);
    }
  }

  /**
   * Classify a reply sequence as a fresh response to an in-flight request, a
   * replay of a recently completed request, or an unsolicited/never-issued
   * sequence. Only fresh and replay replies are legitimate.
   */
  _classifyReply(seq, command) {
    const expected = this.pending.get(seq);
    if (expected !== undefined) {
      if (expected !== command) {
        this.unexpectedReplies++;
        return 'unexpected';
      }
      this.pending.delete(seq);
      this._rememberCompleted(seq, command);
      return 'new';
    }
    const completed = this.completed.get(seq);
    if (completed !== undefined) {
      if (completed !== command) {
        this.unexpectedReplies++;
        return 'unexpected';
      }
      return 'duplicate';
    }
    // Even after bounded-cache eviction, the most recent completed request per
    // command remains a legitimate idempotent replay target.
    if (this.lastCompleted.get(command) === seq) return 'duplicate';
    this.unexpectedReplies++;
    return 'unknown';
  }

  _takePending(seq, command) {
    const state = this._classifyReply(seq, command);
    return state === 'new' || state === 'duplicate';
  }

  _abandonPendingConfig(reason) {
    const request = this.pendingConfig;
    if (request === null) return false;
    this.pending.delete(request.seq);
    this.pendingConfig = null;
    this.lastConfigResult = {
      status: 'unknown',
      seq: request.seq,
      payload: Uint8Array.from(request.payload),
      session: request.session,
      epoch: request.epoch,
      reason,
    };
    return true;
  }

  /**
   * True while a CONFIG request is waiting for its fixed 3-byte reply.
   * CONFIG is single-flight; call config() only after this becomes false.
   */
  get configInFlight() {
    return this.pendingConfig !== null;
  }

  _ignore(reason) {
    this.ignoredFrames++;
    return {accepted: false, event: 'ignored', reason};
  }

  _accept(event) {
    return {accepted: true, event};
  }

  /**
   * Start (or restart) the handshake. Header session is 0; the same nonce is
   * reused until the caller changes client.nonce. A restart clears pending and
   * completed request identifiers and records any in-flight CONFIG as unknown;
   * a WELCOME must echo the nonce actually sent by the latest hello().
   * Returns the HELLO wire frame.
   */
  hello() {
    this._abandonPendingConfig('hello_restart');
    this.helloSentNonce = this.nonce;
    this.session = 0;
    this.phase = CLIENT_PHASE.HELLO_SENT;
    this.reason = null;
    this.lastError = null;
    this.deviceState = null;
    this.caps = 0;
    this.maxMidi = 0;
    this.maxConfig = 0;
    this.lastConfigReply = null;
    this.pendingConfig = null;
    this.lastConfigRequest = null;
    this.pending.clear();
    this.completed.clear();
    this.lastCompleted.clear();
    this.nextControlSeq = 1;
    this.lastRequestSeq = null;
    this._resetHeartbeat();
    this._resetMidi(0);
    return this._request(CONTROL.HELLO, u32le(this.nonce), 0);
  }

  /** Send CONFIRM for the accepted WELCOME nonce/session. */
  confirm() {
    if (!this.hasSession) throw new Error('尚未收到 WELCOME');
    if (this.phase !== CLIENT_PHASE.WELCOME && this.phase !== CLIENT_PHASE.CONFIRM_SENT) {
      throw new Error('当前阶段不能发送 CONFIRM');
    }
    this.phase = CLIENT_PHASE.CONFIRM_SENT;
    return this._request(CONTROL.CONFIRM, u32le(this.nonce), this.session);
  }

  /**
   * Send PING with the current per-epoch MIDI watermark. Also records the
   * phone-side heartbeat transmit watermark used by dueForPing()/lastRttMs.
   */
  ping(now = this.now()) {
    if (this.phase !== CLIENT_PHASE.ACTIVE || !this.hasSession) throw new Error('仅 ACTIVE 会话可发送 PING');
    const hasMidi = this.lastMidiSeq === null ? 0 : 1;
    const lastMidiSeq = this.lastMidiSeq === null ? 0 : this.lastMidiSeq;
    const frame = this._request(
      CONTROL.PING,
      [hasMidi, ...u16le(lastMidiSeq), ...u16le(this.epoch)],
      this.session,
    );
    this.lastPingAt = now;
    this.lastPingSeq = this.lastRequestSeq;
    if (this.lastPongAt === null && this.firstPingAt === null) this.firstPingAt = now;
    return frame;
  }

  /** Request STATUS_GET in the current session. */
  statusGet() {
    if (!this.hasSession) throw new Error('尚未建立会话');
    return this._request(CONTROL.STATUS_GET, [], this.session);
  }

  /**
   * Request playback resume after RESYNC_REQUIRED. The returned PLAYBACK_READY
   * supplies the authoritative expected MIDI sequence.
   */
  resume(epoch = this.epoch, firstMidiSeq = this.expectedMidiSeq) {
    if (!this.hasSession) throw new Error('尚未建立会话');
    if (this.phase !== CLIENT_PHASE.RESYNC && this.phase !== CLIENT_PHASE.RESUME_SENT && this.phase !== CLIENT_PHASE.ACTIVE) {
      throw new Error('当前阶段不能发送 RESUME');
    }
    checkUint(epoch, 16, 'epoch');
    checkUint(firstMidiSeq, 16, 'first_midi_seq');
    if (epoch !== this.epoch) throw new Error('RESUME epoch 不匹配当前 epoch');
    if (this.phase === CLIENT_PHASE.RESYNC) this.phase = CLIENT_PHASE.RESUME_SENT;
    this.resumeEpoch = epoch;
    this.resumeFirstMidiSeq = firstMidiSeq;
    return this._request(CONTROL.RESUME, [...u16le(epoch), ...u16le(firstMidiSeq)], this.session);
  }

  /**
   * Send MIDI in the current epoch. Returns zero or more complete wire frames;
   * frames are assigned consecutive per-epoch MIDI sequence numbers.
   */
  midi(messages) {
    if (!this.active || !this.hasSession) throw new Error('仅 ACTIVE 会话可发送 MIDI');
    const payloads = packMidi(messages, this.epoch);
    const frames = [];
    for (const payload of payloads) {
      const seq = this.nextMidiSeq;
      this.nextMidiSeq = (this.nextMidiSeq + 1) & 0xffff;
      frames.push(encodeFrame(TYPE.MIDI, seq, this.session, payload));
      this.lastMidiSeq = seq;
    }
    return frames;
  }

  /**
   * Send a CONFIG payload (v1 fields) and expect a 0x80 fixed-3 reply.
   * CONFIG is single-flight: calling config() while another CONFIG is pending
   * throws rather than allocating a second sequence number.
   *
   * The returned frame may be retried explicitly with retryConfig(), which
   * reuses the same SEQ and payload. There is no timer or automatic retry in
   * this client. If RESYNC_REQUIRED changes the epoch before the reply arrives,
   * the pending request is dropped, configInFlight becomes false, and
   * lastConfigResult records status 'unknown' with reason 'epoch_resync'.
   */
  config(payload) {
    if (!this.active || !this.hasSession) throw new Error('仅 ACTIVE 会话可发送 CONFIG');
    if (this.pendingConfig !== null) throw new Error('已有 CONFIG 在途，不能并发发送');
    const bytes = toBytes(payload, 'config payload');
    validatePayloadLength(TYPE.CONFIG, bytes.length);
    const seq = this._allocControlSeq();
    this.pending.set(seq, TYPE.CONFIG_REPLY);
    this.lastRequestSeq = seq;
    const request = {
      seq,
      payload: Uint8Array.from(bytes),
      session: this.session,
      epoch: this.epoch,
    };
    this.pendingConfig = request;
    this.lastConfigRequest = request;
    return encodeFrame(TYPE.CONFIG, seq, this.session, bytes);
  }

  /**
   * Explicitly retransmit the in-flight CONFIG with exactly the same SEQ and
   * payload. This is the only retry path: it never allocates a new SEQ, never
   * fires automatically, and throws when no CONFIG is pending (including after
   * a resync abandoned the old request). Optional seq/payload arguments must
   * match the pending request byte-for-byte.
   */
  retryConfig(seq = this.pendingConfig?.seq, payload = this.pendingConfig?.payload) {
    if (this.pendingConfig === null) throw new Error('没有在途 CONFIG 可重试');
    if (!this.active || !this.hasSession) throw new Error('仅 ACTIVE 会话可重试 CONFIG');
    const request = this.pendingConfig;
    if (seq !== request.seq) throw new Error('CONFIG 重试必须复用原 SEQ');
    const bytes = toBytes(payload, 'config payload');
    validatePayloadLength(TYPE.CONFIG, bytes.length);
    if (!sameBytes(bytes, request.payload)) throw new Error('CONFIG 重试必须复用原 payload');
    this.lastRequestSeq = request.seq;
    return encodeFrame(TYPE.CONFIG, request.seq, this.session, request.payload);
  }

  /**
   * Consume one decoded frame (the object returned by decodeBody/FrameReader).
   * Returns {accepted, event, reason?}; stale session/epoch and malformed
   * replies are rejected without changing active state.
   */
  handleFrame(frame, now = this.now()) {
    if (!frame || !Number.isInteger(frame.type) || !(frame.payload instanceof Uint8Array)) {
      return this._ignore('bad_frame');
    }
    const payload = frame.payload;
    this.lastRxAt = now;

    if (frame.type === TYPE.MIDI) return this._ignore('unexpected_midi');
    if (frame.type === TYPE.CONFIG_REPLY) return this._handleConfigReply(frame);
    if (frame.type !== TYPE.CONTROL_REPLY) return this._ignore('unsupported_type');
    if (payload.length === 0) return this._ignore('bad_length');

    const command = payload[0];
    if (command === CONTROL.WELCOME) return this._handleWelcome(frame, now);
    if (command === CONTROL.RESYNC_REQUIRED || command === CONTROL.FAULT) {
      if (!this.hasSession || frame.session !== this.session) return this._ignore('stale_session');
      if (frame.seq !== 0) return this._ignore('bad_seq');
      return command === CONTROL.RESYNC_REQUIRED ? this._handleResync(frame) : this._handleFault(frame);
    }

    if (!this.hasSession || frame.session !== this.session) return this._ignore('stale_session');
    if (frame.seq === 0) return this._ignore('bad_seq');

    switch (command) {
      case CONTROL.READY:
        return this._handleReady(frame, now);
      case CONTROL.PONG:
        return this._handlePong(frame, now);
      case CONTROL.STATUS:
        return this._handleStatus(frame);
      case CONTROL.PLAYBACK_READY:
        return this._handlePlaybackReady(frame);
      case CONTROL.ERROR:
        return this._handleError(frame);
      default:
        return this._ignore('unknown_command');
    }
  }

  _handleWelcome(frame, now) {
    if (
      this.phase !== CLIENT_PHASE.HELLO_SENT &&
      this.phase !== CLIENT_PHASE.WELCOME &&
      this.phase !== CLIENT_PHASE.CONFIRM_SENT &&
      this.phase !== CLIENT_PHASE.ACTIVE
    ) {
      return this._ignore('not_awaiting_welcome');
    }
    const payload = frame.payload;
    if (payload.length !== 11) return this._ignore('bad_length');
    const expectedNonce = this.helloSentNonce === null ? this.nonce : this.helloSentNonce;
    if (readU32le(payload, 1) !== expectedNonce || expectedNonce !== this.nonce) {
      return this._ignore('nonce_mismatch');
    }
    if (frame.session === 0 || frame.seq === 0) return this._ignore('bad_fields');
    const replyState = this._classifyReply(frame.seq, CONTROL.HELLO);
    if (replyState === 'unexpected' || replyState === 'unknown') return this._ignore('unexpected_reply');

    const epoch = readU16le(payload, 5);
    if (replyState === 'duplicate' && frame.session !== this.session) return this._ignore('stale_session');
    if (replyState === 'duplicate' && epoch !== this.epoch) return this._ignore('stale_epoch');
    const replay =
      replyState === 'duplicate' ||
      (this.phase === CLIENT_PHASE.ACTIVE && this.session === frame.session && this.epoch === epoch);
    if (!replay && this.session !== 0 && this.session !== frame.session) {
      this._abandonPendingConfig('session_change');
    }
    this.session = frame.session;
    this.caps = readU16le(payload, 7);
    this.maxMidi = payload[9];
    this.maxConfig = payload[10];
    this.lastWelcomeAt = now;
    this.reason = null;
    if (!replay) {
      this._resetMidi(epoch);
      this._resetHeartbeat();
      this.phase = CLIENT_PHASE.WELCOME;
    }
    return this._accept('welcome');
  }

  _handleReady(frame, now) {
    if (this.phase !== CLIENT_PHASE.CONFIRM_SENT && this.phase !== CLIENT_PHASE.ACTIVE) {
      return this._ignore('unexpected_state');
    }
    const payload = frame.payload;
    if (payload.length !== 5) return this._ignore('bad_length');
    const replyState = this._classifyReply(frame.seq, CONTROL.CONFIRM);
    if (replyState === 'unexpected' || replyState === 'unknown') return this._ignore('unexpected_reply');
    const epoch = readU16le(payload, 1);
    const expected = readU16le(payload, 3);
    const delta = (epoch - this.epoch) & 0xffff;
    // A replayed READY from an older epoch must not roll back session state.
    if (delta >= 0x8000) return this._ignore('stale_epoch');
    const wasActiveSameEpoch = this.phase === CLIENT_PHASE.ACTIVE && this.epoch === epoch;
    // A replay (or a repeated CONFIRM in ACTIVE) is idempotent: READY must not
    // move the host's MIDI send pointer backwards or reset its expected seq.
    if (!wasActiveSameEpoch) {
      this._resetMidi(epoch);
      this._resetHeartbeat();
      this.nextMidiSeq = expected;
      this.lastMidiSeq = null;
      this.expectedMidiSeq = expected;
    }
    this.epoch = epoch;
    this.phase = CLIENT_PHASE.ACTIVE;
    this.reason = null;
    this.deviceState = DEVICE_STATE.ACTIVE;
    this.lastReadyAt = now;
    return this._accept('ready');
  }

  _handlePong(frame, now) {
    const payload = frame.payload;
    if (payload.length !== 6) return this._ignore('bad_length');
    const epoch = readU16le(payload, 2);
    if (epoch !== this.epoch) return this._ignore('stale_epoch');
    const replyState = this._classifyReply(frame.seq, CONTROL.PING);
    if (replyState === 'unexpected' || replyState === 'unknown') return this._ignore('unexpected_reply');
    // A replayed PONG is accepted for idempotence but is not fresh evidence of
    // liveness, so it must not refresh the heartbeat watermark.
    if (replyState === 'duplicate') return this._accept('pong');
    this.deviceState = payload[1];
    this.expectedMidiSeq = readU16le(payload, 4);
    this.lastPongAt = now;
    this.lastPongSeq = frame.seq;
    this.firstPingAt = null;
    if (this.lastPingAt !== null) this.lastRttMs = Math.max(0, now - this.lastPingAt);
    return this._accept('pong');
  }

  _handleStatus(frame) {
    const payload = frame.payload;
    if (payload.length !== 7) return this._ignore('bad_length');
    const epoch = readU16le(payload, 2);
    if (epoch !== this.epoch) return this._ignore('stale_epoch');
    const replyState = this._classifyReply(frame.seq, CONTROL.STATUS_GET);
    if (replyState === 'unexpected' || replyState === 'unknown') return this._ignore('unexpected_reply');
    if (replyState === 'duplicate') return this._accept('status');
    this.deviceState = payload[1];
    this.expectedMidiSeq = readU16le(payload, 4);
    this.reason = payload[6];
    return this._accept('status');
  }

  _handlePlaybackReady(frame) {
    if (this.phase !== CLIENT_PHASE.RESUME_SENT && this.phase !== CLIENT_PHASE.ACTIVE) {
      return this._ignore('unexpected_state');
    }
    const payload = frame.payload;
    if (payload.length !== 5) return this._ignore('bad_length');
    const epoch = readU16le(payload, 1);
    if (epoch !== this.epoch) return this._ignore('stale_epoch');
    const replyState = this._classifyReply(frame.seq, CONTROL.RESUME);
    if (replyState === 'unexpected' || replyState === 'unknown') return this._ignore('unexpected_reply');
    const expected = readU16le(payload, 3);
    // Only the first PLAYBACK_READY after entering RESUME_SENT establishes the
    // recovery sequence. A replayed reply (or an ACTIVE-session replay) must
    // never roll nextMidiSeq back over MIDI already transmitted.
    if (replyState === 'new' && this.phase === CLIENT_PHASE.RESUME_SENT) {
      this.expectedMidiSeq = expected;
      this.nextMidiSeq = expected;
      this.lastMidiSeq = null;
    }
    this.phase = CLIENT_PHASE.ACTIVE;
    this.reason = null;
    this.deviceState = DEVICE_STATE.ACTIVE;
    return this._accept('playback_ready');
  }

  _handleResync(frame) {
    const payload = frame.payload;
    if (payload.length !== 4) return this._ignore('bad_length');
    const epoch = readU16le(payload, 1);
    const delta = (epoch - this.epoch) & 0xffff;
    // Epochs are 16-bit and increase on recovery. Deltas in [1, 0x7fff] are a
    // newer epoch; 0 is an idempotent replay only while already in RESYNC; the
    // upper half-space is an old notification and must not roll state back.
    if (delta >= 0x8000 || (delta === 0 && this.phase !== CLIENT_PHASE.RESYNC)) {
      return this._ignore('stale_epoch');
    }
    if (delta !== 0) {
      this._abandonPendingConfig('epoch_resync');
      this._resetMidi(epoch);
      this._resetHeartbeat();
    }
    this.phase = CLIENT_PHASE.RESYNC;
    this.reason = payload[3];
    this.deviceState = DEVICE_STATE.RESYNC;
    return this._accept('resync_required');
  }

  _handleFault(frame) {
    const payload = frame.payload;
    if (payload.length !== 2) return this._ignore('bad_length');
    this._abandonPendingConfig('fault');
    this._resetHeartbeat();
    this.phase = CLIENT_PHASE.FAULT;
    this.reason = payload[1];
    this.deviceState = DEVICE_STATE.WAIT_HELLO;
    return this._accept('fault');
  }

  _handleError(frame) {
    const payload = frame.payload;
    if (payload.length !== 3) return this._ignore('bad_length');
    const originalCommand = payload[1];
    const replyState = this._classifyReply(frame.seq, originalCommand);
    if (replyState === 'unexpected' || replyState === 'unknown') return this._ignore('unexpected_reply');
    if (replyState === 'duplicate') return this._accept('error');
    this.lastError = {seq: frame.seq, command: originalCommand, result: payload[2]};
    if (originalCommand === CONTROL.HELLO) this.phase = CLIENT_PHASE.IDLE;
    else if (originalCommand === CONTROL.CONFIRM) this.phase = CLIENT_PHASE.WELCOME;
    return this._accept('error');
  }

  _handleConfigReply(frame) {
    if (!this.hasSession || frame.session !== this.session) return this._ignore('stale_session');
    if (frame.seq === 0) return this._ignore('bad_seq');
    if (frame.payload.length !== CONFIG_REPLY_BYTES) return this._ignore('bad_length');
    const replyState = this._classifyReply(frame.seq, TYPE.CONFIG_REPLY);
    if (replyState === 'unexpected' || replyState === 'unknown') return this._ignore('unexpected_reply');
    if (replyState === 'new') {
      const request = this.pendingConfig;
      this.pendingConfig = null;
      if (request !== null) {
        this.lastConfigResult = {
          status: 'ok',
          seq: request.seq,
          payload: Uint8Array.from(request.payload),
          session: request.session,
          epoch: request.epoch,
          reply: Uint8Array.from(frame.payload),
        };
      }
    }
    this.lastConfigReply = Uint8Array.from(frame.payload);
    return this._accept('config_reply');
  }

  /** True when the 500 ms phone-side PING watermark has elapsed in ACTIVE. */
  dueForPing(now = this.now(), intervalMs = 500) {
    if (this.phase !== CLIENT_PHASE.ACTIVE) return false;
    return this.lastPingAt === null || now - this.lastPingAt >= intervalMs;
  }

  /**
   * Milliseconds since the last PONG. Before the first PONG, this falls back to
   * the first PING sent after the last reset so repeated PINGs cannot hide a
   * reply-less session. Returns null before either event.
   */
  heartbeatAgeMs(now = this.now()) {
    const watermark = this.lastPongAt !== null ? this.lastPongAt : this.firstPingAt;
    if (watermark === null) return null;
    return Math.max(0, now - watermark);
  }

  /**
   * True when an ACTIVE session's heartbeat watermark is older than timeout.
   * The watermark is the last accepted PONG; if no PONG has ever arrived, it is
   * the first outstanding PING, so a missing first PONG still times out.
   */
  heartbeatTimedOut(now = this.now(), timeoutMs = 2000) {
    if (this.phase !== CLIENT_PHASE.ACTIVE) return false;
    const age = this.heartbeatAgeMs(now);
    return age !== null && age > timeoutMs;
  }
}
