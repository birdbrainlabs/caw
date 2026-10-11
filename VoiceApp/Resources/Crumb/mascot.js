import * as T from './source/vendor/three.module.js';
import {createMouthRig} from './source/mouth-rig.js';
import {CrumbCompanion} from './source/companion.js';
try {
 const renderer=new T.WebGLRenderer({alpha:true,antialias:true,powerPreference:'low-power'});
 renderer.setPixelRatio(Math.min(devicePixelRatio,2));document.body.append(renderer.domElement);
 const scene=new T.Scene(), camera=new T.OrthographicCamera(-2.5,2.5,2.5,-2.5,.1,50);
 camera.position.set(0,2.7,9);camera.lookAt(0,1.6,0);
 scene.add(new T.HemisphereLight(0xffffff,0x555568,2));
 const light=new T.DirectionalLight(0xfff4df,3);light.position.set(-4,7,6);scene.add(light);
 const gradient=new T.DataTexture(new Uint8Array([66,155,245]),3,1,T.RedFormat);gradient.needsUpdate=true;gradient.minFilter=gradient.magFilter=T.NearestFilter;
 const crumb=new CrumbCompanion(color=>new T.MeshToonMaterial({color,gradientMap:gradient}));crumb.root.position.y=1.05;scene.add(crumb.root);
 const mouthRig=createMouthRig(crumb,color=>new T.MeshToonMaterial({color,gradientMap:gradient}));
 let input={recording:false,processing:false,waiting:false,level:0,active:true,gentle:false},lastDelivery=null,celebrateUntil=0,volume=0,last=0;
 window.updateCrumb=value=>{
  input={...input,...value};
  if(lastDelivery!==null && value.delivery>lastDelivery)celebrateUntil=performance.now()+1500;
  if(Number.isFinite(value.delivery))lastDelivery=value.delivery;
 };
 function resize(){renderer.setSize(innerWidth,innerHeight);const a=innerWidth/Math.max(1,innerHeight);camera.left=-2.5*a;camera.right=2.5*a;camera.updateProjectionMatrix();}
 addEventListener('resize',resize);resize();
 // Idle, he is asked about four times a second instead of thirty; awake, every
 // frame as before. The idle tick exists only to notice when he should wake.
 const idle=()=>!input.active&&performance.now()>=celebrateUntil;
 function frame(ms){
  if(idle())setTimeout(()=>frame(performance.now()),250);else requestAnimationFrame(frame);
  if(ms-last<1000/30-1)return;
  const dt=Math.min(.05,(ms-last)/1000);last=ms;
  if(document.hidden)return;
  if(input.recording||input.processing||input.waiting)celebrateUntil=0;
  const state=input.recording?'talking':input.processing?'thinking':input.waiting?'curious':ms<celebrateUntil?'celebrating':'idle';
  const changed=crumb.state!==state;
  if(changed)crumb.setState(state);
  // Still when nothing is happening: no redraw at all unless the state just
  // changed (so he settles into his idle pose once) or he is celebrating.
  if(!input.active&&!changed&&ms>=celebrateUntil)return;
  crumb.gentle=input.gentle;crumb.update(dt);
  volume+=(Math.sqrt(Math.max(0,Math.min(1,input.level||0)))-volume)*(1-Math.exp(-dt*18));
  mouthRig.update(input.recording?volume:null);
  renderer.render(scene,camera);
 }
 requestAnimationFrame(frame);
 window.crumbDiagnostics=()=>({state:crumb.state,mouthY:crumb.mouth.scale.y,volume,delivery:lastDelivery,active:input.active});
} catch(error){document.querySelector('#error').style.display='block';console.error(error);}
