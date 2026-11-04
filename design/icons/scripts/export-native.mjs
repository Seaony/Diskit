// Copyright (c) 2026 Kubai087. Licensed under the Kubai Icons License; see LICENSE.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRenderer} from './static-dom.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const repo=path.resolve(root,'../..');
const args=process.argv.slice(2);
const option=(name,fallback)=>{const at=args.indexOf(name);return at<0?fallback:args[at+1]};
const manifest=JSON.parse(fs.readFileSync(path.join(root,'manifest.json'),'utf8'));
const render=createRenderer(root);
const dark=(hex)=>'#'+hex.slice(1).match(/../g).map(v=>Math.round(parseInt(v,16)*0.76+255*0.24).toString(16).padStart(2,'0')).join('').toUpperCase();
if(args.includes('--assets')) {
  let count=0;
  for(const name of Object.keys(manifest.types)) for(const [color,accent] of Object.entries(manifest.colors)) {
    const set=path.join(repo,'App/Assets.xcassets',`TypeIcon-${name}-${color}.imageset`);
    fs.mkdirSync(set,{recursive:true});
    fs.writeFileSync(path.join(set,'light.svg'),render(name,accent));
    fs.writeFileSync(path.join(set,'dark.svg'),render(name,dark(accent)));
    fs.writeFileSync(path.join(set,'Contents.json'),JSON.stringify({images:[{filename:'light.svg',idiom:'universal'},{filename:'dark.svg',idiom:'universal',appearances:[{appearance:'luminosity',value:'dark'}]}],info:{author:'xcode',version:1},properties:{'preserves-vector-representation':true}},null,2)+'\n');
    count++;
  }
  console.log(`已导出 ${count} 个图像集，每组含浅色和深色 SVG。`);
} else {
  const only=option('--only','').split(',').filter(Boolean);
  const out=path.resolve(option('--out',path.join(root,'export')));
  fs.mkdirSync(out,{recursive:true});
  for(const name of only.length?only:Object.keys(manifest.types)) {
    const accent=option('--accent',manifest.colors[manifest.types[name] || 'blue']);
    fs.writeFileSync(path.join(out,name+'.svg'),render(name,accent,Number(option('--size',96)),Number(option('--pad',0)),option('--palette','彩色')));
  }
  console.log(`静态 SVG 已导出到 ${out}`);
}
