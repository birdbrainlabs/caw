import * as T from './vendor/three.module.js';
import {createCharacter} from './characters.js';
import {JuiceMotion} from './juice-motion.js';

export const STATES=['idle','curious','thinking','talking','celebrating'];
const V=(x,y,z=0)=>new T.Vector3(x,y,z);
const blend=(a,b,k)=>T.MathUtils.lerp(a,b,k);
const sixPoints=points=>new T.CatmullRomCurve3(points).getPoints(5);
const bounceKeys=[[0,1],[.15,.76],[.22,1.26],[.48,1],[.80,1.14],[.88,.67],[1.08,1.08],[1.32,1],[1.5,1]];
function bounceScale(t){
 for(let i=1;i<bounceKeys.length;i++){const [end,b]=bounceKeys[i], [start,a]=bounceKeys[i-1];if(t<=end)return blend(a,b,(1-Math.cos(Math.PI*(t-start)/(end-start)))/2);}
 return 1;
}

// Character art stays in the original characters.js. This controller only poses it.
export class CrumbCompanion {
 constructor(toon){
  this.root=new T.Group();this.root.scale.setScalar(1.5);
  this.poseRoot=new T.Group();this.root.add(this.poseRoot);
  this.model=createCharacter('crumb',toon);this.poseRoot.add(this.model.root);
  this.juice=new JuiceMotion();this.state='idle';this.time=0;this.age=0;this.gentle=false;
  this.weights=Object.fromEntries(STATES.map(s=>[s,s==='idle'?1:0]));
  this.pointer=new T.Vector2();this.look=new T.Vector2();
  this.mouth=this.model.face.getObjectByName('mouth');
  this.eyes=['Left','Right'].map(side=>({eye:this.model.face.getObjectByName('eye'+side),pupil:this.model.face.getObjectByName('pupil'+side)}));
  this.eyes.forEach(e=>{e.base=e.pupil.position.clone();e.eyeBase=e.eye.position.clone();});
  this.arms=[-1,1].map(sign=>{
   const points=sixPoints([V(sign*.58,0),V(sign*1.03,-.13),V(sign*1.41,.42),V(sign*1.23,.5)]);
   const curve=new T.CatmullRomCurve3(points);
   const geometry=new T.TubeGeometry(curve,28,.055,7,false);
   const mesh=new T.Mesh(geometry,toon(0xecc271));this.poseRoot.add(mesh);
   return {sign,points,curve,mesh};
  });
 }
 setState(state){if(!STATES.includes(state))throw new Error('Unknown Crumb state: '+state);this.state=state;this.age=0;if(state==='celebrating')this.juice.cheer();}
 setLook(x,y){this.pointer.set(T.MathUtils.clamp(x,-1,1),T.MathUtils.clamp(y,-1,1));}
 update(dt){
  dt=T.MathUtils.clamp(dt,0,.05);this.time+=dt;this.age+=dt;const t=this.time;
  const k=1-Math.exp(-7*dt);for(const s of STATES)this.weights[s]=blend(this.weights[s],s===this.state?1:0,k);
  const {curious:c,thinking:h,talking:q,celebrating:j}=this.weights;const amplitude=this.gentle?.3:1;
  // Curious: ease around a shoulder, spot something, then settle back.
  const peekPhase=this.age%7.2;
  const peekSide=Math.floor(this.age/7.2)%2===0?1:-1;
  const peek=T.MathUtils.smoothstep(peekPhase,.4,1.8)*(1-T.MathUtils.smoothstep(peekPhase,4.3,5.7));
  const surprise=T.MathUtils.smoothstep(peekPhase,2.85,3.06)*(1-T.MathUtils.smoothstep(peekPhase,3.85,4.65));
  const recoil=T.MathUtils.smoothstep(peekPhase,2.85,3.06)*(1-T.MathUtils.smoothstep(peekPhase,3.15,3.65));
  // Anticipation → airborne stretch → landing compression → soft rebound.
  // A volume-preserving scale and bottom offset keep grounded poses planted.
  const bouncePhase=this.age%1.5;
  const flight=(bouncePhase-.22)/.58;
  this.hop=(flight>0&&flight<1?Math.sin(flight*Math.PI)*.34:0)*j*(this.gentle?0:1);
  this.juice.update(dt);
  const breath=Math.sin(t*2)*.012*amplitude;
  const bodyY=(1+(bounceScale(bouncePhase)-1)*j*amplitude)*(1+breath);
  const bodyWidth=1/Math.sqrt(bodyY);
  this.poseRoot.scale.set(bodyWidth,bodyY,bodyWidth);
  this.poseRoot.position.set(c*peekSide*(peek*.18-recoil*.035)*amplitude,.7*(bodyY-1)+this.hop+c*peek*.26*amplitude,c*(peek*.09-recoil*.05)*amplitude);
  this.poseRoot.rotation.z=amplitude*(-c*peekSide*peek*.09+h*-.12+j*Math.sin(t*8)*.07);
  // His right is screen-left when he faces us. Ease into an occasional
  // upward glance, hold briefly, then return to a relaxed forward gaze.
  const glancePhase=this.age%5.6;
  const glance=T.MathUtils.smoothstep(glancePhase,.45,1.15)*(1-T.MathUtils.smoothstep(glancePhase,3.25,4.1));
  this.model.face.rotation.y=amplitude*(c*peekSide*peek*.21-h*(.04+.14*glance)+q*Math.sin(t*2)*.04);
  this.model.face.rotation.x=c*peek*.17-h*(.02+.09*glance)+q*Math.sin(t*7)*.015*amplitude;
  const pointerWeight=(.22+c*.78)*(1-h)*(1-c*peek*.85);
  this.look.lerp(new T.Vector2(this.pointer.x*pointerWeight+c*peekSide*peek*1.15-h*(.12+1.25*glance),-this.pointer.y*pointerWeight-c*peek*1.15+h*(.1+1.15*glance)),k);
  // Brief full blinks; a second blink follows every other cycle.
  const phase=t%5.1;const pulse=x=>Math.max(0,1-Math.abs(x)/.095);
  const blink=Math.max(pulse(phase-4.2),Math.floor(t/5.1)%2?pulse(phase-4.48):0)*(1-c*surprise);
  for(const e of this.eyes){
   const wide=c*surprise, spread=Math.sign(e.eyeBase.x)*wide*.018;
   e.eye.scale.set(1+wide*.08,(1+wide*.24)*(1-blink*.94),1);
   e.eye.position.copy(e.eyeBase);e.eye.position.x+=spread;
   e.pupil.scale.set(1-wide*.08,(1-wide*.08)*(1-blink*.94),1);
   e.pupil.position.copy(e.base);e.pupil.position.x+=this.look.x*.045+spread;e.pupil.position.y+=this.look.y*.035;
  }
  // Demonstration speech rhythm, not audio-driven lip synchronization.
  const phrase=Math.sin(this.age*1.8)>-.55?1:0;
  const syllable=(.5+.5*Math.sin(t*18)*Math.sin(t*7.1))*phrase;
  // A silent ‘yay!’: open on takeoff, spread into a smile near the
  // top of the jump, and relax as he lands. Preserve room for the tongue.
  const yayOpen=T.MathUtils.smoothstep(bouncePhase,.15,.29)*(1-T.MathUtils.smoothstep(bouncePhase,.47,.76));
  const yaySmile=T.MathUtils.smoothstep(bouncePhase,.28,.48)*(1-T.MathUtils.smoothstep(bouncePhase,.74,1.08));
  this.mouth.scale.y=.25*(1-q*.12+q*syllable*.55-h*.08+c*(.04+.25*surprise)+j*(.30*yayOpen-.08*yaySmile));
  this.mouth.scale.x=.34*(1+q*syllable*.06-c*surprise*.08+j*(.025+.16*yaySmile-.035*yayOpen));
  // Ground contacts are expressed in root space, then transformed back
  // into the moving body's space so the noodles stay planted as he rises.
  this.poseRoot.updateMatrix();
  const groundToBody=this.poseRoot.matrix.clone().invert();
  for(const arm of this.arms){
   const s=arm.sign;const bob=Math.sin(t*2+s)*.035*amplitude;
   const idle=[V(s*.58,0),V(s*1.03,-.13),V(s*1.41,.42+bob),V(s*1.23,.5+bob)];
   // Curl the right noodle up to the cap rim. Follow the face's turn so
   // the tip stays by the hat; scratch in short bursts with a quiet pause.
   const scratchPhase=t%3.2;
   const scratchEnvelope=scratchPhase<1.65?Math.sin(Math.PI*scratchPhase/1.65)**2:0;
   const scratch=Math.sin(t*19)*.055*scratchEnvelope*amplitude;
   const hatTip=V(.30,.74+scratch,.13).applyEuler(this.model.face.rotation);
   const grounded=(x,y,z)=>V(x,y,z).applyMatrix4(groundToBody);
   const curious=[
    V(s*.58,0),V(s*.79,-.22,.04),
    grounded(s*.96,-.42,.09),grounded(s*1.01,-.60,.13),
    grounded(s*1.13,-.645,.17),grounded(s*1.30,-.645,.18)
   ];
   const thinking=s===1
    ?[V(.58,0),V(1.02,.35,.08),V(.79,.99,.1),hatTip]
    :idle;
   const talking=[V(s*.58,0),V(s*1.02,-.04),V(s*1.45,.3+Math.sin(t*4+s)*.12),V(s*1.3,.63+Math.sin(t*4+s)*.14)];
   // The shoulder sways slowly; each successive bend lags behind it.
   // The final two bends add a faster, small wrist/tip flutter.
   const wave=t*6+s*.7, tip=t*17+s*1.8;
   const celebrating=[
    V(s*.58,0),
    V(s*(.85+Math.sin(wave)*.07*amplitude),.37,Math.sin(wave)*.04*amplitude),
    V(s*(1.12+Math.sin(wave-1)*.14*amplitude),.72+Math.cos(wave)*.07*amplitude),
    V(s*(1.24+Math.sin(wave-2)*.18*amplitude),1.04+Math.cos(wave-1)*.1*amplitude,.08),
    V(s*(1.12+Math.sin(wave-2.7)*.16*amplitude+Math.sin(tip)*.07*amplitude),1.30+Math.cos(tip)*.055*amplitude,.08+Math.sin(tip)*.055*amplitude),
    V(s*(.98+Math.sin(wave-3.1)*.16*amplitude+Math.sin(tip-.9)*.12*amplitude),1.39+Math.cos(tip-.9)*.10*amplitude,.08+Math.sin(tip-.9)*.08*amplitude)
   ];
   const base=sixPoints(idle);
   const poses=[[curious,c],[sixPoints(thinking),h],[sixPoints(talking),q],[celebrating,j]];
   for(let n=0;n<6;n++){
    const goal=base[n].clone();
    for(const [pose,w] of poses)goal.addScaledVector(pose[n].clone().sub(base[n]),w);
    arm.points[n].copy(goal);
   }
   // Update existing buffers: no new GPU geometry per animation frame.
   arm.curve.updateArcLengths();
   const frames=arm.curve.computeFrenetFrames(28,false),pos=arm.mesh.geometry.attributes.position,norm=arm.mesh.geometry.attributes.normal;
   for(let segment=0;segment<=28;segment++){
    const p=arm.curve.getPointAt(segment/28),normal=frames.normals[segment],binormal=frames.binormals[segment];
    for(let radial=0;radial<=7;radial++){
     const a=radial/7*Math.PI*2,ns=normal.clone().multiplyScalar(-Math.cos(a)).addScaledVector(binormal,Math.sin(a));const index=segment*8+radial;
     pos.setXYZ(index,p.x+.055*ns.x,p.y+.055*ns.y,p.z+.055*ns.z);norm.setXYZ(index,ns.x,ns.y,ns.z);
    }
   }
   pos.needsUpdate=true;norm.needsUpdate=true;arm.mesh.geometry.computeBoundingSphere();
  }
 }
}
