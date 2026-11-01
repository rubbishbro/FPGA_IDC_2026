import {clamp,noteName,uid} from './model.mjs';
const black=n=>[1,3,6,8,10].includes((n%12+12)%12);
const rgba=(hex,a=1)=>[...hex.slice(1).match(/../g).map(v=>parseInt(v,16)/255),a];
export class PianoRoll {
  constructor(canvas,overlay,options) {
    Object.assign(this,{canvas,overlay,...options,beatWidth:72,rowHeight:19,topPitch:78,leftBeat:0,keyboard:74,ruler:36,velocityHeight:120,selection:new Set(),hoverId:null,tool:'draw',snap:.25,noteLength:.5,cursor:0,dirty:true});
    this.ctx=overlay.getContext('2d');
    this.initGL();
    canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();this.gl=null;this.onStatus?.('WebGL 上下文丢失，正在等待恢复');});
    canvas.addEventListener('webglcontextrestored',()=>{this.initGL();this.invalidate();});
    new ResizeObserver(()=>this.invalidate()).observe(canvas.parentElement);
    overlay.addEventListener('pointerdown',e=>this.down(e));overlay.addEventListener('pointermove',e=>this.move(e));overlay.addEventListener('pointerup',e=>this.up(e));overlay.addEventListener('pointercancel',()=>{this.drag=null;this.draft=null;this.invalidate();});
    overlay.addEventListener('pointerleave',()=>{if(this.hoverId){this.hoverId=null;this.invalidate();}});
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
    const hoverId=this.drag?null:hover?.id??null;if(this.hoverId!==hoverId){this.hoverId=hoverId;this.invalidate();}
    this.overlay.style.cursor=this.drag?'grabbing':p.y<this.ruler?'pointer':hover?(p.x>this.x(hover.beat+hover.duration)-7?'ew-resize':'grab'):this.tool==='draw'?'crosshair':this.tool==='erase'?'not-allowed':'default';
    if(!this.drag)return;const d=this.drag;
    if(d.type==='marquee') {
      d.end=p;const x1=Math.min(d.start.x,p.x),x2=Math.max(d.start.x,p.x),y1=Math.min(d.start.y,p.y),y2=Math.max(d.start.y,p.y);
      this.select([...d.previous,...this.activeTrack().notes.filter(n=>this.x(n.beat)<x2&&this.x(n.beat+n.duration)>x1&&this.y(n.pitch)<y2&&this.y(n.pitch)+this.rowHeight>y1).map(n=>n.id)]);
    } else if(d.type==='velocity') {
      const v=clamp(Math.round((this.height-p.y)/this.velocityHeight*127),1,127);for(const n of this.selected())n.velocity=v;
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
    this.rowHeight=clamp(Math.floor((this.gridBottom()-this.ruler)/(max-min+5)),12,26);this.topPitch=Math.min(127,max+2);this.leftBeat=0;
    const end=Math.max(16,...notes.map(n=>n.beat+n.duration));this.beatWidth=clamp((this.width-this.keyboard-24)/end,24,160);this.onZoom?.(this.beatWidth);this.invalidate();
  }
  render() {
    const rect=this.canvas.parentElement.getBoundingClientRect();this.width=rect.width;this.height=rect.height;
    const dpr=Math.min(devicePixelRatio,2);for(const canvas of [this.canvas,this.overlay]){if(canvas.width!==Math.round(this.width*dpr)||canvas.height!==Math.round(this.height*dpr)){canvas.width=Math.round(this.width*dpr);canvas.height=Math.round(this.height*dpr);}}
    const ctx=this.ctx;ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,this.width,this.height);ctx.textBaseline='alphabetic';
    const vertices=[],rects=[];
    const box=(x,y,w,h,color)=>{if(w<=0||h<=0)return;const c=Array.isArray(color)?color:rgba(color);rects.push([x,y,w,h,c]);if(this.gl)for(const [px,py] of [[x,y],[x+w,y],[x,y+h],[x,y+h],[x+w,y],[x+w,y+h]])vertices.push(px,py,...c);};
    const bottom=this.gridBottom(),vmax=this.velocityHeight,p=this.project();
    box(0,0,this.width,this.height,'#12171d');
    // Ruler band and its separator.
    box(0,0,this.width,this.ruler,'#0e141a');box(0,this.ruler-1,this.width,1,'#2a3540');
    for(let pitch=this.topPitch;this.y(pitch)<bottom&&pitch>=0;pitch--) {
      const y=this.y(pitch),height=Math.min(this.rowHeight,bottom-y);
      box(this.keyboard,y,this.width-this.keyboard,height,black(pitch)?'#151b22':'#1a2028');box(this.keyboard,y+height-1,this.width-this.keyboard,1,'#232b34');
      box(0,y,this.keyboard-1,height,black(pitch)?'#171d24':'#9faab3');box(0,y+height-1,this.keyboard-1,1,black(pitch)?'#0e1319':'#7e8a92');
      const fs=this.rowHeight>=22?12:this.rowHeight>=14?11:10;
      if((pitch%12===0||this.rowHeight>=12)&&height>=fs+2){
        const octave=pitch%12===0;
        ctx.font='700 '+fs+'px ui-monospace, monospace';
        ctx.fillStyle=black(pitch)?(octave?'#e6edf3':'#b6c2cd'):(octave?'#050b11':'#16202a');
        ctx.textAlign='right';ctx.fillText(noteName(pitch),this.keyboard-12,y+height*.68);
      }
    }
    box(this.keyboard-1,this.ruler,1,bottom-this.ruler,'#2a3540');
    // Grid hierarchy: bar > beat > subdivision.
    const step=this.beatWidth*this.snap>9?this.snap:1;
    for(let beat=Math.floor(this.leftBeat/step)*step;this.x(beat)<this.width;beat+=step) {
      const x=this.x(beat);if(x<this.keyboard)continue;
      const isBar=Math.abs(beat%4)<1e-9,isBeat=Number.isInteger(beat);
      box(x,this.ruler,1,bottom-this.ruler,isBar?'#3e4a56':isBeat?'#29323c':'#202831');
      if(isBar){ctx.font='11px "JetBrains Mono", ui-monospace, monospace';ctx.fillStyle='#b9c4cf';ctx.textAlign='left';ctx.fillText(String(beat/4+1).padStart(2,'0'),x+7,23);}
      else if(isBeat&&this.beatWidth>58){ctx.font='10px "JetBrains Mono", ui-monospace, monospace';ctx.fillStyle='#65727f';ctx.textAlign='left';ctx.fillText(String(beat%4+1),x+6,23);}
    }
    if(p.loop.enabled){
      const x=Math.max(this.keyboard,this.x(p.loop.start)),end=Math.min(this.width,this.x(p.loop.end));
      if(end>x){box(x,this.ruler,end-x,bottom-this.ruler,[.36,.61,.97,.035]);box(x,this.ruler-3,end-x,3,'#5b9cf8');box(x,this.ruler,end-x,1,[.36,.61,.97,.2]);}
      for(const beat of [p.loop.start,p.loop.end]){const lx=this.x(beat);if(lx>this.keyboard&&lx<this.width)box(lx,this.ruler-3,1,bottom-this.ruler+3,'#5c789c');}
    }
    // Velocity lane: same time grid so bars line up with notes.
    box(this.keyboard,bottom,this.width-this.keyboard,this.velocityHeight,'#10161c');box(0,bottom,this.width,1,'#2f3a45');
    box(this.keyboard-1,bottom,1,this.velocityHeight,'#2a3540');
    for(let beat=Math.floor(this.leftBeat/step)*step;this.x(beat)<this.width;beat+=step){const x=this.x(beat);if(x<this.keyboard)continue;box(x,bottom+1,1,this.velocityHeight-1,Math.abs(beat%4)<1e-9?'#26303a':'#1a222b');}
    const lanes=this.keyboard-14,laneBase=this.height;
    for(let i=1;i<=3;i++){const y=laneBase-vmax*i/4;box(this.keyboard,y,this.width-this.keyboard,1,i===2?'#232d37':'#1f2831');}
    ctx.font='600 10px ui-monospace, monospace';ctx.fillStyle='#a7b3be';ctx.textAlign='right';
    const labelY=[laneBase-2,laneBase-vmax/4+3.5,laneBase-vmax/2+3.5,laneBase-vmax*3/4+3.5,bottom+11];
    ['0','32','64','96','127'].forEach((label,i)=>ctx.fillText(label,lanes,labelY[i]));
    ctx.font='600 10px ui-monospace, monospace';ctx.fillStyle='#7f8d9a';ctx.textAlign='center';
    ctx.save();ctx.translate(15,bottom+this.velocityHeight/2);ctx.rotate(-Math.PI/2);ctx.fillText('VELOCITY',0,0);ctx.restore();
    for(const t of p.tracks.filter(t=>t.id!==this.getTrack()).concat(p.tracks.filter(t=>t.id===this.getTrack()))) {
      const active=t.id===this.getTrack();
      for(const n of t.notes) {
        let x=this.x(n.beat),right=this.x(n.beat+n.duration),y=this.y(n.pitch);
        if(right<this.keyboard||x>this.width)continue;
        const selected=active&&this.selection.has(n.id),hovered=active&&!selected&&this.hoverId===n.id;
        const color=rgba(t.color,active?(t.muted ? .3 : .92):.2);
        const left=Math.max(this.keyboard,x+1),w=Math.min(this.width,right-1)-left;
        if(y>=this.ruler&&y+this.rowHeight<=bottom&&w>0) {
          if(selected)box(left-2,y+1,w+4,this.rowHeight-2,'#f2f8ff');
          else if(hovered)box(left-1,y+1,w+2,this.rowHeight-2,'#d8e9ff');
          box(left,y+2,w,this.rowHeight-3,color);
          if(active){box(left,y+2,w,1,[1,1,1,.16]);box(left,y+this.rowHeight-4,w,1,[0,0,0,.2]);}
          if(this.rowHeight>=12&&w>12){
            const name=noteName(n.pitch);
            let size=this.rowHeight>=22?12:this.rowHeight>=14?11:10;
            ctx.font=`600 ${size}px "JetBrains Mono", ui-monospace, monospace`;
            let tw=ctx.measureText(name).width;
            if(w<tw+9&&size>9){size=9;ctx.font='600 9px "JetBrains Mono", ui-monospace, monospace';tw=ctx.measureText(name).width;}
            if(w>=tw+6){
              ctx.save();ctx.beginPath();ctx.rect(left,y,w,this.rowHeight);ctx.clip();ctx.textAlign='left';
              ctx.fillStyle=active?(t.muted?'rgba(225,236,242,.55)':(selected||hovered?'#071019':'#0a1622')):'rgba(222,234,240,.45)';
              ctx.fillText(name,left+5,y+this.rowHeight*.72);ctx.restore();
            }
          }
          if(active&&w>16)box(right-6,y+5,1,this.rowHeight-10,[0,0,0,.28]);
        }
        if(active&&x>=this.keyboard){const h=n.velocity/127*vmax,bw=Math.max(3,Math.min(8,w));box(x,this.height-h,bw,h,rgba(t.color,selected?1:.55));box(x,this.height-h,bw,2,rgba(t.color,selected?1:.82));}
      }
    }
    if(this.drag?.type==='marquee'){const {start,end}=this.drag;const x1=Math.min(start.x,end.x),y1=Math.min(start.y,end.y),w=Math.abs(start.x-end.x),h=Math.abs(start.y-end.y);box(x1,y1,w,h,[.36,.61,.97,.07]);box(x1,y1,w,1,[.36,.61,.97,.6]);box(x1,y1+h-1,w,1,[.36,.61,.97,.6]);box(x1,y1,1,h,[.36,.61,.97,.6]);box(x1+w-1,y1,1,h,[.36,.61,.97,.6]);}
    if(this.cursor>=this.leftBeat&&this.x(this.cursor)<this.width) {box(this.x(this.cursor),this.ruler,1.5,this.height-this.ruler,'#d6e8ff');box(this.x(this.cursor)-4,5,9,7,'#d6e8ff');}
    if(this.gl) {
      const gl=this.gl;gl.viewport(0,0,this.canvas.width,this.canvas.height);gl.clearColor(.071,.09,.114,1);gl.clear(gl.COLOR_BUFFER_BIT);gl.useProgram(this.program);gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);
      gl.bindBuffer(gl.ARRAY_BUFFER,this.buffer);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(vertices),gl.DYNAMIC_DRAW);gl.enableVertexAttribArray(this.positionLoc);gl.vertexAttribPointer(this.positionLoc,2,gl.FLOAT,false,24,0);gl.enableVertexAttribArray(this.colorLoc);gl.vertexAttribPointer(this.colorLoc,4,gl.FLOAT,false,24,8);gl.uniform2f(this.sizeLoc,this.width,this.height);gl.drawArrays(gl.TRIANGLES,0,vertices.length/6);
    } else {
      // Draw fallback geometry behind the label layer without hiding its text.
      ctx.globalCompositeOperation='destination-over';for(const [x,y,w,h,c] of rects.toReversed()){ctx.fillStyle=`rgba(${c[0]*255},${c[1]*255},${c[2]*255},${c[3]})`;ctx.fillRect(x,y,w,h);}ctx.globalCompositeOperation='source-over';
    }
    this.onRender?.({backend:this.gl?'WebGL':'Canvas 2D',notes:p.tracks.reduce((sum,t)=>sum+t.notes.length,0)});
  }
}
