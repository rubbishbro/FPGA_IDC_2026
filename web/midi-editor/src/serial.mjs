import {encodeFrame,FrameReader,packMidi} from './protocol.mjs';
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const cancelled=()=>Object.assign(Error('发送已取消'),{name:'AbortError'});
// One bounded TX queue; no MIDI retry. At most the current frame survives cancel().
export class SerialLink {
  constructor(onState=()=>{},onLog=()=>{},serialApi=globalThis.navigator?.serial) {
    this.serialApi=serialApi;
    Object.assign(this,{onState,onLog,port:null,writer:null,reader:null,queue:[],pumping:false,epoch:0,seq:0,txBytes:0,txFrames:0,rxFrames:0,baud:115200,closing:false,failed:false});
    this.decoder=new FrameReader(frame=>{this.rxFrames++;this.onLog('RX',`type ${frame.type.toString(16)} · seq ${frame.seq}`);this.onState();},e=>this.onLog('RX 错误',e.message));
    this.serialApi?.addEventListener('disconnect',e=>{if(e.target===this.port||e.port===this.port){this.failed=true;this.cancel();this.onLog('断线','串口已断开；板端清音状态未知');this.onFault?.(Error('串口已断开'));this.disconnect().catch(()=>{});}});
  }
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
    } catch(e){if(!this.closing){this.failed=true;this.cancel();this.onLog('串口错误',e.message);this.onFault?.(e);}}
    finally{this.reader?.releaseLock();this.reader=null;this.onState();}
  }
  send(messages) {
    if(!this.connected)return Promise.reject(Error('串口未连接'));
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
        if(entry.epoch!==this.epoch){entry.reject(cancelled());continue;}
        if(performance.now()-entry.queued>200){entry.reject(Error('串口队列延迟超过 200ms'));this.cancel();this.onFault?.(Error('UART 吞吐不足，已停止播放'));break;}
        try {
          // A write resolving only means browser acceptance, not FPGA application.
          await this.writer.write(entry.wire);this.txBytes+=entry.wire.length;this.txFrames++;
          await sleep(entry.wire.length*10000/this.baud);
          entry.resolve();this.onState();
        } catch(e) {entry.reject(e);this.failed=true;this.cancel();this.onFault?.(e);break;}
      }
    } finally {this.pumping=false;this.onState();}
  }
  cancel(){this.epoch++;for(const q of this.queue.splice(0))q.reject(cancelled());}
  async panic(channels=Array.from({length:16},(_,i)=>i)) {
    this.cancel();
    if(this.connected)await this.send(channels.flatMap(ch=>[[0xb0|ch,64,0],[0xb0|ch,120,0]]));
    this.onLog('清音请求','CC64=0 + CC120 已写入串口；v1 无 MIDI 生效确认');
  }
  async disconnect() {
    if(this.closing)return;this.closing=true;this.cancel();
    try {
      await this.reader?.cancel();await this.readTask;await this.pumpTask;
      // Do not close a writable stream before the current write has retired.
      if(this.writer){await this.writer.ready;this.writer.releaseLock();this.writer=null;}
      await this.port?.close();
    } finally {this.port=null;this.writer=null;this.closing=false;this.onState();}
  }
}
