import * as T from './vendor/three.module.js';
// Keep every interior fragment inside the opening, including during a head turn.
// Coordinates are in face space, so the mask follows the same face transform.
export function createMouthRig(crumb,toon){
 const mouth=crumb.mouth,face=crumb.model.face;
 // A clean opening layered over the breadcrumb surface prevents pieces of
 // body/crumb geometry showing through the mouth as its shape changes.
 mouth.geometry.dispose();mouth.geometry=new T.CircleGeometry(1,64);
 mouth.position.z=.718;
 mouth.material.depthTest=false;mouth.material.depthWrite=false;mouth.renderOrder=10;
 const bounds={value:new T.Vector4(0,-.22,.34,.25)};
 const teeth=face.children.filter(o=>o.name==='crumbTooth');
 const tongue=face.getObjectByName('crumbTongue');
 for(const mesh of [...teeth,tongue]){
  mesh.material.depthTest=false;mesh.material.depthWrite=false;mesh.renderOrder=11;
  mesh.material.onBeforeCompile=shader=>{
   shader.uniforms.crumbMouth=bounds;
   shader.vertexShader='varying vec2 crumbFaceXY;\n'+shader.vertexShader;
   // Object-local vertices become face-local coordinates with the object's matrix.
   shader.uniforms.crumbLocal={value:mesh.matrix};
   shader.vertexShader='uniform mat4 crumbLocal;\n'+shader.vertexShader;
   shader.vertexShader=shader.vertexShader.replace('#include <begin_vertex>','#include <begin_vertex>\ncrumbFaceXY=(crumbLocal * vec4(position,1.0)).xy;');
   shader.fragmentShader='uniform vec4 crumbMouth; varying vec2 crumbFaceXY;\n'+shader.fragmentShader;
   shader.fragmentShader=shader.fragmentShader.replace('#include <clipping_planes_fragment>','#include <clipping_planes_fragment>\nvec2 mouthUV=(crumbFaceXY-crumbMouth.xy)/crumbMouth.zw; if(dot(mouthUV,mouthUV)>0.93) discard;');
  };
  mesh.material.customProgramCacheKey=()=> 'crumb-mouth-mask-v1';
 }
 return {
  update(volume=null){
   mouth.scale.x*=.9;
   mouth.scale.y*=.86;
   if(volume!==null){
    const voice=T.MathUtils.clamp((volume-.035)/.965,0,1);
    mouth.scale.x=.285+voice*.04;
    mouth.scale.y=.055+Math.pow(voice,.8)*.225;
   }
   const w=mouth.scale.x,h=mouth.scale.y;
   bounds.value.set(mouth.position.x,mouth.position.y,w,h);
   for(const tooth of teeth){
    const roof=mouth.position.y+h*Math.sqrt(Math.max(0,1-(tooth.position.x/w)**2));
    tooth.scale.y=Math.min(1,h/.15);
    tooth.position.y=roof-.085*tooth.scale.y+.012;
    tooth.updateMatrix();
   }
   tongue.scale.set(Math.min(.12,w*.38),Math.min(.065,h*.28),.022);
   tongue.position.set(.025,mouth.position.y-h*.61,.701);
   tongue.updateMatrix();
  }
 };
}
