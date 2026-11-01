import {encodeFrame,FrameReader,packMidi} from './protocol.mjs';
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const cancelled=()=>Object.assign(Error('发送已取消'),{name:'AbortError'});
// One bounded TX queue; no MIDI retry. At most the current frame survives cancel().
export class SerialLink {
  constructor(onState=()=>{},onLog=()=>{},serialApi=globalThis.navigator?.serial) {
    this.serialApi=serialApi;
    Object.assign(this,{onState,onLog,port:null,writer:null,reader:null,queue:[],pumping:false,epoch:0,seq:0,txBytes:0,txFrames:0,rxFrames:0,baud:115200,closing:false,failed:false});
    this.cfgSeq=0;this.pendingConfig=null;
    this.decoder=new FrameReader(frame=>this.handleFrame(frame),e=>this.onLog('RX 错误',e.message));
    this.serialApi?.addEventListener('disconnect',e=>{if(e.target===this.port||e.port===this.port){this.failed=true;this.failConfig(Error('串口已断开'));this.cancel();this.onLog('断线','串口已断开；板端清音状态未知');this.onFault?.(Error('串口已断开'));this.disconnect().catch(()=>{});}});
  }
  handleFrame(frame) {
    this.rxFrames++;
    if(frame.type===128 && this.pendingConfig && frame.seq===this.pendingConfig.seq && frame.payload[0]===2 && frame.payload[1]===this.pendingConfig.command){
      const pending=this.pendingConfig;this.pendingConfig=null;clearTimeout(pending.timer);
      if(frame.payload[2]===0)pending.resolve(frame);else pending.reject(Error(`设备配置失败：${['OK','UNSUPPORTED','BAD_LENGTH','OUT_OF_RANGE','BUSY','SEQ_CONFLICT','NOT_READY'][frame.payload[2]]??frame.payload[2]}`));
    }
    if(frame.type!==130){this.onLog('RX',`type ${frame.type.toString(16)} · seq ${frame.seq}`);this.onState();}
    this.onFrame?.(frame);
  }
  configure(command,data=[],{timeoutMs=2500}={}) {
    if(!this.connected)return Promise.reject(Error('串口未连接'));
    if(this.pendingConfig)return Promise.reject(Error('已有配置请求在途'));
    const seq=this.cfgSeq;this.cfgSeq=(seq+1)&65535;
    return new Promise((resolve,reject)=>{
      const fail=error=>{if(this.pendingConfig?.seq===seq){clearTimeout(this.pendingConfig.timer);this.pendingConfig=null;reject(error);}};
      const timer=setTimeout(()=>fail(Error('配置回复超时，设备结果未知')),timeoutMs);
      this.pendingConfig={seq,command,resolve,reject,timer};
      try {
        this.queue.push({wire:encodeFrame(2,seq,[command,...data]),epoch:this.epoch,control:true,queued:performance.now(),resolve:()=>{},reject:fail});
        if(!this.pumping)this.pumpTask=this.pump();
      }catch(e){fail(e);}
    });
  }
  failConfig(error){if(this.pendingConfig){clearTimeout(this.pendingConfig.timer);this.pendingConfig.reject(error);this.pendingConfig=null;}}
  get connected(){return !!this.writer&&!this.closing&&!this.failed;}
  async connect(baud) {
    if(!this.serialApi)throw Error('此浏览器没有 Web Serial，请在 Chrome / Edge 打开 localhost');
    if(this.port)throw Error('串口已打开或正在关闭');
    const port=await this.serialApi.requestPort();
    try {await port.open({baudRate:baud,dataBits:8,stopBits:1,parity:'none',flowControl:'none',bufferSize:4096});}
    catch(e){throw Error(`打开串口失败：${e.message}`);}
    this.port=port;this.baud=baud;this.closing=false;this.failed=false;this.seq=0;this.decoder=new FrameReader(this.decoder.onFrame,this.decoder.onError);
    this.writer=port.writable.getWriter();this.readTask=this.readLoop();this.onLog('连接',`${baud} baud · 8N1 · v1 SLIP/CRC`);this.onState();
  }
  async readLoop() {
    try {
      this.reader=this.port.readable.getReader();
      while(!this.closing) {const {value,done}=await this.reader.read();if(done)break;this.decoder.feed(value);}
      if(!this.closing)throw Error('串口接收流结束');
    } catch(e){if(!this.closing){this.failed=true;this.failConfig(Error('串口已断开'));this.cancel();this.onLog('串口错误',e.message);this.onFault?.(e);}}
    finally{this.reader?.releaseLock();this.reader=null;this.onState();}
  }
  send(messages) {
    if(!this.connected)return Promise.reject(Error('串口未连接'));
    if(this.pendingConfig)return Promise.reject(Error('配置在途，请等待完成后演奏'));
    const packets=packMidi(messages);
    if(this.queue.length+packets.length>64) {const error=Error('串口发送积压，已停止播放');this.onFault?.(error);return Promise.reject(error);}
    return Promise.all(packets.map(payload=>new Promise((resolve,reject)=>{
      this.queue.push({wire:encodeFrame(1,this.seq,payload),epoch:this.epoch,queued:performance.now(),resolve,reject});this.seq=(this.seq+1)&65535;
      if(!this.pumping)this.pumpTask=this.pump();
    })));
  }
  async pump() {
    if(this.pumping)return;this.pumping=true;
    try {
      while(this.queue.length && this.writer && !this.failed) {
        const entry=this.queue.shift();
        if(!entry.control && entry.epoch!==this.epoch){entry.reject(cancelled());continue;}
        if(performance.now()-entry.queued>200){entry.reject(Error('串口队列延迟超过 200ms'));this.cancel();this.onFault?.(Error('UART 吞吐不足，已停止播放'));break;}
        try {
          // A write resolving only means browser acceptance, not FPGA application.
          await this.writer.write(entry.wire);this.txBytes+=entry.wire.length;this.txFrames++;
          await sleep(entry.wire.length*10000/this.baud);
          entry.resolve();this.onState();
        } catch(e) {entry.reject(e);this.failed=true;this.failConfig(Error('串口已断开'));this.cancel();this.onFault?.(e);break;}
      }
    } finally {this.pumping=false;this.onState();}
  }
  cancel(){this.epoch++;const keep=[];for(const q of this.queue.splice(0)){if(q.control)keep.push(q);else q.reject(cancelled());}this.queue=keep;}
  async panic(channels=Array.from({length:16},(_,i)=>i)) {
    this.cancel();
    if(this.connected)await this.send(channels.flatMap(ch=>[[0xb0|ch,64,0],[0xb0|ch,120,0]]));
    this.onLog('清音请求','CC64=0 + CC120 已写入串口；v1 无 MIDI 生效确认');
  }
  async disconnect() {
    if(this.closing)return;this.closing=true;this.failConfig(Error('串口已关闭'));this.cancel();for(const q of this.queue.splice(0))q.reject(cancelled());
    try {
      await this.reader?.cancel();await this.readTask;await this.pumpTask;
      // Do not close a writable stream before the current write has retired.
      if(this.writer){await this.writer.ready;this.writer.releaseLock();this.writer=null;}
      await this.port?.close();
    } finally {this.port=null;this.writer=null;this.closing=false;this.onState();}
  }
}
