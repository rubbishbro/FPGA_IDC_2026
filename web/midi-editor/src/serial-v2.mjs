// Web Serial transport for Bluetooth session protocol v2.
//
// Fixed contract: docs/蓝牙会话协议v2_实现约定.md and protocol-v2.mjs.
// This module owns the browser/WebSerial side only: a single serialized write
// queue, ACTIVE-gated MIDI, stop-and-wait CONFIG, heartbeat scheduling and
// playback recovery. It does not claim that the FPGA applied a frame merely
// because writer.write() resolved.
//
// Compatibility with serial.mjs: connect/send/cancel/panic/disconnect, the
// port/txFrames/txBytes/rxFrames fields, and the onFault hook. V2 adds
// configure()/requestStatus()/onRecovery/onRecovered and explicit test hooks.
// `connected` is intentionally stricter than serial.mjs: it means the v2
// session reached READY/ACTIVE, not merely that the port is open.

import {
  CLIENT_PHASE,
  FrameReader,
  REASON,
  ReferenceSessionClient,
  SLIP,
} from './protocol-v2.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const cancelled = (message = '发送已取消') => Object.assign(Error(message), {name: 'AbortError'});

const DEFAULT_OPTIONS = Object.freeze({
  // Short values are injectable for tests. Production defaults match the
  // implementation contract: 500 ms PING, 2 s heartbeat timeout.
  pingIntervalMs: 500,
  pongTimeoutMs: 2000,
  handshakeTimeoutMs: 3000,
  configTimeoutMs: 1500,
  statusTimeoutMs: 1500,
  recoveryTimeoutMs: 3000,
  maxQueue: 64,
  queueTimeoutMs: 200,
  pacing: true,
  pacingMsPerByte: null,
  now: () => Date.now(),
});

function randomNonce() {
  const cryptoApi = globalThis.crypto;
  if (cryptoApi?.getRandomValues) {
    const words = new Uint32Array(1);
    cryptoApi.getRandomValues(words);
    return words[0] >>> 0;
  }
  return (Math.floor(Math.random() * 0xffffffff) + 1) >>> 0;
}

// Validate and group complete MIDI short messages exactly like packMidi():
// one v2 frame carries at most 30 actual MIDI bytes and never splits a message.
// The raw messages (not encoded frames) stay in the queue; MIDI sequence
// numbers are allocated only when the group is actually dispatched.
function splitMidiMessages(messages) {
  if (messages == null || typeof messages === 'string') throw Error('非法 MIDI 消息列表');
  const groups = [];
  let group = [];
  let bytesInGroup = 0;
  for (const message of messages) {
    let values;
    try {
      values = Array.from(message);
    } catch {
      throw Error('MIDI 短消息必须完整并带 status');
    }
    if (values.length === 0) throw Error('MIDI 短消息必须完整并带 status');
    const status = values[0];
    if (!Number.isInteger(status) || status < 0x80 || status >= 0xf0) {
      throw Error('MIDI 短消息必须完整并带 status');
    }
    const kind = status & 0xf0;
    const expectedLength = kind === 0xc0 || kind === 0xd0 ? 2 : 3;
    if (values.length !== expectedLength) throw Error('MIDI 短消息必须完整并带 status');
    for (let index = 1; index < values.length; index++) {
      const data = values[index];
      if (!Number.isInteger(data) || data < 0 || data > 127) throw Error('非法 MIDI 数据字节');
    }
    if (bytesInGroup + values.length > 30) {
      groups.push(group);
      group = [];
      bytesInGroup = 0;
    }
    group.push(values);
    bytesInGroup += values.length;
  }
  if (group.length > 0) groups.push(group);
  return groups;
}

// Corrupt only the CRC of an already well-formed SLIP frame. Type, version,
// length and payload stay untouched; the bytes are re-escaped afterwards.
function corruptCrc(wire) {
  const body = [];
  let escaped = false;
  for (let index = 1; index < wire.length - 1; index++) {
    const byte = wire[index];
    if (escaped) {
      if (byte === SLIP.ESC_END) body.push(SLIP.END);
      else if (byte === SLIP.ESC_ESC) body.push(SLIP.ESC);
      else throw Error('测试帧包含非法 SLIP 转义');
      escaped = false;
    } else if (byte === SLIP.ESC) {
      escaped = true;
    } else {
      body.push(byte);
    }
  }
  if (escaped || body.length < 3) throw Error('测试帧结构错误');
  body[body.length - 1] ^= 0x01;
  const out = [SLIP.END];
  for (const byte of body) {
    if (byte === SLIP.END) out.push(SLIP.ESC, SLIP.ESC_END);
    else if (byte === SLIP.ESC) out.push(SLIP.ESC, SLIP.ESC_ESC);
    else out.push(byte);
  }
  out.push(SLIP.END);
  return Uint8Array.from(out);
}

function readU16(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function statusData(frame, at) {
  return {
    state: frame.payload[1],
    epoch: readU16(frame.payload, 2),
    expectedMidiSeq: readU16(frame.payload, 4),
    reason: frame.payload[6],
    seq: frame.seq,
    sessionId: frame.session,
    at,
  };
}

export class V2SerialLink {
  constructor(onState = () => {}, onLog = () => {}, serialApi = globalThis.navigator?.serial, options = {}) {
    this.onState = typeof onState === 'function' ? onState : () => {};
    this.onLog = typeof onLog === 'function' ? onLog : () => {};
    this.serialApi = serialApi;
    this.options = {...DEFAULT_OPTIONS, ...(options || {})};
    if (typeof this.options.now !== 'function') throw new TypeError('options.now 必须是函数');
    this.now = this.options.now;

    this.port = null;
    this.writer = null;
    this.reader = null;
    this.readTask = null;
    this.pumpTask = null;
    this.baud = 115200;
    this.txFrames = 0;
    this.txBytes = 0;
    this.rxFrames = 0;

    this.queue = [];
    this.pumping = false;
    this._current = null;
    this.closing = false;
    this.failed = false;
    this._connectDeferred = null;
    this._disconnectPromise = null;
    this._lifecycleGeneration = 0;
    this.client = this._newClient();

    this._handshakeTimer = null;
    this._pingTimer = null;
    this._watchTimer = null;
    this._recoveryTimer = null;
    this._pingQueued = false;
    this._heartbeatPaused = false;
    this._recovery = null;
    this._configRequest = null;
    this._statusPending = new Map();
    this._lastStatus = null;

    this.onFault = null;
    this.onRecovery = null;
    this.onRecovered = null;

    this._disconnectHandler = (event) => {
      if (!this.port || this.closing) return;
      if (event?.target !== this.port && event?.port !== this.port) return;
      const error = Object.assign(Error('串口已断开'), {reason: REASON.PHYSICAL_DISCONNECT});
      this._fault(error);
      this.disconnect().catch(() => {});
    };
    this.serialApi?.addEventListener?.('disconnect', this._disconnectHandler);
  }

  // ------------------------------------------------------------------
  // Public state
  // ------------------------------------------------------------------

  /** True only for an ACTIVE/READY v2 session with a live writer. */
  get connected() {
    return Boolean(
      this.writer &&
        !this.closing &&
        !this.failed &&
        this.client?.phase === CLIENT_PHASE.ACTIVE,
    );
  }

  get phase() {
    // A local fault (heartbeat/write/read) can happen while the reference
    // client still says ACTIVE; UI must not present that as a ready session.
    if (this.failed && this.port) return CLIENT_PHASE.FAULT;
    if (!this.port) return CLIENT_PHASE.IDLE;
    return this.client?.phase ?? CLIENT_PHASE.IDLE;
  }

  get sessionId() {
    return this.client?.session ?? 0;
  }

  get session() {
    return this.sessionId;
  }

  get playbackEpoch() {
    return this.client?.epoch ?? 0;
  }

  get epoch() {
    return this.playbackEpoch;
  }

  get lastStatus() {
    return this._lastStatus;
  }

  get configPending() {
    return this._configRequest !== null;
  }

  // ------------------------------------------------------------------
  // Connection and lifecycle
  // ------------------------------------------------------------------

  _newClient() {
    const nonce = this.options.nonce === undefined ? randomNonce() : this.options.nonce >>> 0;
    return new ReferenceSessionClient({nonce, now: () => this.now()});
  }

  async connect(baud = 115200) {
    if (!this.serialApi) throw Error('此浏览器没有 Web Serial，请在 Chrome / Edge 打开 localhost');
    if (this.port) throw Error('串口已打开或正在关闭');

    const generation = ++this._lifecycleGeneration;
    this.baud = Number(baud) || 115200;
    this.closing = false;
    this.failed = false;
    this.queue = [];
    this._current = null;
    this.pumping = false;
    this._heartbeatPaused = false;
    this._recovery = null;
    this._lastStatus = null;
    this._statusPending.clear();
    this._configRequest = null;
    this._pingQueued = false;
    this.client = this._newClient();
    this.decoder = new FrameReader(
      (frame) => this._onFrame(frame),
      (error) => this.onLog('RX 错误', error.message),
    );

    let readyResolve;
    let readyReject;
    const ready = new Promise((resolve, reject) => {
      readyResolve = resolve;
      readyReject = reject;
    });
    this._connectDeferred = {resolve: readyResolve, reject: readyReject};

    let port;
    try {
      port = await this.serialApi.requestPort();
      await port.open({
        baudRate: this.baud,
        dataBits: 8,
        stopBits: 1,
        parity: 'none',
        flowControl: 'none',
        bufferSize: 4096,
      });
    } catch (error) {
      this._connectDeferred = null;
      throw Error(`打开串口失败：${error.message}`);
    }
    if (this.closing || generation !== this._lifecycleGeneration) {
      this._connectDeferred = null;
      try {
        await port.close();
      } catch {
        // Best effort only; the original close request already lost the race.
      }
      throw cancelled('连接已取消');
    }

    this.port = port;
    this.writer = port.writable.getWriter();
    this.readTask = this._readLoop();
    this.onLog('连接', `${this.baud} baud · 8N1 · v2 SLIP/CRC`);
    this._notify();

    this._startHandshakeTimer();
    this._enqueueControl({kind: 'control', label: 'HELLO', frame: this.client.hello()});

    try {
      await ready;
    } catch (error) {
      await this.disconnect().catch(() => {});
      throw error;
    }
    return this;
  }

  async _readLoop() {
    try {
      this.reader = this.port.readable.getReader();
      while (!this.closing) {
        const {value, done} = await this.reader.read();
        if (done) break;
        if (value?.length) this.decoder.feed(value);
      }
      if (!this.closing) throw Error('串口接收流结束');
    } catch (error) {
      if (!this.closing && !this.failed) this._fault(Error(`串口接收失败：${error.message}`));
    } finally {
      try {
        this.reader?.releaseLock();
      } catch {
        // The stream may already be errored/released.
      }
      this.reader = null;
      this._notify();
    }
  }

  async disconnect() {
    if (this._disconnectPromise) return this._disconnectPromise;
    this._lifecycleGeneration++;
    this.closing = true;
    this.failed = true;
    this._clearAllTimers();
    this._pingQueued = false;
    this._recovery = null;

    const abort = cancelled('串口已断开');
    this._rejectQueue(abort);
    this._rejectStatuses(abort);
    this._rejectConfig(abort, false);
    this._rejectConnect(abort);
    this._notify();

    this._disconnectPromise = (async () => {
      try {
        try {
          await this.reader?.cancel();
        } catch {
          // A physical disconnect can make cancel() itself fail.
        }
        try {
          await this.readTask;
        } catch {
          // readLoop already reported/recovered its own error.
        }
        // Preserve the current write until it retires; then release its lock.
        try {
          await this.pumpTask;
        } catch {
          // pump() reports write failures through _fault.
        }
        if (this.writer) {
          try {
            await this.writer.ready;
          } catch {
            // The writable stream may already be errored.
          }
          try {
            this.writer.releaseLock();
          } catch {
            // Ignore an already-released lock.
          }
          this.writer = null;
        }
        if (this.port) {
          try {
            await this.port.close();
          } catch (error) {
            this.onLog('关闭串口失败', error.message);
          }
        }
      } finally {
        this.port = null;
        this.writer = null;
        this.reader = null;
        this.readTask = null;
        this.pumpTask = null;
        this.closing = false;
        this._notify();
      }
    })();

    try {
      return await this._disconnectPromise;
    } finally {
      this._disconnectPromise = null;
    }
  }

  // ------------------------------------------------------------------
  // Business API
  // ------------------------------------------------------------------

  send(messages) {
    if (!this.connected) return Promise.reject(Error('串口未连接或 v2 会话未就绪'));
    if (this._configRequest) return Promise.reject(Error('CONFIG 在途，暂停发送 MIDI'));
    let groups;
    try {
      groups = splitMidiMessages(messages);
    } catch (error) {
      return Promise.reject(error);
    }
    if (groups.length === 0) return Promise.resolve();
    // Bound all queued/current groups, not send() calls. One queue entry is
    // one group, so a short control frame can be interleaved between groups
    // instead of waiting for a large MIDI batch to finish.
    if (this._pendingMidiGroups() + groups.length > this.options.maxQueue) {
      const error = Error('串口发送积压，已停止播放');
      this._fault(error);
      return Promise.reject(error);
    }
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => {
      resolve = res;
      reject = rej;
    });
    const batch = {
      epoch: this.client.epoch,
      remaining: groups.length,
      settled: false,
      resolve,
      reject,
    };
    const queuedAt = this.now();
    for (const group of groups) {
      this.queue.push({kind: 'midi', label: 'MIDI', batch, messages: group, queuedAt});
    }
    this._kick();
    return promise;
  }

  /**
   * Stop unsent business traffic without disturbing control traffic. The
   * write currently inside writer.write() is allowed to retire. No sequence
   * number is allocated for a group that was not actually handed to the
   * writer, so a later MIDI frame continues without a hole.
   */
  cancel() {
    this._clearUnsentMidi(cancelled());
    this._notify();
  }

  async panic(channels = Array.from({length: 16}, (_, index) => index)) {
    this.cancel();
    if (!this.connected) {
      this.onLog('清音请求', '串口未就绪，未写入板端');
      return;
    }
    if (this._configRequest) {
      this.onLog('清音请求', 'CONFIG 在途；未在配置之后插入 MIDI');
      return;
    }
    const messages = channels.flatMap((channel) => [
      [0xb0 | (channel & 0x0f), 64, 0],
      [0xb0 | (channel & 0x0f), 120, 0],
    ]);
    try {
      await this.send(messages);
      this.onLog('清音请求', 'CC64=0 + CC120 已写入；板端生效仍需状态确认');
    } catch (error) {
      this.onLog('清音失败', error.message);
      throw error;
    }
  }

  /**
   * Submit one stop-and-wait CONFIG. Resolves only on the matching 3-byte
   * CONFIG_REPLY with {result, command, seq}. A bounded timeout rejects with
   * an Error whose `.result` is a status:'unknown' record.
   */
  configure(payload) {
    if (!this.connected) return Promise.reject(Error('串口未连接或 v2 会话未就绪'));
    if (this._configRequest) return Promise.reject(Error('已有 CONFIG 在途，不能并发发送'));
    let frame;
    try {
      frame = this.client.config(payload);
    } catch (error) {
      return Promise.reject(error);
    }
    const request = this.client.pendingConfig;
    if (!request) return Promise.reject(Error('CONFIG 请求创建失败'));

    let resolve;
    let reject;
    const promise = new Promise((res, rej) => {
      resolve = res;
      reject = rej;
    });
    const config = {
      seq: request.seq,
      payload: Uint8Array.from(request.payload),
      frame,
      promise,
      resolve,
      reject,
      timer: null,
      written: false,
      settled: false,
    };
    this._configRequest = config;
    // CONFIG is a barrier: append it behind already queued MIDI. New MIDI is
    // rejected while _configRequest is non-null.
    this.queue.push({kind: 'config', label: 'CONFIG', frame, config});
    this._kick();
    return promise;
  }

  /**
   * Retransmit the in-flight CONFIG with exactly the same SEQ and payload.
   * This is explicit only; there is no automatic CONFIG retry. Returns the
   * same promise as the original configure() call.
   */
  retryConfig(seq = this._configRequest?.seq, payload = this._configRequest?.payload) {
    if (!this._configRequest) throw Error('没有在途 CONFIG 可重试');
    if (!this._configRequest.written) throw Error('CONFIG 尚未写出，不能重试');
    const frame = this.client.retryConfig(seq, payload);
    const config = this._configRequest;
    // The retry itself restarts the bounded wait once it reaches the writer.
    this._clearTimer(config, 'timer');
    config.written = false;
    this._enqueueControl({kind: 'config-retry', label: 'CONFIG 重试', frame, config});
    return config.promise;
  }

  /** Ask for STATUS_GET and resolve with the decoded matching STATUS reply. */
  requestStatus() {
    if (!this.connected) return Promise.reject(Error('串口未连接或 v2 会话未就绪'));
    if (this._statusPending.size) return Promise.reject(Error('已有状态查询在途，请等待回复'));
    let frame;
    let seq;
    try {
      frame = this.client.statusGet();
      seq = this.client.lastRequestSeq;
    } catch (error) {
      return Promise.reject(error);
    }
    return new Promise((resolve, reject) => {
      const entry = {
        kind: 'status',
        label: 'STATUS_GET',
        frame,
        seq,
        resolve,
        reject,
        timer: null,
        settled: false,
      };
      this._statusPending.set(seq, entry);
      this._enqueueControl(entry);
    });
  }

  // ------------------------------------------------------------------
  // Explicit test hooks (ACTIVE only)
  // ------------------------------------------------------------------

  /**
   * Stop sending scheduled PINGs but keep the local heartbeat watchdog alive.
   * A first-PONG watermark is established so a missing reply still faults even
   * though no new PING leaves the host.
   */
  pauseHeartbeatForTest() {
    if (!this.connected) throw Error('仅 ACTIVE 会话可暂停心跳');
    this._heartbeatPaused = true;
    if (this.client.lastPongAt === null && this.client.firstPingAt === null) {
      this.client.firstPingAt = this.now();
    }
    this.onLog('测试', '心跳发送已暂停；本地 PONG 超时监视仍在运行');
  }

  /**
   * Send a well-formed CONFIG frame with only its CRC corrupted. The test
   * request is abandoned before transmission, so a late/valid-looking reply
   * can never be reported as a normal configuration completion.
   */
  sendBadCrcForTest() {
    if (!this.connected) throw Error('仅 ACTIVE 会话可发送坏 CRC 测试帧');
    if (this._configRequest) throw Error('CONFIG 在途，不能发送坏 CRC 测试帧');
    if (this.queue.length >= this.options.maxQueue) throw Error('发送队列已满，请等待后再测试');
    const frame = this.client.config([0x01, 0x00, 0x00]);
    const request = this.client.pendingConfig;
    this._abandonClientConfig('bad_crc_test');
    const wire = corruptCrc(frame);
    const result = {seq: request.seq, wire};
    return new Promise((resolve, reject) => {
      this._enqueueControl({
        kind: 'raw',
        label: 'BAD_CRC_TEST',
        wire,
        result,
        resolve,
        reject,
        settled: false,
      });
      this.onLog('测试', '坏 CRC CONFIG 已排入发送队列；不参与正常配置结果');
    });
  }

  // ------------------------------------------------------------------
  // Frame handling
  // ------------------------------------------------------------------

  _onFrame(frame) {
    this.rxFrames++;
    this.onLog('RX', `type ${frame.type.toString(16)} · seq ${frame.seq}`);
    if (this.closing || this.failed) return;
    let result;
    try {
      result = this.client.handleFrame(frame, this.now());
    } catch (error) {
      this.onLog('RX 处理失败', error.message);
      return;
    }
    if (!result?.accepted) {
      this.onLog('RX 忽略', result?.reason ?? 'unknown');
      return;
    }
    switch (result.event) {
      case 'welcome':
        this._onWelcome();
        break;
      case 'ready':
        this._onReady();
        break;
      case 'pong':
        this.onLog('心跳', `PONG · RTT ${this.client.lastRttMs ?? '?'} ms`);
        break;
      case 'status':
        this._resolveStatus(frame);
        break;
      case 'config_reply':
        this._resolveConfig(frame);
        break;
      case 'resync_required':
        this._beginRecovery(frame);
        break;
      case 'playback_ready':
        this._finishRecovery();
        break;
      case 'fault':
        this._onDeviceFault(frame);
        break;
      case 'error':
        this._onProtocolError();
        break;
      default:
        break;
    }
    this._notify();
  }

  _onWelcome() {
    if (this.closing || this.failed) return;
    if (this.client.phase !== CLIENT_PHASE.WELCOME) return;
    try {
      const frame = this.client.confirm();
      this._enqueueControl({kind: 'control', label: 'CONFIRM', frame});
      this.onLog('会话', `WELCOME session=${this.client.session} epoch=${this.client.epoch}`);
    } catch (error) {
      this._fault(error);
    }
  }

  _onReady() {
    if (this.closing || this.failed) return;
    this._clearTimer('_handshakeTimer');
    if (this._connectDeferred) {
      this._startHeartbeatTimers();
      this.onLog('会话', `READY session=${this.client.session} epoch=${this.client.epoch}`);
      this._resolveConnect();
    } else {
      this.onLog('会话', 'READY 重放');
    }
  }

  _onDeviceFault(frame) {
    const reason = frame.payload[1];
    this._fault(Object.assign(Error(`板端故障 reason=${reason}`), {reason}));
  }

  _onProtocolError() {
    const error = this.client.lastError;
    if (!error) return;
    const status = this._statusPending.get(error.seq);
    if (status) {
      this._statusPending.delete(error.seq);
      this._rejectEntry(
        status,
        Object.assign(Error(`STATUS_GET 被拒绝 result=${error.result}`), {result: error.result}),
      );
    }
    const config = this._configRequest;
    if (config && config.seq === error.seq) {
      this._rejectConfig(
        Object.assign(Error(`CONFIG 被拒绝 result=${error.result}`), {
          result: {
            result: error.result,
            command: error.command,
            seq: error.seq,
            status: 'rejected',
          },
        }),
        false,
      );
    }
  }

  // ------------------------------------------------------------------
  // CONFIG
  // ------------------------------------------------------------------

  _resolveConfig(frame) {
    const config = this._configRequest;
    if (!config || config.seq !== frame.seq) return;
    this._clearTimer(config, 'timer');
    this._configRequest = null;
    config.settled = true;
    const result = {
      result: frame.payload[2],
      command: frame.payload[1],
      seq: frame.seq,
    };
    this.onLog('配置', `SEQ ${result.seq} · result ${result.result}`);
    config.resolve?.(result);
  }

  _startConfigTimer(config) {
    this._clearTimer(config, 'timer');
    if (config.settled) return;
    config.timer = setTimeout(() => this._timeoutConfig(config), this.options.configTimeoutMs);
  }

  _timeoutConfig(config) {
    if (config.settled || this._configRequest !== config) return;
    this._abandonClientConfig('timeout');
    this._configRequest = null;
    config.settled = true;
    const result = {
      result: null,
      command: null,
      seq: config.seq,
      status: 'unknown',
      reason: 'timeout',
    };
    const error = Object.assign(Error('CONFIG 回复超时，结果未知'), {result});
    config.reject?.(error);
    this.queue = this.queue.filter((entry) => entry.kind !== 'config' || entry.config !== config);
    if (this._current?.kind === 'config' && this._current.config === config) {
      this._current.cancelled = true;
    }
    this._notify();
  }

  _abandonClientConfig(reason) {
    const request = this.client.pendingConfig;
    if (!request) return null;
    this.client.pending.delete(request.seq);
    this.client.pendingConfig = null;
    this.client.lastConfigResult = {
      status: 'unknown',
      seq: request.seq,
      payload: Uint8Array.from(request.payload),
      session: request.session,
      epoch: request.epoch,
      reason,
    };
    return request;
  }

  _rejectConfig(error, unknown) {
    const config = this._configRequest;
    if (!config) return;
    this._configRequest = null;
    this._clearTimer(config, 'timer');
    config.settled = true;
    let finalError = error;
    if (unknown) {
      finalError = Object.assign(Error(error?.message ?? String(error)), {
        result: {
          result: null,
          command: null,
          seq: config.seq,
          status: 'unknown',
          reason: error.reason ?? 'recovery',
        },
      });
    }
    config.reject?.(finalError);
    this.queue = this.queue.filter(
      (entry) => !((entry.kind === 'config' || entry.kind === 'config-retry') && entry.config === config),
    );
    if (
      (this._current?.kind === 'config' || this._current?.kind === 'config-retry') &&
      this._current.config === config
    ) {
      this._current.cancelled = true;
    }
  }

  _rejectConfigUnknown(reason) {
    const config = this._configRequest;
    if (!config) return;
    const error = Object.assign(Error('RESYNC：旧 CONFIG 结果未知，禁止自动重试'), {reason});
    this._rejectConfig(error, true);
  }

  // ------------------------------------------------------------------
  // STATUS
  // ------------------------------------------------------------------

  _resolveStatus(frame) {
    const entry = this._statusPending.get(frame.seq);
    if (!entry) return;
    this._statusPending.delete(frame.seq);
    this._clearTimer(entry, 'timer');
    if (entry.settled) return;
    entry.settled = true;
    const data = statusData(frame, this.now());
    this._lastStatus = data;
    entry.resolve?.(data);
  }

  _startStatusTimer(entry) {
    if (entry.settled) return;
    this._clearTimer(entry, 'timer');
    entry.timer = setTimeout(() => {
      if (entry.settled) return;
      this._statusPending.delete(entry.seq);
      this._rejectEntry(entry, Error('STATUS_GET 回复超时'));
    }, this.options.statusTimeoutMs);
  }

  _rejectStatuses(error) {
    for (const entry of this._statusPending.values()) {
      this._clearTimer(entry, 'timer');
      this._rejectEntry(entry, error);
    }
    this._statusPending.clear();
    this.queue = this.queue.filter((entry) => entry.kind !== 'status');
    if (this._current?.kind === 'status') this._current.cancelled = true;
  }

  // ------------------------------------------------------------------
  // Recovery
  // ------------------------------------------------------------------

  _beginRecovery(frame) {
    const reason = frame.payload[3];
    const epoch = this.client.epoch;
    if (this._recovery?.epoch === epoch) {
      // A duplicate RESYNC notification in the same new epoch must not issue a
      // second RESUME or repeat the host-side recovery callback.
      this.onLog('恢复', `忽略重复 RESYNC reason=${reason} epoch=${epoch}`);
      return;
    }
    this._clearTimer('_recoveryTimer');
    this._stopHeartbeatTimers();
    this._clearUnsentMidi(cancelled('RESYNC：旧 epoch 的 MIDI 已丢弃'));
    this._rejectConfigUnknown('epoch_resync');
    this._rejectStatuses(Error('RESYNC：旧 STATUS 请求已作废'));
    this._recovery = {epoch, reason};

    let resume;
    try {
      resume = this.client.resume(epoch, this.client.expectedMidiSeq);
    } catch (error) {
      this._fault(error);
      return;
    }
    this._enqueueControl({kind: 'control', label: 'RESUME', frame: resume});
    this.onLog('恢复', `RESYNC reason=${reason} · 新 epoch=${epoch} · 已排入 RESUME`);
    try {
      this.onRecovery?.({epoch, reason, sessionId: this.client.session});
    } catch (error) {
      this.onLog('onRecovery 异常', error.message);
    }
    this._recoveryTimer = setTimeout(() => {
      if (!this._recovery) return;
      this._fault(Error('PLAYBACK_READY 超时'));
    }, this.options.recoveryTimeoutMs);
    this._notify();
  }

  _finishRecovery() {
    if (!this._recovery) return;
    const info = this._recovery;
    this._recovery = null;
    this._clearTimer('_recoveryTimer');
    this._startHeartbeatTimers();
    this.onLog('恢复', `PLAYBACK_READY epoch=${info.epoch} · 可以重建按键/踏板并继续 MIDI`);
    try {
      this.onRecovered?.(info);
    } catch (error) {
      this.onLog('onRecovered 异常', error.message);
    }
  }

  // ------------------------------------------------------------------
  // Heartbeat and faults
  // ------------------------------------------------------------------

  _startHeartbeatTimers() {
    this._stopHeartbeatTimers();
    this._pingTimer = setInterval(
      () => this._maybePing(),
      Math.max(5, Math.floor(this.options.pingIntervalMs)),
    );
    this._watchTimer = setInterval(
      () => this._checkHeartbeat(),
      Math.max(5, Math.floor(this.options.pongTimeoutMs / 4)),
    );
  }

  _startHandshakeTimer() {
    this._clearTimer('_handshakeTimer');
    this._handshakeTimer = setTimeout(() => {
      if (this.closing || this.failed || this.client.active) return;
      this._fault(Error('v2 握手超时：未在限定时间内达到 READY'));
    }, this.options.handshakeTimeoutMs);
  }

  _stopHeartbeatTimers() {
    this._clearTimer('_pingTimer');
    this._clearTimer('_watchTimer');
    this._pingQueued = false;
  }

  _maybePing() {
    if (this.closing || this.failed || !this.client.active) return;
    if (this._heartbeatPaused || this._pingQueued) return;
    if (!this.client.dueForPing(this.now(), this.options.pingIntervalMs)) return;
    this._pingQueued = true;
    this._enqueueControl({
      kind: 'ping',
      label: 'PING',
      prepare: () => {
        this._pingQueued = false;
        if (this.closing || this.failed || !this.client.active) return null;
        // Built here, at dispatch: the watermark therefore covers every MIDI
        // frame already written, and never predicts a queued frame.
        return this.client.ping(this.now());
      },
    });
  }

  _checkHeartbeat() {
    if (this.closing || this.failed || !this.client.active) return;
    if (this.client.heartbeatTimedOut(this.now(), this.options.pongTimeoutMs)) {
      this._fault(Object.assign(Error('v2 心跳超时，已停止业务'), {reason: REASON.HEARTBEAT_TIMEOUT}));
    }
  }

  _fault(error) {
    if (this.failed || this.closing) return;
    this.failed = true;
    this._clearAllTimers();
    this._pingQueued = false;
    this._recovery = null;
    this._rejectConnect(error);
    this._rejectQueue(error);
    this._rejectStatuses(error);
    this._rejectConfig(error, true);
    this.onLog('故障', error.message);
    try {
      this.onFault?.(error);
    } catch (callbackError) {
      this.onLog('onFault 异常', callbackError.message);
    }
    this._notify();
  }

  _rejectConnect(error) {
    const deferred = this._connectDeferred;
    this._connectDeferred = null;
    deferred?.reject(error);
  }

  _resolveConnect() {
    const deferred = this._connectDeferred;
    this._connectDeferred = null;
    deferred?.resolve(this);
  }

  _clearAllTimers() {
    this._clearTimer('_handshakeTimer');
    this._clearTimer('_pingTimer');
    this._clearTimer('_watchTimer');
    this._clearTimer('_recoveryTimer');
  }

  _clearTimer(owner, key) {
    const holder = typeof owner === 'string' ? this : owner;
    const field = typeof owner === 'string' ? owner : key;
    if (holder?.[field]) {
      clearTimeout(holder[field]);
      clearInterval(holder[field]);
      holder[field] = null;
    }
  }

  // ------------------------------------------------------------------
  // Serialized queue
  // ------------------------------------------------------------------

  _isControlLike(entry) {
    return entry.kind !== 'midi' && entry.kind !== 'config';
  }

  _enqueueControl(entry) {
    let index = 0;
    while (index < this.queue.length && this._isControlLike(this.queue[index])) index++;
    this.queue.splice(index, 0, entry);
    this._kick();
  }

  _kick() {
    if (this.pumping || this.closing || this.failed || !this.writer) return;
    this.pumping = true;
    this.pumpTask = (async () => {
      let activeEntry = null;
      try {
        while (!this.closing && !this.failed && this.writer && this.queue.length > 0) {
          const entry = this.queue.shift();
          this._current = entry;
          activeEntry = entry;
          await this._dispatch(entry);
          if (this._current === entry) this._current = null;
          activeEntry = null;
        }
      } catch (error) {
        // Keep activeEntry until here: clearing _current in an inner finally
        // would hide the failed MIDI batch from this rejection path.
        const current = activeEntry ?? this._current;
        this._current = null;
        if (current?.kind === 'midi') this._rejectMidiEntry(current, error);
        else if (current?.reject) this._rejectEntry(current, error);
        this._fault(error);
      } finally {
        this.pumping = false;
        if (!this.closing && !this.failed && this.queue.length > 0) this._kick();
      }
    })();
  }

  async _dispatch(entry) {
    if (entry.cancelled) {
      if (entry.kind === 'midi') this._rejectMidiEntry(entry, cancelled());
      return;
    }
    if (entry.kind === 'midi') return this._dispatchMidi(entry);
    if (entry.kind === 'config' || entry.kind === 'config-retry') {
      const config = entry.config;
      if (!config || config.settled) return;
      await this._write(entry.frame ?? config.frame);
      if (config.settled) return;
      config.written = true;
      this._startConfigTimer(config);
      return;
    }
    if (entry.kind === 'status') {
      await this._write(entry.frame);
      if (!entry.settled) this._startStatusTimer(entry);
      return;
    }
    if (entry.kind === 'raw') {
      await this._write(entry.wire);
      if (!entry.settled) {
        entry.settled = true;
        this.onLog('测试', '坏 CRC CONFIG 已写入；不参与正常配置结果');
        entry.resolve?.(entry.result);
      }
      return;
    }
    // Plain control, and PING which is built only now.
    const frame = typeof entry.prepare === 'function' ? entry.prepare() : entry.frame;
    if (!frame) return;
    await this._write(frame);
  }

  async _dispatchMidi(entry) {
    const batch = entry.batch;
    if (!batch || batch.settled) return;
    if (batch.epoch !== this.client.epoch || !this.client.active) {
      this._failMidiBatch(entry, cancelled('MIDI epoch 已失效'));
      return;
    }
    const waitedMs = this.now() - entry.queuedAt;
    if (Number.isFinite(this.options.queueTimeoutMs) && waitedMs > this.options.queueTimeoutMs) {
      const error = Error(`串口队列延迟超过 ${this.options.queueTimeoutMs}ms，已停止播放`);
      this._failMidiBatch(entry, error);
      this._fault(error);
      return;
    }
    let frames;
    try {
      // Allocate the MIDI sequence only immediately before writer.write().
      frames = this.client.midi(entry.messages);
    } catch (error) {
      this._failMidiBatch(entry, error);
      return;
    }
    for (const wire of frames) {
      if (this.closing || this.failed || entry.cancelled || batch.settled) {
        this._failMidiBatch(entry, cancelled());
        return;
      }
      await this._write(wire);
    }
    if (!batch.settled && --batch.remaining === 0) {
      batch.settled = true;
      batch.resolve?.();
    }
  }

  async _write(wire) {
    if (!this.writer) throw Error('串口写入器已释放');
    // A resolving write means browser acceptance, not FPGA application.
    await this.writer.write(wire);
    this.txBytes += wire.length;
    this.txFrames++;
    this._notify();
    const perByte = this.options.pacing
      ? this.options.pacingMsPerByte ?? 10000 / this.baud
      : 0;
    if (perByte > 0) await sleep(wire.length * perByte);
  }

  _rejectEntry(entry, error) {
    if (!entry || entry.settled) return;
    entry.settled = true;
    entry.cancelled = true;
    entry.reject?.(error);
  }

  _pendingMidiGroups() {
    let count = 0;
    for (const entry of this.queue) if (entry.kind === 'midi') count++;
    if (this._current?.kind === 'midi') count++;
    return count;
  }

  _rejectMidiBatch(batch, error) {
    if (!batch || batch.settled) return;
    batch.settled = true;
    batch.reject?.(error);
  }

  _rejectMidiEntry(entry, error) {
    if (!entry) return;
    entry.cancelled = true;
    this._rejectMidiBatch(entry.batch, error);
  }

  _removeMidiBatch(batch) {
    this.queue = this.queue.filter((entry) => entry.kind !== 'midi' || entry.batch !== batch);
  }

  _failMidiBatch(entry, error) {
    entry.cancelled = true;
    this._rejectMidiBatch(entry.batch, error);
    this._removeMidiBatch(entry.batch);
  }

  _clearUnsentMidi(error) {
    const kept = [];
    for (const entry of this.queue) {
      if (entry.kind === 'midi') {
        this._rejectMidiEntry(entry, error);
      } else {
        kept.push(entry);
      }
    }
    this.queue = kept;
    // An in-flight write is preserved, but its not-yet-written groups are not.
    if (this._current?.kind === 'midi') {
      this._rejectMidiEntry(this._current, error);
    }
  }

  _rejectQueue(error) {
    const entries = this.queue.splice(0);
    for (const entry of entries) {
      entry.cancelled = true;
      if (entry.kind === 'midi') this._rejectMidiEntry(entry, error);
      else if (entry.reject) this._rejectEntry(entry, error);
    }
    if (this._current) {
      this._current.cancelled = true;
      if (this._current.kind === 'midi') this._rejectMidiEntry(this._current, error);
      else if (this._current.reject) this._rejectEntry(this._current, error);
    }
  }

  _notify() {
    try {
      this.onState();
    } catch {
      // A UI callback must not corrupt the transport state machine.
    }
  }
}

export default V2SerialLink;
