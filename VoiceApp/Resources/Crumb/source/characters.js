import * as T from './vendor/three.module.js';
export const CHARACTERS=[
 {id:'max',name:'Meat',family:'WAR BOYS',description:'One meatball. One magnificent bad idea.',color:0xb75132},
 {id:'grist',name:'Grist',family:'WAR BOYS',description:'A hard head and a very short fuse.',color:0x94411f},
 {id:'pup',name:'Pup',family:'WAR BOYS',description:'All Parmesan. Absolutely no hesitation.',color:0xd9a54b},
 {id:'char',name:'Char',family:'WAR BOYS',description:'Overcooked. Still causing trouble.',color:0x9f4326},
 {id:'crumb',name:'Crumb',family:'HALF-COOKEDS',description:'Helmet on. Nobody home.',color:0xc9872f},
 {id:'gooey',name:'Gooey',family:'HALF-COOKEDS',description:'Barely holding it together. Having a lovely time.',color:0xd88b31}
];
export function createCharacter(id,toon){
 const data=CHARACTERS.find(c=>c.id===id)??CHARACTERS[0];id=data.id;
 const root=new T.Group(),rolling=new T.Group(),face=new T.Group();root.add(rolling,face);
const ballGeo=new T.IcosahedronGeometry(.68,3),bp=ballGeo.attributes.position;for(let i=0;i<bp.count;i++){const x=bp.getX(i),y=bp.getY(i),z=bp.getZ(i),f=1+.037*Math.sin(x*22+y*8)*Math.cos(z*19-y*5);bp.setXYZ(i,x*f,y*f,z*f);}ballGeo.computeVertexNormals();
const ball=new T.Mesh(ballGeo,toon(0xb75132));ball.castShadow=true;rolling.add(ball);ball.name="body";
const outline=new T.Mesh(ballGeo,new T.MeshBasicMaterial({color:0x513326,side:T.BackSide}));outline.scale.setScalar(1.027);rolling.add(outline);
const crumbsGeo=new T.DodecahedronGeometry(.045,0),cheese=toon(0xf1d391);for(let i=0;i<42;i++){const y=1-2*(i+.5)/42,a=i*2.39996,r=Math.sqrt(1-y*y),c=new T.Mesh(crumbsGeo,cheese);c.position.set(Math.cos(a)*r*.68,y*.68,Math.sin(a)*r*.68);c.rotation.set(i*.3,i*.7,i);c.scale.setScalar(.5+(i%4)*.18);rolling.add(c);}
for(const [x,y,size] of [[-.22,.2,.2],[.22,.25,.235]]){const eye=new T.Mesh(new T.SphereGeometry(size,16,12),toon(0xffedc3));eye.position.set(x,y,.55);face.add(eye);eye.name=x<0?"eyeLeft":"eyeRight";const pupil=new T.Mesh(new T.SphereGeometry(size*.41,12,8),new T.MeshBasicMaterial({color:0x1b2422}));pupil.position.set(x+.025,y-.025,.55+size*.88);face.add(pupil);pupil.name=x<0?"pupilLeft":"pupilRight";}
const mouth=new T.Mesh(new T.SphereGeometry(1,18,12),new T.MeshBasicMaterial({color:0x321d1c}));mouth.scale.set(.34,.25,.075);mouth.position.set(0,-.22,.615);face.add(mouth);mouth.name="mouth";
for(let i=0;i<4;i++){const tooth=new T.Mesh(new T.ConeGeometry(.063,.14,3),toon(0xffe7b7));tooth.rotation.z=Math.PI;tooth.position.set(-.21+i*.14,-.105,.687);face.add(tooth);tooth.name="tooth";}for(let i=0;i<3;i++){const tooth=new T.Mesh(new T.ConeGeometry(.055,.11,3),toon(0xffe7b7));tooth.position.set(-.15+i*.15,-.39,.678);face.add(tooth);tooth.name="tooth";}

 ball.material.color.setHex(data.color);
 const dark=new T.MeshBasicMaterial({color:0x321d1c});
 const add=(geo,mat,x,y,z,parent=face)=>{const m=new T.Mesh(geo,mat);m.position.set(x,y,z);parent.add(m);m.castShadow=true;return m;};
 const eyeL=face.getObjectByName('eyeLeft'),eyeR=face.getObjectByName('eyeRight'),pupilL=face.getObjectByName('pupilLeft'),pupilR=face.getObjectByName('pupilRight');
 const removeTeeth=()=>face.children.filter(m=>m.name==='tooth').forEach(m=>{m.geometry.dispose();m.material.dispose();face.remove(m);});
 const fang=(x,y,size=.17)=>{const t=add(new T.ConeGeometry(size*.45,size,3),toon(0xffe7b7),x,y,.73);t.rotation.z=Math.PI;};
 if(id==='grist'||id==='char'){
  removeTeeth();mouth.scale.set(.25,.1,.06);mouth.position.y=-.26;
  for(const sign of [-1,1]){const brow=add(new T.BoxGeometry(.41,.12,.14),toon(data.color),sign*.22,.34,.71);brow.rotation.z=sign*.25;}
  if(id==='grist')fang(0,-.30,.28);else{fang(-.075,-.24);fang(.075,-.24);}
 }
 if(id==='grist'){
  const crack=new T.CatmullRomCurve3([new T.Vector3(.01,.64,.23),new T.Vector3(-.04,.48,.48),new T.Vector3(.02,.26,.64),new T.Vector3(-.04,.05,.7),new T.Vector3(.01,-.1,.69)]);
  add(new T.TubeGeometry(crack,12,.025,5,false),dark,0,0,0);
 }
 if(id==='pup'){
  pupilL.scale.setScalar(1.85);pupilR.scale.setScalar(1.8);
  for(let i=0;i<38;i++){const y=.1+(i%7)*.076,a=i*2.4,r=Math.sqrt(Math.max(.01,.7*.7-y*y));add(new T.DodecahedronGeometry(.075,0),cheese,Math.cos(a)*r,y,Math.sin(a)*r,rolling);}
 }
 if(id==='char'){
  const colors=[];for(let i=0;i<bp.count;i++){const c=new T.Color(bp.getX(i)<0?0x292d2b:data.color);colors.push(c.r,c.g,c.b);}ballGeo.setAttribute('color',new T.Float32BufferAttribute(colors,3));ball.material.color.setHex(0xffffff);ball.material.vertexColors=true;
  const patch=add(new T.SphereGeometry(1,14,12),toon(0x292d2b),-.27,.09,.46);patch.scale.set(.34,.5,.19);pupilL.visible=false;
 }
 if(id==='crumb'){
  removeTeeth();for(const x of [-.1,.1]){const tooth=add(new T.BoxGeometry(.14,.17,.04),toon(0xffe7b7),x,-.12,.705);tooth.name='crumbTooth';}
  const cap=new T.Group();cap.position.set(-.09,.59,0);cap.rotation.z=.16;face.add(cap);
  add(new T.CylinderGeometry(.36,.42,.15,16),toon(0x999c91),0,.11,0,cap);
  for(let i=0;i<16;i++){const a=i*Math.PI/8;const ridge=add(new T.BoxGeometry(.075,.14,.065),toon(0xc1bdaa),Math.sin(a)*.39,.045,Math.cos(a)*.39,cap);ridge.rotation.y=a;}
  for(const x of [-.18,.09])add(new T.BoxGeometry(.07,.1,.016),toon(0xb75132),x,.13,.355,cap);
  for(let i=0;i<26;i++){const y=1-2*(i+.5)/26,a=i*2.4,r=Math.sqrt(1-y*y);add(new T.DodecahedronGeometry(.06,0),toon(i%2?0xe6b45b:0xb5752f),Math.cos(a)*r*.7,y*.7,Math.sin(a)*r*.7,rolling);}
 }
 if(id==='gooey'){
  eyeL.position.y-=.08;pupilL.position.y-=.08;eyeR.position.y+=.1;pupilR.position.y+=.1;
  const hole=add(new T.SphereGeometry(1,12,10),toon(0x7e4721),-.42,-.08,.46);hole.scale.set(.24,.38,.18);
  for(let i=0;i<4;i++){const x=-.55+i*.075;const curve=new T.CatmullRomCurve3([new T.Vector3(x,.2,.56),new T.Vector3(x+.06,0,.67),new T.Vector3(x-.02,-.37,.54)]);add(new T.TubeGeometry(curve,10,.026,5,false),cheese,0,0,0);}
 }
 if(['pup','crumb','gooey'].includes(id)){const tongue=add(new T.SphereGeometry(1,10,8),toon(0xc64c3a),.03,-.35,.7);tongue.scale.set(.12,.075,.035);if(id==='crumb')tongue.name='crumbTongue';}
 return {root,rolling,face,id};
}
export function addPreviewArms(root,toon){for(const sign of [-1,1]){const curve=new T.CatmullRomCurve3([new T.Vector3(sign*.58,0,0),new T.Vector3(sign*.98,-.13,0),new T.Vector3(sign*1.3,.42,0),new T.Vector3(sign*1.15,.5,0)]);root.add(new T.Mesh(new T.TubeGeometry(curve,20,.055,7,false),toon(0xecc271)));}}
export function disposeCharacter(root){const geometries=new Set(),materials=new Set();root.traverse(o=>{if(o.geometry)geometries.add(o.geometry);if(o.material)materials.add(o.material);});geometries.forEach(g=>g.dispose());materials.forEach(m=>m.dispose());}
