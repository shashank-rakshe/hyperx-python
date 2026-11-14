"""Build the artifact page of the ship viewer with a model XML embedded: python make_viewer_page.py model.xml out.html"""
import sys, re
src = open('/mnt/user-data/outputs/ship_xml_viewer.html', encoding='utf-8').read() if len(sys.argv) < 4 else open(sys.argv[3], encoding='utf-8').read()
xml = open(sys.argv[1], encoding='utf-8').read()
xml = re.sub(r'>\s+<', '><', xml).replace('</script', '<\\/script')
style = re.search(r'<style>(.*?)</style>', src, re.S).group(1)
body = re.search(r'<body>(.*?)<script>', src, re.S).group(1)
js = re.search(r'<script>\n(.*?)</script>\s*</body>', src, re.S).group(1)
style = re.sub(r':root\{[^}]*\}\s*@media \(prefers-color-scheme: light\)\{:root\{[^}]*\}\}', '', style, count=1)
tokens = '''
:root{--bg:#eef1f5;--panel:#ffffff;--line:#cfd6df;--txt:#1d2530;--mut:#5d6b7b;--acc:#0b6bcb}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#1e2227;--panel:#262b32;--line:#39414b;--txt:#d8dee6;--mut:#8a95a3;--acc:#4da3ff;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#1e2227;--panel:#262b32;--line:#39414b;--txt:#d8dee6;--mut:#8a95a3;--acc:#4da3ff;color-scheme:dark}
'''
style = style.replace('html,body{margin:0;height:100%;', 'html,body{margin:0;height:100%;')
style += '''
#top,#side .hd{padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px))}
#stage{padding-right:env(safe-area-inset-right,0px)}
#note{position:absolute;left:10px;top:8px;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:4px 9px;font-size:12px;color:var(--mut);max-width:60%}
'''
body = body.replace('<input type="file" id="file" accept=".xml,text/xml" multiple hidden>', '<input type="file" id="file" accept=".xml,text/xml" multiple hidden>')
js = js.replace("legend();resize();\n", '''legend();resize();
(function(){const el=document.getElementById('model');if(!el)return;
 const t=el.textContent;try{const all=parse(t,'built model');items=all;prepare(items);document.getElementById('drop').style.display='none';
 const c={};items.forEach(i=>c[i.type]=(c[i.type]||0)+1);fileNames=[el.dataset.name||'built model'];
 document.getElementById('stat').textContent=`${fileNames[0]} · ${blocks.length} blocks · ${new Set(items.map(i=>i.panel)).size} panels · ${items.length} parts`;
 legend();drawTree();resize();setView('iso');}catch(e){document.getElementById('stat').textContent='could not read the embedded model'}})();
''')
js = js.replace("type:'web',t:0,", "type:'web',t:0,md:web.getAttribute('MaterialDirection'),").replace("type:'flange',t:+(fl.getAttribute('Thickness')||0),", "type:'flange',md:fl.getAttribute('MaterialDirection'),t:+(fl.getAttribute('Thickness')||0),")
js = js.replace('pan:e.button===2||e.shiftKey', 'pan:e.button===2||e.shiftKey||window._panmode')
js = js.replace('for(const {it,sp} of draw){\n    const col=colorOf(it);','for(const {it,sp} of draw){\n    const col=colorOf(it);\n    if(window._ext&&window._ext(it,c,alpha,col))continue;')
name = sys.argv[1].split('/')[-1]
page = f'''<title>Ship Model Viewer</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>{tokens}{style}</style>
{body}
<script id="model" type="application/xml" data-name="{name}">{xml}</script>
<script>
{js}</script>
'''
# chat page: panel hidden, buttons that show the deck beam - bracket - wall stiffener connection of the VFD room
page = page.replace('<button id="fit">Fit</button>', '<button id="fit">Fit</button><button id="c85">Connection 8525</button><button id="c186">Connection 18665</button><button id="all">All parts</button><button id="w85">VFD wall 8525</button><button id="w186">VFD wall 18665</button><button id="f4000">VFD FR.47-4000</button><button id="f47">VFD FR.47</button><button id="f48">FR.48 section</button><button id="s2665">Slanted 2665</button><span style="width:8px"></span><input id="mq" list="mlist" placeholder="member e.g. FR47-4000/O1" style="width:190px"><datalist id="mlist"></datalist><button id="mz">Zoom member</button><button id="me">End view (L section)</button><button id="pn">Pan: off</button><button class="pa" data-dx="60" data-dy="0">◀</button><button class="pa" data-dx="0" data-dy="60">▲</button><button class="pa" data-dx="0" data-dy="-60">▼</button><button class="pa" data-dx="-60" data-dy="0">▶</button><button id="sl">Solid: off</button><button id="zi">Zoom +</button><button id="zo">Zoom −</button><label style="display:flex;gap:3px;align-items:center"><input type="checkbox" id="iso" checked>isolate</label><label style="display:flex;gap:3px;align-items:center"><input type="checkbox" id="fa" checked>flange arrows</label><button class="qm" data-q="FR47-4000/O1">O1</button><button class="qm" data-q="FR47-4000/O2">O2</button><button class="qm" data-q="FR47-4000/O3">O3</button><button class="qm" data-q="FR47-4000/O4">O4</button>', 1)
page = page.replace("legend();resize();\n(function(){const el", "document.body.classList.add('nosb');document.getElementById('sb').textContent='Show panel';\nlegend();resize();\n(function(){const el", 1)
extra = '''
function focusConn(oc,wy,yaw){
  items.forEach(i=>{i.on=false;
    if(i.panel==='PDF-VFDROOM-OFFCL'+oc&&(/\\/S[1-4] /.test(i.name)||(i.type==='plate'&&/-P1$/.test(i.name))))i.on=true;
    if(i.panel==='PDF-Z41460DK'&&(/\\/B[1-5] /.test(i.name)||/-B\\d+$/.test(i.name)))i.on=true;
  });
  drawTree();view.yaw=yaw;view.pitch=0.4;view.tx=97800;view.ty=wy;view.tz=40000;view.dist=8500;view.panx=0;view.pany=0;render();
}
document.getElementById('c85').onclick=()=>focusConn(8525,-8525,0.55);
document.getElementById('c186').onclick=()=>focusConn(18665,-18665,Math.PI-0.55);
function focusWall(oc,wy,yaw){
  items.forEach(i=>{i.on=false;
    if(i.panel.indexOf('PDF-VFDROOM-OFFCL'+oc)===0)i.on=true;
    if(i.panel==='PDF-Z41460DK'&&(/\\/B[1-5] /.test(i.name)||/-B\\d+$/.test(i.name)))i.on=true;
  });
  drawTree();view.yaw=yaw;view.pitch=0.3;view.tx=98000;view.ty=wy;view.tz=39300;view.dist=9500;view.panx=0;view.pany=0;render();
}
document.getElementById('w85').onclick=()=>focusWall(8525,-8525,0.55);
document.getElementById('w186').onclick=()=>focusWall(18665,-18665,Math.PI-0.55);
function focusFrame(nm,fx){
  items.forEach(i=>{i.on=(i.panel.indexOf('PDF-VFDROOM-'+nm)===0&&(nm!=='FR47'||i.panel.indexOf('PDF-VFDROOM-FR47-4000')!==0))||i.panel.indexOf('PDF-FR'+fx)===0&&/Z37160|Z39930|Z39945|Z41460/.test(i.panel);});
  drawTree();view.yaw=-0.6;view.pitch=0.25;view.tx=fx+200;view.ty=-13600;view.tz=39300;view.dist=15000;view.panx=0;view.pany=0;render();
}
document.getElementById('f4000').onclick=()=>focusFrame('FR47-4000',96000);
document.getElementById('f47').onclick=()=>focusFrame('FR47',100000);
function focusFr48(slant){
  items.forEach(i=>{i.on=i.panel.indexOf('PDF-FR103545')===0||/DEEP7/.test(i.panel)||(slant&&/OFFCL2665/.test(i.panel));});
  drawTree();view.yaw=-0.9;view.pitch=0.2;view.tx=103400;view.ty=slant?-2665:-8000;view.tz=40000;view.dist=slant?9000:18000;view.panx=0;view.pany=0;render();
}
document.getElementById('f48').onclick=()=>focusFr48(false);
document.getElementById('s2665').onclick=()=>focusFr48(true);
document.getElementById('all').onclick=()=>{items.forEach(i=>i.on=true);drawTree();fit()};

/* ---- member zoom + flange arrows (owner request) ---- */
const _mk=it=>it.name.replace(/ (Web|Flange)$/,'');
const _stif=()=>items.filter(i=>i.type==='web'||i.type==='flange');
(function(){const keys=[...new Set(_stif().map(_mk))].sort();document.getElementById('mlist').innerHTML=keys.map(k=>'<option value="'+k.replace(/"/g,'')+'">').join('');})();
const _fnote=document.createElement('div');_fnote.id='fnote';_fnote.style.cssText='position:absolute;left:10px;top:8px;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:5px 9px;font-size:12px;max-width:62%;display:none;white-space:pre-wrap';document.getElementById('stage').appendChild(_fnote);
let _focus=null,_ortho=false;
const _proj0=project;
project=function(c,p){if(!_ortho)return _proj0(c,p);const v=sub(p,c.eye),x=dot(v,c.r),y=dot(v,c.up),z=-dot(v,c.d);const W=cv.clientWidth,H=cv.clientHeight,f=Math.min(W,H)*0.9,k=f/view.dist;return[W/2+view.panx+k*x,H/2+view.pany-k*y,z]};
function _pair(key){const w=items.find(i=>i.type==='web'&&_mk(i)===key),f=items.find(i=>i.type==='flange'&&_mk(i)===key);return{w,f}}
function _cen(p){const c=[0,0,0];p.p3.forEach(q=>{for(let k=0;k<3;k++)c[k]+=q[k]});return c.map(v=>v/p.p3.length)}
function _axisName(v){const a=[Math.abs(v[0]),Math.abs(v[1]),Math.abs(v[2])],k=a.indexOf(Math.max(...a));return(v[k]<0?'-':'+')+'XYZ'[k]}
function _flangeVec(w,f){const wc=_cen(w),fc=_cen(f),n=nrm(f.cs.w);const d=dot(sub(wc,fc),n);const pr=[wc[0]-n[0]*d,wc[1]-n[1]*d,wc[2]-n[2]*d];return{from:pr,to:fc,v:sub(fc,pr)}}
function _memberAxis(w){let best=0,A=null;const P=w.p3;for(let i=0;i<P.length;i++){const q=P[(i+1)%P.length],dd=len(sub(q,P[i]));if(dd>best){best=dd;A=sub(q,P[i])}}return nrm(A)}
function zoomMember(q,end){
  q=(q||'').trim().toLowerCase();if(!q)return;_ortho=!!end;
  const keys=[...new Set(_stif().map(_mk))];
  const key=keys.find(k=>k.toLowerCase()===q)||keys.find(k=>k.toLowerCase().endsWith('/'+q))||keys.find(k=>k.toLowerCase().includes(q));
  if(!key){document.getElementById('stat').textContent='member not found: '+q;return}
  const {w,f}=_pair(key);_focus=key;
  if(document.getElementById('iso').checked)items.forEach(i=>{i.on=(i===w||i===f)});
  else{w&&(w.on=true);f&&(f.on=true)}
  const pts=[...(w?w.p3:[]),...(f?f.p3:[])],mn=[1e18,1e18,1e18],mx=[-1e18,-1e18,-1e18];
  pts.forEach(p=>{for(let k=0;k<3;k++){mn[k]=Math.min(mn[k],p[k]);mx[k]=Math.max(mx[k],p[k])}});
  view.tx=(mn[0]+mx[0])/2;view.ty=(mn[1]+mx[1])/2;view.tz=(mn[2]+mx[2])/2;view.panx=0;view.pany=0;
  const ext=len(sub(mx,mn));
  if(end&&w){const a=_memberAxis(w);let d=a[2]<0?[-a[0],-a[1],-a[2]]:a;if(Math.abs(a[2])<1e-6&&a[1]<0)d=[-a[0],-a[1],0];
    view.pitch=Math.max(-1.5698,Math.min(1.5698,Math.asin(d[2])));view.yaw=Math.atan2(d[0],-d[1]);
    const sec=[];if(w)sec.push(...w.p3);if(f)sec.push(...f.p3);
    view.dist=Math.max(ext*0.5,400);
    // end view: look at the cross-section scale (150 mm) not the member length
    const pp=[...(w?w.p3:[]),...(f?f.p3:[])],mxd=Math.max(...pp.map(p=>dot(p,d))),endp=pp.filter(p=>dot(p,d)>mxd-5),ec=[0,0,0];
    endp.forEach(p=>{for(let k=0;k<3;k++)ec[k]+=p[k]/endp.length});
    view.tx=ec[0];view.ty=ec[1];view.tz=ec[2];view.dist=450;
  }else{view.yaw=-0.8;view.pitch=0.5;view.dist=Math.max(ext*1.6,700)}
  drawTree();render();
}
document.getElementById('mz').onclick=()=>zoomMember(document.getElementById('mq').value,false);
document.getElementById('me').onclick=()=>zoomMember(document.getElementById('mq').value,true);
document.getElementById('mq').addEventListener('change',()=>zoomMember(document.getElementById('mq').value,false));
document.querySelectorAll('.qm').forEach(b=>b.onclick=()=>{document.getElementById('mq').value=b.dataset.q;zoomMember(b.dataset.q,false)});
document.getElementById('zi').onclick=()=>{view.dist*=0.55;render()};
document.getElementById('zo').onclick=()=>{view.dist/=0.55;render()};
document.getElementById('fa').onchange=render;
document.querySelectorAll('#top button:not(#me):not(#zi):not(#zo):not(#mz):not(.qm):not(#pn):not(.pa):not(#sl)').forEach(b=>b.addEventListener('click',()=>{_ortho=false;render()}));

function _hull(P){P=P.slice().sort((a,b)=>a[0]-b[0]||a[1]-b[1]);const cr=(o,a,b)=>(a[0]-o[0])*(b[1]-o[1])-(a[1]-o[1])*(b[0]-o[0]);const lo=[];for(const p of P){while(lo.length>=2&&cr(lo[lo.length-2],lo[lo.length-1],p)<=0)lo.pop();lo.push(p)}const up=[];for(const p of P.slice().reverse()){while(up.length>=2&&cr(up[up.length-2],up[up.length-1],p)<=0)up.pop();up.push(p)}lo.pop();up.pop();return lo.concat(up)}
function _thk(it){const q=(it.attrs.params||'').split(/\\s+/).map(Number);if(it.type==='flange')return it.t||(q.length>=4?q[3]:12);return q.length>=3?q[2]:(q[1]||0)}
function _solid(it,c){const t=_thk(it),sg=it.md==='Positive'?1:(it.md==='Negative'?-1:0),w=nrm(it.cs.w);
  const pts=[];for(const p of it.p3){pts.push(project(c,p));const o=sg*t;pts.push(project(c,[p[0]+w[0]*o,p[1]+w[1]*o,p[2]+w[2]*o]));if(!sg){pts.push(project(c,[p[0]-w[0]*t/2,p[1]-w[1]*t/2,p[2]-w[2]*t/2]));pts.push(project(c,[p[0]+w[0]*t/2,p[1]+w[1]*t/2,p[2]+w[2]*t/2]))}}
  const h=_hull(pts.map(p=>[p[0],p[1]]));if(h.length<3)return;ctx.beginPath();ctx.moveTo(h[0][0],h[0][1]);h.slice(1).forEach(p=>ctx.lineTo(p[0],p[1]));ctx.closePath();
  ctx.globalAlpha=.9;ctx.fillStyle=TYPES[it.type][1];ctx.fill();ctx.globalAlpha=1;ctx.strokeStyle='#000';ctx.lineWidth=1;ctx.stroke()}
const _render0=render;
render=function(){_render0();
  if(!items.length)return;const c=cam();
  if(_ortho&&_focus){const {w,f}=_pair(_focus);[w,f].forEach(it=>{if(!it)return;if(window._solidOn)_solid(it,c);else{const P=it.p3.map(p=>project(c,p));ctx.beginPath();ctx.moveTo(P[0][0],P[0][1]);for(let i=1;i<P.length;i++)ctx.lineTo(P[i][0],P[i][1]);ctx.closePath();ctx.strokeStyle=TYPES[it.type][1];ctx.lineWidth=4;ctx.stroke()}});}
  if(document.getElementById('fa').checked){
    let n=0;const keys=new Set();items.forEach(i=>{if(i.on&&(i.type==='web'||i.type==='flange'))keys.add(_mk(i))});
    if(keys.size<=250)keys.forEach(k=>{const {w,f}=_pair(k);if(!w||!f||!w.on||!f.on)return;
      const fv=_flangeVec(w,f);if(len(fv.v)<1)return;
      const a=project(c,fv.from),b=project(c,[fv.from[0]+fv.v[0]*2.2,fv.from[1]+fv.v[1]*2.2,fv.from[2]+fv.v[2]*2.2]);
      if(a[2]<=1||b[2]<=1)return;
      ctx.strokeStyle='#ff2bd6';ctx.fillStyle='#ff2bd6';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(a[0],a[1]);ctx.lineTo(b[0],b[1]);ctx.stroke();
      const ang=Math.atan2(b[1]-a[1],b[0]-a[0]);ctx.beginPath();ctx.moveTo(b[0],b[1]);ctx.lineTo(b[0]-9*Math.cos(ang-.45),b[1]-9*Math.sin(ang-.45));ctx.lineTo(b[0]-9*Math.cos(ang+.45),b[1]-9*Math.sin(ang+.45));ctx.closePath();ctx.fill();
      if(keys.size<=40){ctx.font='11px system-ui';ctx.fillText('flange '+_axisName(fv.v),b[0]+5,b[1]-4)}
    });
  }
  if(_focus){const {w,f}=_pair(_focus);if(w&&f){const fv=_flangeVec(w,f);const wc=_cen(w);
    _fnote.style.display='block';
    _fnote.textContent=_focus+'\\nflange side: '+_axisName(fv.v)+'   (web centre X '+Math.round(wc[0])+' Y '+Math.round(wc[1])+' Z '+Math.round(wc[2])+')\\nmagenta arrow = from web to flange';}}
};

/* ---- pan option ---- */
window._panmode=false;
document.getElementById('sl').onclick=e=>{window._solidOn=!window._solidOn;e.target.textContent='Solid: '+(window._solidOn?'ON':'off');e.target.classList.toggle('on',window._solidOn);render()};
document.getElementById('pn').onclick=e=>{window._panmode=!window._panmode;e.target.textContent='Pan: '+(window._panmode?'ON (drag)':'off');e.target.classList.toggle('on',window._panmode);cv.style.cursor=window._panmode?'move':'grab'};
document.querySelectorAll('.pa').forEach(b=>b.onclick=()=>{view.panx+=+b.dataset.dx;view.pany+=+b.dataset.dy;render()});
addEventListener('keydown',e=>{if(e.target&&/INPUT|TEXTAREA|SELECT/.test(e.target.tagName))return;const m={ArrowLeft:[60,0],ArrowRight:[-60,0],ArrowUp:[0,60],ArrowDown:[0,-60]}[e.key];if(m){view.panx+=m[0];view.pany+=m[1];render();e.preventDefault()}});

/* ---- solid (extruded) drawing of web / flange / bracket: no visual gap between web and flange ---- */
window._solidOn=false;
window._ext=function(it,c,alpha,col){
  if(!window._solidOn)return false;
  if(!(it.type==='web'||it.type==='flange'||it.type==='bracket'))return false;
  const t=it.type==='bracket'?(it.t||0):_thk(it);if(!t)return false;
  const sg=it.type==='bracket'?0:(it.md==='Positive'?1:(it.md==='Negative'?-1:0)),w=nrm(it.cs.w);
  const o0=sg===0?-t/2:0,o1=sg===0?t/2:sg*t;
  const A=it.p3.map(p=>[p[0]+w[0]*o0,p[1]+w[1]*o0,p[2]+w[2]*o0]),B=it.p3.map(p=>[p[0]+w[0]*o1,p[1]+w[1]*o1,p[2]+w[2]*o1]);
  const sa=A.map(p=>project(c,p)),sb=B.map(p=>project(c,p));if(sa.concat(sb).some(p=>p[2]<=1))return true;
  const za=sa.reduce((s,p)=>s+p[2],0),zb=sb.reduce((s,p)=>s+p[2],0);
  const lam=Math.abs(dot(it.n,c.d)),fa=shade(col,0.45+0.55*lam),fs=shade(col,0.4);
  const poly=(P,fill)=>{ctx.beginPath();ctx.moveTo(P[0][0],P[0][1]);for(let i=1;i<P.length;i++)ctx.lineTo(P[i][0],P[i][1]);ctx.closePath();ctx.globalAlpha=alpha;ctx.fillStyle=fill;ctx.fill();ctx.globalAlpha=1;if(showEdges||wire){ctx.strokeStyle='rgba(0,0,0,.45)';ctx.lineWidth=.6;ctx.stroke()}};
  const far=za>zb?sa:sb,near=za>zb?sb:sa;
  poly(far,fs);
  for(let i=0;i<sa.length;i++){const j=(i+1)%sa.length;poly([sa[i],sa[j],sb[j],sb[i]],fs)}
  poly(near,fa);
  return true;
};

/* ---- importer rule 4.1 (owner's import): the L flange inner edge (V = web thickness) is moved onto the web plane -> no gap, moulded thickness not considered ---- */
(function(){let n=0;items.forEach(it=>{if(it.type!=='flange'||!it.poly)return;const q=(it.attrs.params||'').split(/\\s+/).map(Number);if(q.length<4||it.attrs.section.indexOf('LBar')!==0)return;
  const tw=q[2],mn=Math.min(...it.poly.map(p=>p[1]));if(Math.abs(mn-tw)>0.5)return;
  it.poly=it.poly.map(p=>Math.abs(p[1]-mn)<1e-6?[p[0],0]:p);it.p3=it.poly.map(p=>to3(it.cs,p));n++});
  document.getElementById('stat').textContent+=' · L flanges joined to web plane: '+n;render();})();
window.addEventListener('load',()=>setTimeout(()=>{if(items.some(i=>i.panel==='PDF-VFDROOM-OFFCL8525'))focusConn(8525,-8525,0.55)},50));
'''
page = page[:page.rindex('</script>')] + extra + '</script>\n'
open(sys.argv[2], 'w', encoding='utf-8').write(page)
print(len(page) / 1e6, 'MB')
