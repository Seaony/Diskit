// Copyright (c) 2026 Kubai087. Licensed under the Kubai Icons License; see LICENSE.
// 原生静态导出适配器：为未修改的图标引擎提供最小 SVG DOM。
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
const bundled = process.env.DISKIT_NODE_MODULES || path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules');
const require = createRequire(path.join(bundled, 'package.json'));
const xml = require('xml-js');
export const sharp = require('sharp');

const escape = (s) => String(s).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
class Element {
  constructor(tag, attrs = {}, children = []) { this.tagName = tag; this.attrs = {...attrs}; this.children = children; }
  setAttribute(name, value) { this.attrs[name] = String(value); }
  getAttribute(name) { return this.attrs[name] ?? null; }
  removeAttribute(name) { delete this.attrs[name]; }
  get attributes() { return Object.entries(this.attrs).map(([name,value]) => ({name,value})); }
  get dataset() { return Object.fromEntries(Object.entries(this.attrs).filter(([k]) => k.startsWith('data-')).map(([k,v]) => [k.slice(5).replace(/-([a-z])/g,(_,c)=>c.toUpperCase()),v])); }
  get id() { return this.attrs.id; }
  set id(value) { this.attrs.id = value; }
  appendChild(child) { this.children.push(child); return child; }
  set innerHTML(source) { this.children = parse(source); }
  get innerHTML() { return this.children.map((e)=>e.outerHTML ?? escape(e.text)).join(''); }
  get outerHTML() { return `<${this.tagName}${Object.entries(this.attrs).map(([k,v])=>` ${k}="${escape(v)}"`).join('')}>${this.innerHTML}</${this.tagName}>`; }
  querySelectorAll(selector) {
    const selectors = selector.split(',').map(s=>s.trim());
    const matches = (el,s) => s === '*' || (s.startsWith('.') ? (el.attrs.class || '').split(' ').includes(s.slice(1)) : s.startsWith('[') ? Object.hasOwn(el.attrs,s.slice(1,-1)) : el.tagName === s);
    const result=[];
    for (const child of this.children) if(child instanceof Element) {
      if(selectors.some(s=>matches(child,s))) result.push(child);
      result.push(...child.querySelectorAll(selector));
    }
    return result;
  }
  querySelector(s) { return this.querySelectorAll(s)[0] ?? null; }
}
function parse(source) {
  const normalized = source.replace(/\s(data-[\w-]+)(?=\s|>)/g, ' $1=""');
  const doc = xml.xml2js(`<root>${normalized}</root>`, {compact:false});
  const convert = (node) => node.type === 'element' ? new Element(node.name,node.attributes,(node.elements || []).filter(n=>n.type==='element'||n.type==='text').map(convert)) : {text:node.text};
  return (doc.elements[0].elements || []).filter(n=>n.type==='element'||n.type==='text').map(convert);
}
export function createRenderer(root) {
  const context = vm.createContext({ console, document:{createElementNS:(_,tag)=>new Element(tag)}, matchMedia:()=>({matches:true}), performance, setTimeout,clearTimeout });
  vm.runInContext(fs.readFileSync(path.join(root,'src/engine.js'),'utf8')+'\n'+fs.readFileSync(path.join(root,'src/icons.js'),'utf8'),context);
  return (name,accent,size=96,pad=0,palette="彩色")=>{
    context.host=new Element('span');context.iconName=name;context.accent=accent;context.paletteName=palette;
    vm.runInContext(`runtime.palette=paletteName==="彩色"?{colors:[accent]}:paletteName==="黑色"?flatTone(paletteName,accent,1):clearTone(paletteName,accent,1); var icon=ICONS.find(x=>x.name===iconName); if(!icon)throw Error(iconName); var inst=mountIcon(icon,0,host);`,context);
    const svg=context.host.querySelector('svg');
    // CoreSVG 不支持 feMerge，用相同顺序的 over 合成保留投影。
    for(const filter of svg.querySelectorAll('filter')) {
      if(!filter.querySelector('feMerge')) continue;
      filter.querySelector('[data-sh]').setAttribute('result','diskit-shadow');
      filter.children=filter.children.map(child=>child.tagName==='feMerge'?new Element('feComposite',{in:'SourceGraphic',in2:'diskit-shadow',operator:'over'}):child);
    }
    for(const el of svg.querySelectorAll('.ol, .ln')) {
      const outline=(el.attrs.class || '').split(' ').includes('ol');
      el.setAttribute('fill','none');el.setAttribute('stroke-width',outline?2:(el.getAttribute('stroke-width')||1.6));
      el.setAttribute('stroke-linecap','round');el.removeAttribute('class');
    }
    for(const el of svg.querySelectorAll('*')) for(const {name} of el.attributes) if(name.startsWith('data-'))el.removeAttribute(name);
    const side=31+pad*2;
    svg.removeAttribute('aria-hidden');svg.setAttribute('xmlns','http://www.w3.org/2000/svg');svg.setAttribute('viewBox',`${15.5-side/2} ${12.5-side/2} ${side} ${side}`);svg.setAttribute('width',size);svg.setAttribute('height',size);
    const prefix=`diskit-${name}-`;
    return svg.outerHTML.replace(/(id="|url\(#)([^"\)]+)/g,(_,p,id)=>p+prefix+id)+'\n';
  };
}

export function createTint(root) {
  const context = vm.createContext({matchMedia:()=>({matches:true})});
  vm.runInContext(fs.readFileSync(path.join(root,'src/engine.js'),'utf8'),context);
  return (source,accent)=>{context.source=source;context.accent=accent;return vm.runInContext('tint(source,rgb(accent))',context)};
}
