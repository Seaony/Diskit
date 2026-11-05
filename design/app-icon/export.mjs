import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {sharp,createTint} from '../icons/scripts/static-dom.mjs';
const root=path.dirname(fileURLToPath(import.meta.url)),repo=path.resolve(root,'../..');
const tint=createTint(path.join(repo,'design/icons'));
const c=source=>tint(source,'#427FE5');
const defs=`<defs><linearGradient id="plate" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${c('#639EFF')}"/><stop offset="1" stop-color="${c('#2F6FE0')}"/></linearGradient><linearGradient id="front" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${c('#CCDFFF')}"/><stop offset="1" stop-color="${c('#ADCBFF')}"/></linearGradient><filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="22" stdDeviation="22" flood-color="${c('#244C90')}" flood-opacity=".25"/></filter></defs>`;
const plate=`<rect x="100" y="100" width="824" height="824" rx="184" fill="url(#plate)" filter="url(#shadow)"/>`;
const designs={
 '01-roundtrip':`<path d="M279 300H605V242L756 352L605 462V404H279Q258 404 258 383V321Q258 300 279 300Z" fill="#FFFFFF"/><path d="M745 620H419V562L268 672L419 782V724H745Q766 724 766 703V641Q766 620 745 620Z" fill="url(#front)"/>`,
 '02-devices':`<rect x="234" y="274" width="468" height="322" rx="35" fill="url(#front)"/><rect x="266" y="306" width="404" height="230" rx="16" fill="#FFFFFF"/><path d="M416 594H524V665H416Z" fill="${c('#B2CEFF')}"/><rect x="340" y="650" width="260" height="48" rx="24" fill="#FFFFFF"/><rect x="602" y="462" width="176" height="306" rx="37" fill="${c('#2857A5')}"/><rect x="619" y="479" width="142" height="272" rx="26" fill="url(#front)"/><rect x="637" y="504" width="106" height="174" rx="9" fill="#FFFFFF"/><path d="M389 372H520V338L581 395L520 452V418H389Z" fill="${c('#5393FF')}"/><rect x="665" y="708" width="49" height="14" rx="7" fill="${c('#2F6FE0')}"/>`,
 '03-folder':`<path d="M237 300Q237 267 270 267H435L492 328H757Q789 328 789 360V718Q789 750 757 750H269Q237 750 237 718Z" fill="${c('#93BBFF')}"/><rect x="304" y="360" width="418" height="250" rx="21" fill="#FFFFFF"/><path d="M237 447Q237 416 268 416H756Q789 416 789 449V718Q789 750 756 750H269Q237 750 237 718Z" fill="url(#front)"/><path d="M341 490H568V452L651 527L568 602V564H341Z" fill="${c('#2F6FE0')}"/><path d="M683 621H456V583L373 658L456 733V695H683Z" fill="${c('#5393FF')}"/>`
};
for(const [name,body] of Object.entries(designs)) fs.writeFileSync(path.join(root,name+'.svg'),`<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">${defs}${plate}${body}</svg>\n`);
// AppIcon 改用小花怪兽，由 export-turtle.swift 导出；这里只生成早期草案和对照图
const out=path.join(repo,'docs/screenshots/v0.2/icons');fs.mkdirSync(out,{recursive:true});
for(const dark of [false,true]){
 const width=1656,height=850;
 let sheet=`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"><rect width="100%" height="100%" fill="${dark?'#1D2026':'#F5F6F9'}"/>`;
 Object.keys(designs).forEach((name,column)=>{
  const source=fs.readFileSync(path.join(root,name+'.svg')).toString('base64'),cx=column*552+276;
  sheet+=`<text x="${cx}" y="33" text-anchor="middle" font-family="Helvetica" font-size="18" fill="${dark?'#E0E6EF':'#28364F'}">${name}</text>`;
  let y=58;
  for(const size of [16,32,128,512]) {
   sheet+=`<image href="data:image/svg+xml;base64,${source}" x="${cx-size/2}" y="${y}" width="${size}" height="${size}"/>`;
   y+=size+18;
  }
 });
 sheet+='</svg>';await sharp(Buffer.from(sheet)).png().toFile(path.join(out,`app-directions-${dark?'dark':'light'}.png`));
}
console.log('应用图标三个早期方向的草案和对照图已导出。');
