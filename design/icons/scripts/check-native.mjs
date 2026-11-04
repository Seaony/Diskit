// Copyright (c) 2026 Kubai087. Licensed under the Kubai Icons License; see LICENSE.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRenderer,sharp} from './static-dom.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2),option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1]};
const out=path.resolve(option('--out',path.join(root,'check-out')));fs.mkdirSync(out,{recursive:true});
const manifest=JSON.parse(fs.readFileSync(path.join(root,'manifest.json'),'utf8'));
const render=createRenderer(root);
const chosen=option('--only','').split(',').filter(Boolean);
const references=option('--with','文件夹,邮件,下载').split(',').filter(Boolean);
const types=chosen.length?chosen:Object.keys(manifest.types);
const list=[...new Set([...types,...references])];
const img=(svg,x,y,size)=>`<image x="${x}" y="${y}" width="${size}" height="${size}" href="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}"/>`;
const escaped=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;');
const dark=hex=>'#'+hex.slice(1).match(/../g).map(v=>Math.round(parseInt(v,16)*0.76+255*.24).toString(16).padStart(2,'0')).join('');
async function sheet(file,names,size,darkMode=false,palette) {
 const cols=Math.min(8,names.length),tile=118,row=100,rows=Math.ceil(names.length/cols),w=cols*tile+24,h=rows*row+24;
 let svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="100%" height="100%" fill="${darkMode?'#1D2026':'#F5F6F9'}"/>`;
 for(let index=0;index<names.length;index++) {
  const name=names[index],x=12+index%cols*tile,y=12+Math.floor(index/cols)*row;
  let accent=option('--accent',manifest.colors[manifest.types[name] || 'blue']);if(darkMode)accent=dark(accent);
  if(palette)accent=palette[1];
  const icon=render(name,accent,size,0,palette?.[0] || '彩色');
  if(/undefined|NaN|<script|https?:\/\/(?!www\.w3\.org)/.test(icon))throw Error('非法静态图标 '+name);
  await sharp(Buffer.from(icon)).resize(size,size).png().toBuffer();
  svg+=`<rect x="${x+3}" y="${y+3}" width="106" height="88" rx="12" fill="${darkMode?'#292D35':'#FFFFFF'}"/>`+img(icon,x+(112-size)/2,y+8,size)+`<text x="${x+56}" y="${y+83}" text-anchor="middle" font-family="Helvetica" font-size="10" fill="${darkMode?'#D7DEEB':'#44516A'}">${escaped(name)}</text>`;
 }
 svg+='</svg>';fs.writeFileSync(path.join(out,file+'.svg'),svg);await sharp(Buffer.from(svg)).png().toFile(path.join(out,file+'.png'));
}
await sheet('rest',list,56);await sheet('size-24',list,24);await sheet('size-28',list,28);
await sheet('rest-dark',list,56,true);
const palettes=[['蓝灰','#6F87B5'],['青瓷','#5BA3A8'],['薄荷','#5FAE8A'],['薰衣草','#8C83C6'],['杏色','#C9946A'],['黑色','#2E3036']];
for(const [index,palette] of palettes.entries()) await sheet('palette-'+index,list,28,false,palette);
await sheet('light-accent',list,28,false,['彩色','#F59E0B']);
for(const darkMode of [false,true]) {
 const names=types.filter(n=>n!=='emptyLink'),cols=7,tile=132,w=cols*tile+32,rows=Math.ceil(names.length/cols),h=rows*100+162;
 let svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="100%" height="100%" fill="${darkMode?'#1D2026':'#F5F6F9'}"/>`;
 names.forEach((name,i)=>{
  const x=16+i%cols*tile,y=12+Math.floor(i/cols)*100,accent=manifest.colors[manifest.types[name]];
  svg+=img(render(name,darkMode?dark(accent):accent,56),x+35,y,56)+`<text x="${x+63}" y="${y+77}" text-anchor="middle" font-family="Helvetica" font-size="11" fill="${darkMode?'#D7DEEB':'#44516A'}">${name}</text>`;
 });
 Object.entries(manifest.colors).forEach(([name,accent],i)=>{
  const x=20+i*(w-40)/8,y=rows*100+36;
  svg+=img(render('googleDrive',darkMode?dark(accent):accent,48),x+22,y,48)+`<text x="${x+46}" y="${y+71}" text-anchor="middle" font-family="Helvetica" font-size="11" fill="${darkMode?'#D7DEEB':'#44516A'}">${name}</text>`;
 });
 svg+='</svg>';const file='overview-'+(darkMode?'dark':'light');fs.writeFileSync(path.join(out,file+'.svg'),svg);await sharp(Buffer.from(svg)).png().toFile(path.join(out,file+'.png'));
}
fs.writeFileSync(path.join(out,'checks.json'),JSON.stringify({mode:'native-static-engine',types:types.length,references,checkedSizes:[24,28,56],palettes:['彩色',...palettes.map(p=>p[0])],lightAccent:'#F59E0B',errors:[]},null,2)+'\n');
console.log(`${types.length} 个原创图标及 ${references.length} 个参考图标静态检查通过；输出 ${out}`);
