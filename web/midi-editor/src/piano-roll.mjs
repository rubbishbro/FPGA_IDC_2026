import {clamp,noteName,uid} from './model.mjs';
const black=n=>[1,3,6,8,10].includes((n%12+12)%12);
const rgba=(hex,a=1)=>[...hex.slice(1).match(/../g).map(v=>parseInt(v,16)/255),a];
export class PianoRoll {
  constructor(canvas,overlay,options) {
    Object.assign(this,{canvas,overlay,...options,beatWidth:72,rowHeight:19,topPitch:78,leftBeat:0,keyboard:66,ruler:32,velocityHeight:108,selection:new Set(),tool:'draw',snap:.25,noteLength:.5,cursor:0,dirty:true});
    this.ctx=overlay.getContext('2d');
    this.initGL();
    canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();this.gl=null;this.onStatus?.('WebGL 上下文丢失，正在等待恢复');});
    canvas.addEventListener('webglcontextrestored',()=>{this.initGL();this.invalidate();});
    new ResizeObserver(()=>this.invalidate()).observe(canvas.parentElement);
    overlay.addEventListener('pointerdown',e=>this.down(e));overlay.addEventListener('pointermove',e=>this.move(e));overlay.addEventListener('pointerup',e=>this.up(e));overlay.addEventListener('pointercancel',()=>{this.drag=null;this.draft=null;this.invalidate();});
    overlay.addEventListener('contextmenu',e=>e.preventDefault());
    overlay.addEventListener('wheel',e=>this.wheel(e),{passive:false});
    const frame=()=>{if(this.dirty){this.render();this.dirty=false;}requestAnimationFrame(frame);};requestAnimationFrame(frame);
  }
  initGL() {
    const gl=this.canvas.getContext('webgl',{alpha:false,antialias:false,preserveDrawingBuffer:false});
    if(!gl){this.onStatus?.('WebGL 不可用，使用 Canvas 兼容渲染');this.gl=null;return;}
    this.gl=gl;
    const shader=(type,source)=>{const s=gl.createShader(type);gl.shaderSource(s,source);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s));return s;};
    const program=gl.createProgram();
    gl.attachShader(program,shader(gl.VERTEX_SHADER,'attribute vec2 a_position; attribute vec4 a_color; uniform vec2 u_size; varying vec4 v_color; void main(){vec2 p=a_position/u_size;gl_Position=vec4(p.x*2.0-1.0,1.0-p.y*2.0,0,1);v_color=a_color;}'));
    gl.attachShader(program,shader(gl.FRAGMENT_SHADER,'precision mediump float; varying vec4 v_color; void main(){gl_FragColor=v_color;}'));
    gl.linkProgram(program);if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(program));
    this.program=program;this.buffer=gl.createBuffer();this.positionLoc=gl.getAttribLocation(program,'a_position');this.colorLoc=gl.getAttribLocation(program,'a_color');this.sizeLoc=gl.getUniformLocation(program,'u_size');
  }
  invalidate(){this.dirty=true;}
  project(){return this.draft??this.getProject();}
  activeTrack(){return this.project().tracks.find(t=>t.id===this.getTrack());}
  gridBottom(){return this.height-this.velocityHeight;}
  x(beat){return this.keyboard+(beat-this.leftBeat)*this.beatWidth;}
  y(pitch){return this.ruler+(this.topPitch-pitch)*this.rowHeight;}
  beat(x){return clamp((x-this.keyboard)/this.beatWidth+this.leftBeat,0,39999.75);}
  pitch(y){return clamp(this.topPitch-Math.floor((y-this.ruler)/this.rowHeight),0,127);}
  quantize(v){return Math.round(v/this.snap)*this.snap;}
  point(e){const r=this.overlay.getBoundingClientRect();return {x:e.clientX-r.left,y:e.clientY-r.top};}
  hit(x,y){return this.activeTrack()?.notes.findLast(n=>x>=this.x(n.beat)&&x<=this.x(n.beat+n.duration)&&y>=this.y(n.pitch)&&y<this.y(n.pitch)+this.rowHeight);}
  selected(){return this.activeTrack()?.notes.filter(n=>this.selection.has(n.id))??[];}
  select(ids){this.selection=new Set(ids);this.onSelection?.();this.invalidate();}
  down(e) {
    if(e.button!==0&&e.button!==2)return;
    this.overlay.focus();const p=this.point(e);this.overlay.setPointerCapture(e.pointerId);
    if(p.x<this.keyboard) {
      if(p.y>this.ruler&&p.y<this.gridBottom()){this.audition?.(this.pitch(p.y));this.onStatus?.(`${noteName(this.pitch(p.y))} · MIDI ${this.pitch(p.y)}`);}return;
    }
    if(p.y<this.ruler){this.onSeek?.(this.quantize(this.beat(p.x)));return;}
    if(p.y>=this.gridBottom()) {
      const n=this.activeTrack().notes.findLast(n=>Math.abs(this.x(n.beat)-p.x)<8);
      if(!n)return;if(!this.selection.has(n.id))this.select([n.id]);this.beforeEdit?.();this.draft=structuredClone(this.getProject());this.drag={type:'velocity',start:p};this.move(e);return;
    }
    const hit=this.hit(p.x,p.y);
    if(this.tool==='erase'||e.button===2) {
      if(hit){this.beforeEdit?.();const next=structuredClone(this.getProject());next.tracks.find(t=>t.id===this.getTrack()).notes=next.tracks.find(t=>t.id===this.getTrack()).notes.filter(n=>n.id!==hit.id);this.selection.delete(hit.id);this.onCommit(next);}return;
    }
    if(hit) {
      if(e.shiftKey){const ids=new Set(this.selection);if(ids.has(hit.id))ids.delete(hit.id);else ids.add(hit.id);this.select(ids);if(!ids.has(hit.id))return;}
      else if(!this.selection.has(hit.id))this.select([hit.id]);
      this.beforeEdit?.();this.draft=structuredClone(this.getProject());
      if(e.altKey){const copies=this.selected().map(n=>({...n,id:uid()}));this.activeTrack().notes.push(...copies);this.select(copies.map(n=>n.id));}
      this.drag={type:p.x>this.x(hit.beat+hit.duration)-7?'resize':'move',start:p,base:structuredClone(this.selected())};
    } else if(this.tool==='draw') {
      this.beforeEdit?.();this.draft=structuredClone(this.getProject());
      const note={id:uid(),pitch:this.pitch(p.y),beat:Math.floor(this.beat(p.x)/this.snap)*this.snap,duration:this.noteLength,velocity:96};
      this.activeTrack().notes.push(note);this.select([note.id]);this.drag={type:'draw',start:p,note};
    } else {this.drag={type:'marquee',start:p,end:p,previous:e.shiftKey?[...this.selection]:[]};if(!e.shiftKey)this.select([]);}
    this.invalidate();
  }
  move(e) {
    const p=this.point(e);const hover=this.hit(p.x,p.y);
    this.overlay.style.cursor=this.drag?'grabbing':p.y<this.ruler?'pointer':hover?(p.x>this.x(hover.beat+hover.duration)-7?'ew-resize':'grab'):this.tool==='draw'?'crosshair':this.tool==='erase'?'not-allowed':'default';
    if(!this.drag)return;const d=this.drag;
    if(d.type==='marquee') {
      d.end=p;const x1=Math.min(d.start.x,p.x),x2=Math.max(d.start.x,p.x),y1=Math.min(d.start.y,p.y),y2=Math.max(d.start.y,p.y);
      this.select([...d.previous,...this.activeTrack().notes.filter(n=>this.x(n.beat)<x2&&this.x(n.beat+n.duration)>x1&&this.y(n.pitch)<y2&&this.y(n.pitch)+this.rowHeight>y1).map(n=>n.id)]);
    } else if(d.type==='velocity') {
      const v=clamp(Math.round((this.height-15-p.y)/(this.velocityHeight-35)*127),1,127);for(const n of this.selected())n.velocity=v;
    } else if(d.type==='draw') {
      const n=this.activeTrack().notes.find(n=>n.id===d.note.id);n.duration=Math.min(40000-n.beat,Math.max(this.snap,this.quantize(this.beat(p.x)-n.beat+this.snap)));
    } else {
      const db=this.quantize((p.x-d.start.x)/this.beatWidth),dp=-Math.round((p.y-d.start.y)/this.rowHeight);
      const base=d.base,shiftBeat=clamp(db,-Math.min(...base.map(n=>n.beat)),40000-Math.max(...base.map(n=>n.beat+n.duration))),shiftPitch=clamp(dp,-Math.min(...base.map(n=>n.pitch)),127-Math.max(...base.map(n=>n.pitch)));
      for(const n of this.selected()) {const b=base.find(b=>b.id===n.id);if(d.type==='move'){n.beat=b.beat+shiftBeat;n.pitch=b.pitch+shiftPitch;}else n.duration=Math.min(40000-n.beat,Math.max(this.snap,b.duration+db));}
    }
    this.onSelection?.();this.invalidate();
  }
  up() {
    if(!this.drag)return;
    if(this.draft){const p=this.draft;p.bars=Math.max(p.bars,Math.ceil(Math.max(...this.activeTrack().notes.map(n=>n.beat+n.duration),4)/4));this.draft=null;this.onCommit(p);}
    this.drag=null;this.onSelection?.();this.invalidate();
  }
  wheel(e) {
    e.preventDefault();
    if(e.ctrlKey||e.metaKey){const p=this.point(e),beat=this.beat(p.x);this.beatWidth=clamp(this.beatWidth*Math.exp(-e.deltaY*.003),24,240);this.leftBeat=Math.max(0,beat-(p.x-this.keyboard)/this.beatWidth);this.onZoom?.(this.beatWidth);}
    else if(e.shiftKey||Math.abs(e.deltaX)>Math.abs(e.deltaY)) this.leftBeat=Math.max(0,this.leftBeat+(e.deltaX||e.deltaY)/this.beatWidth);
    else this.topPitch=clamp(this.topPitch+Math.sign(e.deltaY)*-2,Math.ceil((this.gridBottom()-this.ruler)/this.rowHeight)-1,127);
    this.invalidate();
  }
  fit() {
    const notes=this.activeTrack().notes;if(!notes.length){this.topPitch=78;this.leftBeat=0;return this.invalidate();}
    const min=Math.min(...notes.map(n=>n.pitch)),max=Math.max(...notes.map(n=>n.pitch));
    this.rowHeight=clamp(Math.floor((this.gridBottom()-this.ruler)/(max-min+5)),7,23);this.topPitch=Math.min(127,max+2);this.leftBeat=0;
    const end=Math.max(16,...notes.map(n=>n.beat+n.duration));this.beatWidth=clamp((this.width-this.keyboard-24)/end,24,160);this.onZoom?.(this.beatWidth);this.invalidate();
  }
  render() {
    const rect=this.canvas.parentElement.getBoundingClientRect();this.width=rect.width;this.height=rect.height;
    const dpr=Math.min(devicePixelRatio,2);for(const canvas of [this.canvas,this.overlay]){if(canvas.width!==Math.round(this.width*dpr)||canvas.height!==Math.round(this.height*dpr)){canvas.width=Math.round(this.width*dpr);canvas.height=Math.round(this.height*dpr);}}
    const ctx=this.ctx;ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,this.width,this.height);ctx.font='10px ui-monospace, monospace';
    const vertices=[],rects=[];
    const box=(x,y,w,h,color)=>{if(w<=0||h<=0)return;const c=Array.isArray(color)?color:rgba(color);rects.push([x,y,w,h,c]);if(this.gl)for(const [px,py] of [[x,y],[x+w,y],[x,y+h],[x,y+h],[x+w,y],[x+w,y+h]])vertices.push(px,py,...c);};
    box(0,0,this.width,this.height,'#171b20');const bottom=this.gridBottom();
    for(let pitch=this.topPitch;this.y(pitch)<bottom&&pitch>=0;pitch--) {
      const y=this.y(pitch),height=Math.min(this.rowHeight,bottom-y);
      box(this.keyboard,y,this.width-this.keyboard,height,black(pitch)?'#191e24':'#1d232a');box(this.keyboard,y+height-1,this.width-this.keyboard,1,'#272e36');
      box(0,y,this.keyboard-1,height,black(pitch)?'#20262d':'#c3c8c9');box(0,y+height-1,this.keyboard-1,1,black(pitch)?'#12171d':'#939a9d');
      if(pitch%12===0||this.rowHeight>17){ctx.fillStyle=black(pitch)?'#828d99':'#485360';ctx.textAlign='right';ctx.fillText(noteName(pitch),this.keyboard-9,y+height*.68);}
    }
    const p=this.project();
    const step=this.beatWidth*this.snap>9?this.snap:1;
    for(let beat=Math.floor(this.leftBeat/step)*step;this.x(beat)<this.width;beat+=step) {
      const x=this.x(beat);if(x<this.keyboard)continue;
      box(x,this.ruler,1,bottom-this.ruler,beat%4===0?'#48505a':Number.isInteger(beat)?'#343d47':'#282f38');
      if(Number.isInteger(beat)&&beat%4===0){ctx.fillStyle='#b4bdc8';ctx.textAlign='left';ctx.fillText(String(beat/4+1).padStart(2,'0'),x+7,21);}
      else if(Number.isInteger(beat)&&this.beatWidth>56){ctx.fillStyle='#596673';ctx.textAlign='left';ctx.fillText(String(beat%4+1),x+5,21);}
    }
    if(p.loop.enabled){const x=Math.max(this.keyboard,this.x(p.loop.start)),end=Math.min(this.width,this.x(p.loop.end));if(end>x){box(x,0,end-x,3,'#f2b86b');box(x,this.ruler,end-x,bottom-this.ruler,[.95,.72,.42,.025]);}for(const beat of [p.loop.start,p.loop.end])if(this.x(beat)>this.keyboard)box(this.x(beat),3,1,26,'#8d7353');}
    box(this.keyboard,bottom,this.width-this.keyboard,this.velocityHeight,'#171d23');box(0,bottom,this.width,1,'#46505a');
    ctx.fillStyle='#788593';ctx.textAlign='left';ctx.fillText('VELOCITY',10,bottom+24);ctx.fillText('127',this.keyboard+8,bottom+20);ctx.fillText('0',this.keyboard+8,this.height-12);
    for(const t of p.tracks.filter(t=>t.id!==this.getTrack()).concat(p.tracks.filter(t=>t.id===this.getTrack()))) {
      const active=t.id===this.getTrack();
      for(const n of t.notes) {
        let x=this.x(n.beat),right=this.x(n.beat+n.duration),y=this.y(n.pitch);
        if(right<this.keyboard||x>this.width)continue;
        const selected=active&&this.selection.has(n.id),color=rgba(t.color,active?(t.muted ? .35 : .88):.14);
        const left=Math.max(this.keyboard,x+1),w=Math.min(this.width,right-1)-left;
        if(y>=this.ruler&&y+this.rowHeight<=bottom&&w>0) {
          if(selected)box(left-1,y+1,w+2,this.rowHeight-1,'#fff0d5');
          box(left,y+2,w,this.rowHeight-3,color);
          if(active&&w>26&&this.rowHeight>14){ctx.save();ctx.beginPath();ctx.rect(left,y,w,this.rowHeight);ctx.clip();ctx.fillStyle=selected?'#342c22':'#322f29';ctx.textAlign='left';ctx.fillText(noteName(n.pitch),left+5,y+this.rowHeight*.73);ctx.restore();}
          if(active&&w>15)box(right-5,y+5,1,this.rowHeight-9,[.1,.1,.1,.3]);
        }
        if(active&&x>=this.keyboard){const height=n.velocity/127*(this.velocityHeight-35);box(x,this.height-15-height,Math.max(3,Math.min(7,w)),height,rgba(t.color,selected?1:.5));}
      }
    }
    if(this.drag?.type==='marquee'){const {start,end}=this.drag;box(Math.min(start.x,end.x),Math.min(start.y,end.y),Math.abs(start.x-end.x),Math.abs(start.y-end.y),[.7,.8,.9,.18]);}
    if(this.cursor>=this.leftBeat&&this.x(this.cursor)<this.width) {box(this.x(this.cursor),0,1.5,this.height,'#f3e6cb');box(this.x(this.cursor)-3,4,7,7,'#f3e6cb');}
    if(this.gl) {
      const gl=this.gl;gl.viewport(0,0,this.canvas.width,this.canvas.height);gl.clearColor(.09,.1,.12,1);gl.clear(gl.COLOR_BUFFER_BIT);gl.useProgram(this.program);gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);
      gl.bindBuffer(gl.ARRAY_BUFFER,this.buffer);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(vertices),gl.DYNAMIC_DRAW);gl.enableVertexAttribArray(this.positionLoc);gl.vertexAttribPointer(this.positionLoc,2,gl.FLOAT,false,24,0);gl.enableVertexAttribArray(this.colorLoc);gl.vertexAttribPointer(this.colorLoc,4,gl.FLOAT,false,24,8);gl.uniform2f(this.sizeLoc,this.width,this.height);gl.drawArrays(gl.TRIANGLES,0,vertices.length/6);
    } else {
      // Draw fallback geometry behind the label layer without hiding its text.
      ctx.globalCompositeOperation='destination-over';for(const [x,y,w,h,c] of rects.toReversed()){ctx.fillStyle=`rgba(${c[0]*255},${c[1]*255},${c[2]*255},${c[3]})`;ctx.fillRect(x,y,w,h);}ctx.globalCompositeOperation='source-over';
    }
    this.onRender?.({backend:this.gl?'WebGL':'Canvas 2D',notes:p.tracks.reduce((sum,t)=>sum+t.notes.length,0)});
  }
}
