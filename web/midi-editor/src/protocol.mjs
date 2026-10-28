// Wire contract: rtl/drivers/analyzer/PROTOCOL_V1.md. No bare MIDI or SMF bytes.
export function crc16(bytes) {
  let crc=0xffff;
  for(const byte of bytes) {crc ^= byte<<8; for(let i=0;i<8;i++) crc=((crc<<1)^((crc&0x8000)?0x1021:0))&0xffff;}
  return crc;
}
export function encodeFrame(type,seq,payload) {
  const limit={1:32,2:16,128:3}[type];
  if(!limit || !payload.length || payload.length>limit || (type===128 && payload.length!==3)) throw Error('非法协议 payload 长度/类型');
  if(!Number.isInteger(seq)||seq<0||seq>65535 || [...payload].some(b=>!Number.isInteger(b)||b<0||b>255)) throw Error('非法协议字段');
  const body=[1,type,seq&255,seq>>8,payload.length,0,...payload];
  const crc=crc16(body); body.push(crc&255,crc>>8);
  const wire=[0xc0];
  for(const b of body) wire.push(...(b===0xc0?[0xdb,0xdc]:b===0xdb?[0xdb,0xdd]:[b]));
  return Uint8Array.from([...wire,0xc0]);
}
export function decodeBody(body) {
  if(body.length<9||body.length>40) throw Error('帧长错误');
  const type=body[1],len=body[4]|body[5]<<8;
  if(body[0]!==1 || !({1:32,2:16,128:3}[type]) || len<1 || len>({1:32,2:16,128:3}[type]) || body.length!==len+8 || (type===128 && len!==3)) throw Error('帧头错误');
  if(crc16(body.slice(0,-2))!==(body.at(-2)|(body.at(-1)<<8))) throw Error('CRC 错误');
  return {type,seq:body[2]|body[3]<<8,payload:Uint8Array.from(body.slice(6,-2))};
}
export class FrameReader {
  constructor(onFrame=()=>{},onError=()=>{}) {Object.assign(this,{onFrame,onError,started:false,escape:false,bad:false,body:[]});}
  feed(bytes) {
    for(const byte of bytes) {
      if(byte===0xc0) {
        if(this.started && (this.body.length||this.bad||this.escape)) {
          try {if(this.bad||this.escape) throw Error('SLIP 转义或长度错误'); this.onFrame(decodeBody(this.body));} catch(e) {this.onError(e);}
        }
        this.started=true; this.escape=this.bad=false; this.body=[];
      } else if(this.started && !this.bad) {
        if(this.escape) {if(byte!==0xdc && byte!==0xdd) this.bad=true; else this.body.push(byte===0xdc?0xc0:0xdb); this.escape=false;}
        else if(byte===0xdb) this.escape=true;
        else this.body.push(byte);
        if(this.body.length>40) this.bad=true;
      }
    }
  }
}
export function packMidi(messages) {
  const packets=[]; let bytes=[];
  for(const message of messages) {
    const status=message[0],kind=status&0xf0,expected=(kind===0xc0||kind===0xd0)?2:3;
    if(status<0x80||status>=0xf0||message.length!==expected||message.slice(1).some(b=>!Number.isInteger(b)||b<0||b>127)) throw Error('MIDI 短消息必须完整并带 status');
    if(bytes.length+message.length>32) {packets.push(bytes);bytes=[];}
    bytes.push(...message);
  }
  if(bytes.length) packets.push(bytes);
  return packets;
}
