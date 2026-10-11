// Presentation only. Never changes velocity, collisions, rope timing or gravity.
const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x));
export class JuiceMotion{
 constructor(){this.reset();}
 reset(){this.age=10;this.strength=0;this.tug=0;this.excitement=0;this.shake=0;}
 land(speed){if(speed<3)return;const strength=clamp(speed/24,.18,1);if(this.age<.12&&strength<this.strength)return;this.age=0;this.strength=strength;this.shake=Math.max(this.shake,strength);}
 grab(){this.tug=1;this.excitement=Math.max(this.excitement,.45);}
 release(){this.tug=Math.max(this.tug,.45);}
 cheer(strength=1){this.excitement=Math.max(this.excitement,clamp(strength));}
 update(dt){this.age+=dt;this.tug*=Math.exp(-13*dt);this.excitement*=Math.exp(-5*dt);this.shake*=Math.exp(-18*dt);}
 pose({grounded=false,speed=0}={}){
  const t=this.age;
  // Compress over 45ms, then spring up once and settle by 400ms.
  const squash=t<.045?t/.045:t<.16?1-(t-.045)/.115:t<.4?-.22*Math.sin((t-.16)/.24*Math.PI):0;
  const y=1-.56*this.strength*squash;
  const width=1/Math.sqrt(y),stretch=grounded?0:clamp(speed/60)*.06;
  return {x:width*(1+this.tug*.055),y:y*(1+stretch),z:width/(1+stretch),offsetY:grounded?-.7*(1-y):0,excitement:this.excitement};
 }
}
