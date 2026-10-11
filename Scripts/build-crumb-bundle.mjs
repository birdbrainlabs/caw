// Bundles Crumb's page (VoiceApp/Resources/Crumb/mascot.js) into crumb.bundle.js,
// Run after editing mascot.js:
//   node Scripts/build-crumb-bundle.mjs [path/to/esbuild/package]
// esbuild is a build tool only; nothing from it ships in the app.
import {createRequire} from 'node:module';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const crumb=join(root,'VoiceApp/Resources/Crumb');
const require=createRequire(import.meta.url);
// esbuild comes from: the path given as the first argument, else $ESBUILD,
// else a normal install (npm install --no-save esbuild in the repo root).
const esbuildPath=process.argv[2]||process.env.ESBUILD||'esbuild';
let esbuild;
try{esbuild=require(esbuildPath);}catch{
 console.error(`Can't load esbuild from "${esbuildPath}". Run "npm install --no-save esbuild" in the repo root, or pass the esbuild package folder as the first argument (or set ESBUILD=/path/to/node_modules/esbuild).`);
 process.exit(1);
}
const three=join(crumb,'source/vendor/three.module.js');
await esbuild.build({
 entryPoints:[join(crumb,'mascot.js')],outfile:join(crumb,'crumb.bundle.js'),
 bundle:true,minify:true,format:'iife',legalComments:'inline',target:'safari17',logLevel:'info',
 plugins:[{name:'one-three',setup(b){b.onResolve({filter:/vendor\/three\.module\.js$/},()=>({path:three}));}}],
});
