"""python make_region3d_page.py data.json "title" "subtitle" out.html [questions.json]   - 3D page (three.js from CDN in the browser only)"""
import sys, json, html
data, title, sub, out = sys.argv[1:5]
qs = json.load(open(sys.argv[5])) if len(sys.argv) > 5 else []
D = open(data).read()
E = html.escape
qhtml = ''.join(f"<li><b>{E(q['t'])}</b> {q['x']}" + ''.join(f"<img src='{u}' alt=''>" for u in q.get('img', [])) + "</li>" for q in qs)
page = f"""<title>{E(title)}</title>
<style>
:root{{--bg:#eef1f4;--panel:#fff;--fg:#17222d;--mut:#5b6a78;--line:#d5dde5;--acc:#1e5aa8}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--bg:#12171c;--panel:#1c242c;--fg:#e4eaf0;--mut:#93a2b0;--line:#2e3a45;--acc:#7fb0ef;color-scheme:dark}}}}
:root[data-theme="dark"]{{--bg:#12171c;--panel:#1c242c;--fg:#e4eaf0;--mut:#93a2b0;--line:#2e3a45;--acc:#7fb0ef;color-scheme:dark}}
body{{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif}}
header{{padding:12px 16px 4px}} h1{{font-size:1.3rem;margin:0}} .mut{{color:var(--mut)}}
.bar{{display:flex;flex-wrap:wrap;gap:6px;padding:6px 16px}}
.bar label{{background:var(--panel);border:1px solid var(--line);border-radius:999px;padding:3px 10px;cursor:pointer;user-select:none}}
.bar button{{font:inherit;background:var(--panel);color:var(--fg);border:1px solid var(--line);border-radius:999px;padding:3px 10px;cursor:pointer}}
.sw{{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:middle}}
#wrap{{position:relative;height:72vh;margin:0 16px;border:1px solid var(--line);border-radius:6px;overflow:hidden;background:#f7f8fa}}
#info{{position:absolute;left:8px;bottom:8px;max-width:min(560px,90%);background:rgba(255,255,255,.95);color:#17222d;border:1px solid #ccd;border-radius:6px;padding:8px 10px;font-size:12.5px;display:none;max-height:45%;overflow:auto}}
section{{margin:12px 16px 24px;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:10px 14px}}
section img{{display:block;max-width:100%;margin:6px 0;border:1px solid var(--line);background:#fff}}
li{{margin-bottom:10px}}
</style>
<header><h1>{E(title)}</h1><div class="mut">{E(sub)}</div></header>
<div class="bar" id="layers"></div>
<div class="bar"><button data-v="below">From below</button><button data-v="above">From above</button><button data-v="aft">Looking forward</button><button data-v="side">Looking inboard</button><span class="mut">Drag to rotate · scroll to zoom · right-drag to pan · click a part for its data</span></div>
<div id="wrap"><div id="info"></div></div>
{('<section><h2 style="margin:0 0 6px;font-size:1.1rem">Questions</h2><ol>' + qhtml + '</ol></section>') if qs else ''}
<script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/controls/OrbitControls.js"></script>
<script>
const DATA={D};
const COL={{'plate':0x9fb7c9,'web:beam':0x1e5aa8,'flange:beam':0x4f86d0,'web:carling':0xe07a00,'flange:carling':0xf0a040,'web:girder':0xc0141e,'flange:girder':0xe0505a,
 'web:deep':0x7a0010,'web:frame stiffener':0x1d8a4a,'flange:frame stiffener':0x52b77a,'web:wall stiffener':0x1d8a4a,'flange:wall stiffener':0x52b77a,'bracket':0x7b3fbf,'bracket:unknown':0xff00aa}};
const NAME={{'plate':'Plates (deck / wall)','beam':'Beams','carling':'Carlings','girder':'Girders','deep':'Deep girders','stiff':'Wall / frame stiffeners','bracket':'Brackets (size read)','bracket:unknown':'Brackets, size NOT read (pink)'}};
const grp=k=>k==='plate'?'plate':k==='bracket:unknown'?'bracket:unknown':k==='bracket'?'bracket':k.includes('stiffener')?'stiff':k.split(':')[1]||k;
const b=DATA.box, cx=(b[0]+b[1])/2, cy=(b[2]+b[3])/2, cz=(b[4]+b[5])/2, S=0.001;
const wrap=document.getElementById('wrap');
const scene=new THREE.Scene(); scene.background=new THREE.Color(0xf7f8fa);
const cam=new THREE.PerspectiveCamera(40,wrap.clientWidth/wrap.clientHeight,0.01,200);
const R=new THREE.WebGLRenderer({{antialias:true}}); R.setPixelRatio(Math.min(2,devicePixelRatio)); R.setSize(wrap.clientWidth,wrap.clientHeight); wrap.appendChild(R.domElement);
scene.add(new THREE.HemisphereLight(0xffffff,0x667788,0.9)); const dl=new THREE.DirectionalLight(0xffffff,0.5); dl.position.set(3,-2,5); scene.add(dl);
const ctl=new THREE.OrbitControls(cam,R.domElement); ctl.target.set(0,0,0);
const P=p=>new THREE.Vector3((p[0]-cx)*S,(p[1]-cy)*S,(p[2]-cz)*S);
const groups={{}}, meshes=[];
function poly(it){{
  const o=it.o.map(P); if(o.length<3)return;
  const a=o[0], e1=new THREE.Vector3().subVectors(o[1],a); let n=new THREE.Vector3();
  for(let i=2;i<o.length&&n.length()<1e-9;i++) n.crossVectors(e1,new THREE.Vector3().subVectors(o[i],a));
  if(n.length()<1e-12)return; n.normalize(); const u=e1.clone().normalize(), v=new THREE.Vector3().crossVectors(n,u);
  const to2=p=>{{const d=new THREE.Vector3().subVectors(p,a);return new THREE.Vector2(d.dot(u),d.dot(v));}};
  const sh=new THREE.Shape(o.map(to2)); (it.h||[]).forEach(h=>sh.holes.push(new THREE.Path(h.map(P).map(to2))));
  const g=new THREE.ShapeGeometry(sh); const m4=new THREE.Matrix4().makeBasis(u,v,n).setPosition(a); g.applyMatrix4(m4);
  const isPl=it.k==='plate', c=COL[it.k]??0x888888;
  const mat=new THREE.MeshLambertMaterial({{color:c,side:THREE.DoubleSide,transparent:isPl,opacity:isPl?0.35:1,depthWrite:!isPl}});
  const mesh=new THREE.Mesh(g,mat); mesh.userData=it;
  const ed=new THREE.LineSegments(new THREE.EdgesGeometry(g),new THREE.LineBasicMaterial({{color:isPl?0x55697a:0x222222,transparent:true,opacity:isPl?0.6:0.35}}));
  const k=grp(it.k); (groups[k]=groups[k]||new THREE.Group()).add(mesh,ed); meshes.push(mesh);
}}
DATA.items.forEach(poly); Object.values(groups).forEach(g=>scene.add(g));
const bar=document.getElementById('layers');
Object.keys(NAME).filter(k=>groups[k]).forEach(k=>{{const l=document.createElement('label'); const c=k==='stiff'?COL['web:wall stiffener']:k==='plate'?COL.plate:k.startsWith('bracket')?COL[k]:COL['web:'+k];
  l.innerHTML=`<input type=checkbox checked> <span class=sw style="background:#${{c.toString(16).padStart(6,'0')}}"></span>${{NAME[k]}} (${{groups[k].children.length/2}})`;
  l.querySelector('input').onchange=e=>groups[k].visible=e.target.checked; bar.appendChild(l);}});
const ext=Math.max(b[1]-b[0],b[3]-b[2],b[5]-b[4])*S;
const views={{below:[0.9,-1.1,-1.0],above:[0.8,-1.0,1.1],aft:[-1.6,0,0.12],side:[0,1.6,0.12]}};
function setView(k){{const d=views[k]; cam.position.set(d[0]*ext,d[1]*ext,d[2]*ext); cam.up.set(0,0,1); ctl.target.set(0,0,0); ctl.update();}}
document.querySelectorAll('[data-v]').forEach(bt=>bt.onclick=()=>setView(bt.dataset.v)); setView('below');
const ray=new THREE.Raycaster(), mp=new THREE.Vector2(), info=document.getElementById('info'); let sel=null, down=null;
R.domElement.addEventListener('pointerdown',e=>down=[e.clientX,e.clientY]);
R.domElement.addEventListener('pointerup',e=>{{ if(!down||Math.hypot(e.clientX-down[0],e.clientY-down[1])>4)return;
  const r=R.domElement.getBoundingClientRect(); mp.set((e.clientX-r.left)/r.width*2-1,-(e.clientY-r.top)/r.height*2+1); ray.setFromCamera(mp,cam);
  const hit=ray.intersectObjects(meshes.filter(m=>m.parent.visible)).filter(h=>h.object.userData.k!=='plate'||true)[0];
  if(sel){{sel.material.emissive.setHex(0);sel=null;}}
  if(!hit){{info.style.display='none';return;}}
  sel=hit.object; sel.material.emissive.setHex(0x444400); const it=sel.userData, i=it.i||{{}};
  const xs=it.o.map(p=>p[0]), ys=it.o.map(p=>p[1]), zs=it.o.map(p=>p[2]), rg=a=>Math.round(Math.min(...a))+'..'+Math.round(Math.max(...a));
  info.innerHTML=`<b>${{i.name||it.k}}</b> · ${{it.k}} ${{i.section?'· '+i.section:''}} ${{i.t?'· t '+i.t:''}}<br>X ${{rg(xs)}} · Y ${{rg(ys)}} · Z ${{rg(zs)}}<br><span style="color:#556">${{(i.evidence||i.panel||'').replace(/</g,'&lt;')}}</span>`;
  info.style.display='block';}});
addEventListener('resize',()=>{{cam.aspect=wrap.clientWidth/wrap.clientHeight;cam.updateProjectionMatrix();R.setSize(wrap.clientWidth,wrap.clientHeight);}});
(function loop(){{requestAnimationFrame(loop);ctl.update();R.render(scene,cam);}})();
</script>"""
open(out, 'w').write(page)
print(round(len(page) / 1e6, 2), 'MB')
