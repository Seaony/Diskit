// Copyright (c) 2026 Kubai087. Licensed under the Kubai Icons License; see LICENSE.
// The icon set. Each entry: svg(u) builds the layers, target(hover, state) returns the
// numbers for rest or hover, draw(p, E) writes the interpolated numbers back. A contributed
// icon also names its designer's GitHub handle in `by`.

// ---------- Icons ----------
// Fills: u.lo(h) / u.up(h) carry the thin bottom band. Use them only on a flat-bottomed
// rectangle of height h whose bottom is clear: nothing within about 3 units of the edge
// and the piece itself not short. Everything else, and curved shapes, use u.loS / u.upS.
// Marks: on a mid-tone (back) body they are white; on a light (front) body or white
// content they take the deep tint; a supporting object laid over the subject (the
// lens) is deep so it reads as separate. Weights: content lines 1.6, glyphs 2.2.
const OL = 'class="ol" data-t="stroke:#5393FF"';
const LINE = 'class="ln" data-t="stroke:#D3E2FC"';
const ACC = 'class="ln" data-t="stroke:#5393FF"';
const DEEP = 'data-t="fill:#2F6FE0"';
const DEEPS = 'data-t="stroke:#2F6FE0"';
const FOLDER_BACK_R = [KR, 1.4, 1.4, KR, KR, KR];
// Keylines (fills; outside strokes add 1 all round), all centred on (15.5, 12.5) and scaled from the folder's 23-wide body
// (Material's 20 / 18 / 20×16 grid × 1.15): circle Ø23, square 20.6, landscape 23×18.4,
// portrait 18.4×23. Outlines sit 1 unit outside a shape; a coloured band around white
// content keeps 2+ units or is dropped so the content meets the edge.
const TRASH_LID = rp([[5.4, 6.6], [5.4, 4], [12.4, 4], [12.4, 1.6], [18.6, 1.6], [18.6, 4], [25.6, 4], [25.6, 6.6]], [1, 1, 0.5, 0.8, 0.8, 0.5, 1, 1]);
const GEAR = gear(6, 11.4, 9);
  const MAIL_T = 3.3;
const today = new Date();
const tomorrow = new Date(today.getTime() + 86400000);

// A capsule ring centred on the origin: outer w×h, wall t (fill-rule evenodd).
const capsuleRing = (w, h, t) => rr(-w / 2, -h / 2, w, h, h / 2) + rr(-w / 2 + t, -h / 2 + t, w - 2 * t, h - 2 * t, (h - 2 * t) / 2);
const LINK_RING = capsuleRing(15.6, 9.6, 2.8);
// An arc of radius r round the origin from angle a0 to a1 (degrees, clockwise), and a
// solid arrowhead whose base covers the arc's end. Strokes never overlap one another,
// so the head stays crisp instead of clotting where strokes would cross.
function arcArrow(a0, a1, r) {
  const rad = (d) => d * Math.PI / 180;
  const pt = (a) => [r * Math.cos(rad(a)), r * Math.sin(rad(a))];
  const s = pt(a0), e = pt(a1);
  const t = [-Math.sin(rad(a1)), Math.cos(rad(a1))], n = [Math.cos(rad(a1)), Math.sin(rad(a1))];
  const tip = [e[0] + t[0] * 3, e[1] + t[1] * 3];
  const head = rp([[e[0] + n[0] * 2.5, e[1] + n[1] * 2.5], tip, [e[0] - n[0] * 2.5, e[1] - n[1] * 2.5]], 0.5);
  return { arc: `M${f(s[0])} ${f(s[1])}A${r} ${r} 0 0 1 ${f(e[0])} ${f(e[1])}`, head };
}
// Each arrow's tip stops well short of the other arc's tail.
const SYNC_A = arcArrow(215, 300, 4.4), SYNC_B = arcArrow(35, 120, 4.4);
const SHORTCUT_TILES = [[7.2, 4.2], [16.5, 4.2], [7.2, 13.5], [16.5, 13.5]];

const ICONS = [
  {
    name: '文件夹',
    svg: (u) => `
      <g filter="${u.sh}"><path data-n="back" fill="${u.lo(21)}"/></g>
      <path data-n="backO" ${OL}/>
      <g data-n="file"><path d="${rr(0, 0, 17, 9, 1)}" fill="#fff"/><path d="M5.5 2.3H11.5" ${LINE} stroke-width="1"/></g>
      <g filter="${u.hi}"><path data-n="front" fill="${u.up(18)}"/></g>
      <path data-n="frontO" ${OL}/>`,
    target: (h) => ({
      back: h ? [[4, 3], [11.2, 3], [14.2, 6], [27, 6], [27.6, 23], [4.6, 23]] : [[4, 2], [11.2, 2], [14.2, 5], [27, 5], [27, 23], [4, 23]],
      fx: h ? 7.9 : 7,
      front: h ? [[6.8, 13], [29.3, 13], [27.6, 23], [5.4, 23]] : [[4, 5], [27, 5], [27, 23], [4, 23]],
      fr: h ? 1.8 : KR
    }),
    draw(p, E) {
      const b = rp(p.back, FOLDER_BACK_R), fr = rp(p.front, p.fr);
      at(E.back, { d: b }); at(E.backO, { d: b });
      at(E.file, { transform: `translate(${f(p.fx)} 9)` });
      at(E.front, { d: fr }); at(E.frontO, { d: fr });
    }
  },
  {
    name: '搜索',
    // The page is the subject; the lens is a supporting mark on its corner, a solid
    // ring with no inner outline so it never leaves a thin band.
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${rr(4, 1, 16.8, 20.2, KR)}" fill="${u.lo(20.2)}"/></g></g>
      <path d="${rr(4, 1, 16.8, 20.2, KR)}" ${OL}/>
      <path d="${lines(7.4, 4.8, [10, 6.6])}" class="ln" stroke="#fff" data-w="stroke"/>
      <g filter="${u.hi}"><path d="${rp(R(4, 10.8, 16.8, 10.4), [1.6, 1.6, KR, KR])}" fill="${u.upS}"/></g>
      <path d="${rp(R(4, 10.8, 16.8, 10.4), [1.6, 1.6, KR, KR])}" ${OL}/>
      <g data-n="lens" filter="${u.sh}">
        <circle r="3.6" fill="#fff" fill-opacity=".8"/>
        <circle r="3.6" fill="${u.upS}" fill-opacity=".35"/>
        <circle r="4.5" fill="none" stroke-width="1.8" data-t="stroke:#2F6FE0"/>
        <path d="M3.8 3.8L6.6 6.6" stroke-width="2.2" stroke-linecap="round" data-t="stroke:#2F6FE0"/>
      </g>`,
    target: (h) => ({ lens: h ? [13.2, 10.4, 1.05] : [19.8, 16.8, 1] }),
    draw(p, E) {
      const [x, y, s] = p.lens;
      at(E.lens, { transform: `translate(${f(x)} ${f(y)}) scale(${f(s)})` });
    }
  },
  {
    name: '邮件',
    svg: (u) => {
      const T = MAIL_T;
      const body = rr(4, T, 23, 18.4, KR);
      const pocket = rp([[4, T + 3.8], [15.5, T + 10.4], [27, T + 3.8], [27, T + 18.4], [4, T + 18.4]], [0.6, 2.4, 0.6, KR, KR]);
      const B = T + 18.4;
      return `
      <g filter="${u.sh}"><path d="${body}" fill="${u.lo(18.4)}"/></g>
      <path d="${body}" ${OL}/>
      <g data-n="inG"><path data-n="inF" fill="${u.loS}"/><path data-n="inO" ${OL}/></g>
      <g data-n="letter"><path d="${rr(7, 0, 17, 12, CR)}" fill="#fff"/><path d="${lines(9.8, 3.6, [7])}" ${ACC}/><path d="${lines(9.8, 6.8, [11.4])}" ${LINE}/></g>
      <path d="${pocket}" fill="${u.up(15.6)}"/>
      <g data-n="outG"><g filter="${u.hi}"><path data-n="outF" fill="${u.loS}"/></g><path data-n="outO" ${OL}/></g>`;
    },
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      // The flap is the back sheet folded over, so it takes the back's mid tone; the pocket
      // is the lighter front. The flap shares the body's top corners and its lower edges lie on the pocket's V;
      // turning it scales its height about the top edge from 1 to -0.7. The letter rises after.
      const T = MAIL_T;
      const o = Math.max(0, Math.min(1, p.o));
      const k = 1 + (-0.7 - 1) * Math.min(1, o / 0.55);
      const rise = Math.max(0, Math.min(1, (o - 0.35) / 0.65));
      // Closed it is a pentagon sharing the body's top corners. Open, its fold drops to where
      // the body's sides turn straight and its base corners square off, so the body's side
      // outline runs straight up into the flap's and the body's rounded top hides behind it.
      let d;
      if (k >= 0) {
        d = rp([[4, T], [27, T], [27, T + 3.8 * k], [15.5, T + 10.4 * k], [4, T + 3.8 * k]], [KR, KR, 0.6, 2.4, 0.6], true);
      } else {
        const q = Math.min(1, -k / 0.3), fold = T + KR * q, cr = KR * (1 - q);
        d = rp([[4, fold], [27, fold], [27, T], [15.5, T + 10.4 * k], [4, T]], [cr, cr, 0.8, 2.4, 0.8], true);
      }
      const down = k >= 0;
      at(E.outF, { d }); at(E.outO, { d }); at(E.outG, { opacity: down ? 1 : 0 });
      at(E.inF, { d }); at(E.inO, { d }); at(E.inG, { opacity: down ? 0 : 1 });
      at(E.letter, { transform: `translate(0 ${f(T + 5 + (-6.5) * rise)})` });
    }
  },
  {
    name: '日历',
    svg: (u) => {
      const body = rr(5.2, 3.4, 20.6, 19.4, KR);
      const sheet = rp(R(8.2, 9, 14.6, 10.8), [0, 0, CR, CR]);
      const head = rp(R(5.2, 3.4, 20.6, 5.6), [KR, KR, 0, 0]);
      const ring = rr(10.4, 1.6, 1.8, 3.8, 0.9) + rr(18.8, 1.6, 1.8, 3.8, 0.9);
      return `
      <g filter="${u.sh}"><path d="${body}" fill="${u.loS}"/></g>
      <path d="${sheet}" fill="#fff"/>
      <text x="15.5" y="17.4" text-anchor="middle" font-size="8.4" font-weight="700" data-t="fill:#81B0FF">${tomorrow.getDate()}</text>
      <g data-n="sheet"><path d="${sheet}" fill="#fff"/>
        <text x="15.5" y="17.4" text-anchor="middle" font-size="8.4" font-weight="700" data-t="fill:#4389FF">${today.getDate()}</text>
        <path data-n="shade" d="${sheet}" data-t="fill:#4389FF" opacity="0"/></g>
      <path d="${body}" ${OL}/>
      <g filter="${u.hi}"><path d="${head}" fill="${u.upS}"/></g>
      <path d="${head}" ${OL}/>
      <g data-n="rings"><path d="${ring}" fill="#fff"/><path d="${ring}" ${OL}/></g>`;
    },
    target: (h) => ({ o: h ? 1 : 0, rings: h ? -0.6 : 0 }),
    draw(p, E) {
      // Today's page turns up under the header: it foreshortens toward its top edge and
      // darkens as it faces away, uncovering tomorrow.
      const o = Math.max(0, Math.min(1, p.o));
      const sy = Math.cos(o * Math.PI / 2);
      at(E.sheet, { transform: `translate(0 9) scale(1 ${f(Math.max(0.001, sy))}) translate(0 -9)`, opacity: o > 0.985 ? 0 : 1 });
      at(E.shade, { opacity: f(0.45 * Math.sin(o * Math.PI / 2)) });
      at(E.rings, { transform: `translate(0 ${f(p.rings)})` });
    }
  },
  {
    name: '照片',
    // Two prints, one behind the other: on hover the back one fans out to the left and
    // the front one tilts, like leafing through an album.
    svg: (u) => {
      const frame = rr(4, 5.6, 23, 16.1, KR), back = rr(6, 3.3, 19, 15, KR);
      return `
      <g data-n="back"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${back}" fill="${u.lo(15)}"/></g></g><path d="${back}" ${OL}/></g>
      <g data-n="front">
        <clipPath id="${u.id('sky')}"><path d="${frame}"/></clipPath>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${frame}" fill="${u.upS}"/></g></g>
        <g clip-path="url(#${u.id('sky')})">
          <circle cx="20.4" cy="9.8" r="2.5" fill="#fff"/>
          <path d="${rp([[-1, 23], [-1, 20.2], [10.6, 10.8], [23, 20.8], [23, 23]], [0, 0, 1.8, 0, 0])}" fill="${u.loS}"/>
          <path d="${rp([[8, 23], [8, 21.4], [19.8, 13.2], [32, 20.8], [32, 23]], [0, 0, 1.8, 0, 0])}" fill="${u.pure('#5393FF')}"/>
        </g>
        <path d="${frame}" ${OL}/>
      </g>`;
    },
    target: (h) => ({ back: h ? [-1.4, -1.2, -9] : [0, 0, 0], front: h ? [0.6, 0.2, 4] : [0, 0, 0] }),
    draw(p, E) {
      at(E.back, { transform: `translate(${f(p.back[0])} ${f(p.back[1])}) rotate(${f(p.back[2])} 15.5 21.7)` });
      at(E.front, { transform: `translate(${f(p.front[0])} ${f(p.front[1])}) rotate(${f(p.front[2])} 15.5 21.7)` });
    }
  },
  {
    name: '上传',
    // Back: the cloud. Front: a lighter section cut from its lower part, like the
    // folder's front panel. The arrow sits clear above the front and lifts on hover.
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path data-n="cloud" fill="${u.loS}"/></g></g>
      <path data-n="cloudO" ${OL}/>
      <path data-n="arrow" fill="none" stroke="#fff" data-w="stroke" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
      <g filter="${u.hi}"><path data-n="front" fill="${u.upS}"/></g>
      <path data-n="frontO" ${OL}/>`,
    target: (h) => ({
      L: [9.2, 15.8, h ? 6.3 : 6], T: [15.8, 9.6, h ? 8.4 : 8], Rc: [22.2, 16.2, h ? 5.9 : 5.6],
      tip: h ? 4.8 : 6.4,
      chord: h ? 17.6 : 16.8
    }),
    draw(p, E) {
      const d = cloud(p.L, p.T, p.Rc);
      at(E.cloud, { d }); at(E.cloudO, { d });
      const t = p.tip;
      at(E.arrow, { d: `M15.5 ${f(t + 7.6)}V${f(t)}M12.1 ${f(t + 3.4)}L15.5 ${f(t)}L18.9 ${f(t + 3.4)}` });
      const fr = frontPiece(p.L, p.Rc, p.chord, 2);
      at(E.front, { d: fr }); at(E.frontO, { d: fr });
    }
  },
  {
    name: '下载',
    // Back: the disc. Front: a lighter lower segment. The arrow follows the front down
    // on hover and always stays clear of it.
    svg: (u) => {
      const r = 11.5;
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, r)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, r)}" ${OL}/>
      <path data-n="arrow" fill="none" stroke="#fff" data-w="stroke" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
      <g filter="${u.hi}"><path data-n="seg" fill="${u.upS}"/></g>
      <path data-n="segO" ${OL}/>`;
    },
    target: (h) => ({ tip: h ? 13.4 : 12.4, chord: h ? 16.6 : 15.6 }),
    draw(p, E) {
      const t = p.tip;
      at(E.arrow, { d: `M15.5 ${f(t - 9.4)}V${f(t)}M11.9 ${f(t - 3.6)}L15.5 ${f(t)}L19.1 ${f(t - 3.6)}` });
      const disc = [15.5, 12.5, 11.5];
      const seg = frontPiece(disc, disc, p.chord, 2);
      at(E.seg, { d: seg }); at(E.segO, { d: seg });
    }
  },
  {
    name: '书签',
    tap: true,
    // A coloured card with a white ribbon, as the folder carries its white file;
    // saving turns the ribbon deep and adds a star.
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${rr(6.3, 1.5, 18.4, 22, KR)}" fill="${u.lo(22)}"/></g></g>
      <path d="${rr(6.3, 1.5, 18.4, 22, KR)}" ${OL}/>
      <path data-n="rib" fill="#fff"/>
      <path data-n="ribF" fill="${u.pure('#2F6FE0')}"/>
      <path data-n="star" d="${star(2.3, 1.05)}" fill="#fff"/>
      <g filter="${u.hi}"><path d="${rp(R(6.3, 17.4, 18.4, 6.1), [1.6, 1.6, KR, KR])}" fill="${u.upS}"/></g>
      <path d="${rp(R(6.3, 17.4, 18.4, 6.1), [1.6, 1.6, KR, KR])}" ${OL}/>`,
    target: (h, s) => ({ yb: s.saved ? (h ? 16.2 : 15.2) : (h ? 14.2 : 12.2), fo: s.saved ? 1 : 0 }),
    draw(p, E) {
      const y = p.yb, d = rp([[10.2, 1.5], [17.6, 1.5], [17.6, y], [13.9, y - 2.8], [10.2, y]], [0, 0, 0.6, 0.7, 0.6]);
      at(E.rib, { d }); at(E.ribF, { d, opacity: f(p.fo) });
      at(E.star, { transform: `translate(13.9 ${f(1.5 + (y - 4.3) * 0.5)}) scale(${f(Math.max(0.001, p.fo))})` });
    }
  },
  {
    name: '时钟',
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, 11.5)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, 11.5)}" ${OL}/>
      <path d="${circ(15.5, 12.5, 8.2)}" fill="#fff"/>
      <g filter="${u.hi}"><path data-n="sweep" fill="${u.upS}"/></g>
      <path data-n="hh" d="M15.5 12.5V8.3" stroke-width="2.6" stroke-linecap="round" data-t="stroke:#89B5FF"/>
      <path data-n="mh" d="M15.5 12.5V6.2" stroke-width="2" stroke-linecap="round" data-t="stroke:#2F6FE0"/>
      <circle cx="15.5" cy="12.5" r="1.7" data-t="fill:#2F6FE0"/>`,
    target: (h) => {
      // Time moves on: the hands run 25 minutes forward (10:08 to 10:33, still well apart)
      // and the face marks the stretch passed.
      const m = CLOCK_MINUTES, sw = h ? 150 : 0;
      return { base: m * 6, sw, mA: m * 6 + sw, hA: m / 2 + sw / 12 };
    },
    draw(p, E) {
      at(E.sweep, { d: sector(p.base, Math.max(0, p.sw), 7) });
      at(E.mh, { transform: `rotate(${f(p.mA)} 15.5 12.5)` });
      at(E.hh, { transform: `rotate(${f(p.hA)} 15.5 12.5)` });
    }
  },
  {
    name: '锁',
    svg: (u) => `
      <g data-n="shackle" filter="${u.sh}">
        <path d="M10.5 12V7.6A5 5 0 0 1 20.5 7.6V12" fill="none" stroke-width="3.2" stroke-linecap="round" data-t="stroke:#81B0FF"/>
        <path d="M10.5 12V7.6A5 5 0 0 1 20.5 7.6V12" fill="none" stroke-width="1" stroke-linecap="round" stroke="#fff" stroke-opacity=".45"/>
      </g>
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${rr(5.6, 11, 19.8, 12.6, KR)}" fill="${u.upS}"/></g></g>
      <path d="${rr(5.6, 11, 19.8, 12.6, KR)}" ${OL}/>
      <g data-n="key" data-t="fill:#2F6FE0"><circle cx="15.5" cy="16.2" r="2.5"/><path d="${rr(14.6, 16.6, 1.8, 4.6, 0.9)}"/></g>`,
    target: (h) => ({ sh: h ? [-2.4, 20] : [0, 0], key: h ? -90 : 0 }),
    draw(p, E) {
      at(E.shackle, { transform: `translate(0 ${f(p.sh[0])}) rotate(${f(p.sh[1])} 20.5 12)` });
      at(E.key, { transform: `rotate(${f(p.key)} 15.5 16.2)` });
    }
  },
  {
    name: '设置',
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><g data-n="gear"><path d="${GEAR}" fill="${u.loS}"/></g></g></g><g data-n="gearO"><path d="${GEAR}" ${OL}/></g>
      <path d="${circ(15.5, 12.5, 5.8)}" fill="#fff"/>
      <g filter="${u.hi}"><path data-n="hub" fill="${u.upS}"/></g>
      <path data-n="hubO" ${OL}/>`,
    target: (h) => ({ rot: h ? 60 : 0, hub: h ? 2.9 : 3.5 }),
    draw(p, E) {
      at(E.gear, { transform: `rotate(${f(p.rot)} 15.5 12.5)` }); at(E.gearO, { transform: `rotate(${f(p.rot)} 15.5 12.5)` });
      const d = circ(15.5, 12.5, p.hub);
      at(E.hub, { d }); at(E.hubO, { d });
    }
  },
  {
    name: '回收站',
    svg: (u) => `
      <g filter="${u.sh}"><path data-n="back" fill="${u.lo(18.6)}"/></g>
      <g data-n="card" filter="${u.sh}"><path d="${rr(0, 0, 10.4, 7.6, CR)}" fill="${u.upS}"/><circle cx="3" cy="3" r="1.4" fill="#fff"/></g>
      <g filter="${u.hi}"><path data-n="front" fill="${u.up(17.4)}"/></g>
      <path data-n="frontO" ${OL}/>
      <path data-n="ribs" fill="none" stroke-width="1.6" stroke-linecap="round" data-t="stroke:#5393FF" stroke-opacity=".6"/>
      <g data-n="lid"><g filter="${u.hi}"><path d="${TRASH_LID}" fill="${u.upS}"/></g><path d="${TRASH_LID}" ${OL}/></g>`,
    target: (h) => ({
      back: [[7.4, 4.8], [23.6, 4.8], [22.4, 23.4], [8.6, 23.4]],
      front: h ? [[6.6, 6], [24.4, 6], [22.6, 23.4], [8.4, 23.4]] : [[6.8, 6], [24.2, 6], [22.6, 23.4], [8.4, 23.4]],
      card: h ? [10.3, 2.4, -8] : [10.3, 12, 0],
      lid: h ? [0, -5.8, -6] : [0, 0, 0]
    }),
    draw(p, E) {
      at(E.back, { d: rp(p.back, [0.6, 0.6, 2.8, 2.8]) });
      const fr = rp(p.front, [1.2, 1.2, 2.8, 2.8]);
      at(E.front, { d: fr }); at(E.frontO, { d: fr });
      const F = p.front, top = F[0][1] + 3.4;
      at(E.ribs, { d: [0.36, 0.64].map((k) => `M${f(F[0][0] + (F[1][0] - F[0][0]) * k)} ${f(top)}L${f(F[3][0] + (F[2][0] - F[3][0]) * k)} 20.2`).join('') });
      at(E.card, { transform: `translate(${f(p.card[0])} ${f(p.card[1])}) rotate(${f(p.card[2])} 5.2 3.8)` });
      at(E.lid, { transform: `translate(${f(p.lid[0])} ${f(p.lid[1])}) rotate(${f(p.lid[2])} 15.5 5.3)` });
    }
  },
  {
    name: '分屏',
    // A window whose single page splits into two on hover; the new page carries the
    // opened result's line.
    svg: (u) => {
      const body = rr(4, 3.3, 23, 18.4, KR), head = rp(R(4, 3.3, 23, 4.6), [KR, KR, 0, 0]);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g>
      <path d="${body}" ${OL}/>
      <path data-n="L" fill="#fff"/>
      <g data-n="Rg"><path data-n="Rp" fill="#fff"/><path data-n="Ra" ${ACC}/></g>
      <g filter="${u.hi}"><path d="${head}" fill="${u.upS}"/></g>
      <path d="${head}" ${OL}/>`;
    },
    target: (h) => ({ L: h ? [6, 9.9, 8.9, 9.8] : [6, 9.9, 19, 9.8], Rr: h ? [16.1, 9.9, 8.9, 9.8, 1] : [25, 9.9, 0, 9.8, 0] }),
    draw(p, E) {
      const [x, y, w, hh] = p.L;
      at(E.L, { d: rr(x, y, w, hh, CR) });
      const [rx, ry, rw, rh, op] = p.Rr;
      at(E.Rp, { d: rr(rx, ry, rw, rh, CR) });
      at(E.Ra, { d: lines(rx + 1.8, ry + 2.6, [Math.max(0, rw - 3.6)]) });
      at(E.Rg, { opacity: f(op) });
    }
  },
  {
    name: '标签组',
    // Two tabs of one group; hover spreads them apart.
    svg: (u) => {
      const card = rr(0, 0, 18, 13.6, KR);
      return `
      <g data-n="b"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${card}" fill="${u.lo(13.6)}"/></g></g><path d="${card}" ${OL}/></g>
      <g data-n="fr"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${card}" fill="${u.up(13.6)}"/></g></g><path d="${card}" ${OL}/>
        <path d="${rr(2.4, 2.6, 6.4, 2.4, 1.2)}" data-t="fill:#2F6FE0"/>
        <path d="${lines(2.4, 8.4, [11.6])}" class="ln" data-t="stroke:#2F6FE0" stroke-opacity=".45"/></g>`;
    },
    target: (h) => ({ b: h ? [9, 1.4, 6] : [8.4, 3.3, 0], fr: h ? [3.4, 8.8, -4] : [4.6, 8.1, 0] }),
    draw(p, E) {
      at(E.b, { transform: `translate(${f(p.b[0])} ${f(p.b[1])}) rotate(${f(p.b[2])} 9 6.8)` });
      at(E.fr, { transform: `translate(${f(p.fr[0])} ${f(p.fr[1])}) rotate(${f(p.fr[2])} 9 6.8)` });
    }
  },
  {
    name: '画中画',
    // A small player floats in the corner of the page and pops out of the window on hover.
    svg: (u) => {
      const body = rr(4, 3.3, 23, 18.4, KR), mini = rr(0, 0, 9.6, 7, 1.6);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g>
      <path d="${body}" ${OL}/>
      <path d="${rr(6, 5.3, 19, 14.4, CR)}" fill="#fff"/>
      <g data-n="mini"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${mini}" fill="${u.upS}"/></g></g><path d="${mini}" ${OL}/>
        <path d="M3.8 1.8L6.6 3.5L3.8 5.2Z" stroke-width="1" stroke-linejoin="round" data-t="fill:#2F6FE0" data-ck="c"/></g>`;
    },
    target: (h) => ({ mini: h ? [17.2, 12.8, 1.1] : [14, 10.6, 1] }),
    draw(p, E) {
      at(E.mini, { transform: `translate(${f(p.mini[0])} ${f(p.mini[1])}) scale(${f(p.mini[2])})` });
    }
  },
  {
    name: '链接',
    // Two links of a chain; hover draws them tighter.
    svg: (u) => `
      <g data-n="g">
        <g data-n="a"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${LINK_RING}" fill-rule="evenodd" fill="${u.loS}"/></g></g><path d="${LINK_RING}" fill-rule="evenodd" ${OL}/></g>
        <g data-n="bb"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${LINK_RING}" fill-rule="evenodd" fill="${u.upS}"/></g></g><path d="${LINK_RING}" fill-rule="evenodd" ${OL}/></g>
      </g>`,
    target: (h) => ({ gap: h ? 3.5 : 4.2, rot: h ? -40 : -45 }),
    draw(p, E) {
      at(E.g, { transform: `rotate(${f(p.rot)} 15.5 12.5)` });
      at(E.a, { transform: `translate(${f(15.5 - p.gap)} 12.5)` });
      at(E.bb, { transform: `translate(${f(15.5 + p.gap)} 12.5)` });
    }
  },
  {
    name: '同步',
    // A dial with two chasing arrows that turn half a revolution on hover.
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, 11.5)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, 11.5)}" ${OL}/>
      <g filter="${u.hi}"><path d="${circ(15.5, 12.5, 8)}" fill="${u.upS}"/></g>
      <path d="${circ(15.5, 12.5, 8)}" ${OL}/>
      <g data-n="arr"><path d="${SYNC_A.arc}${SYNC_B.arc}" fill="none" stroke-width="2.2" stroke-linecap="round" data-t="stroke:#2F6FE0"/><path d="${SYNC_A.head}${SYNC_B.head}" data-t="fill:#2F6FE0"/></g>`,
    target: (h) => ({ rot: h ? 180 : 0 }),
    draw(p, E) {
      at(E.arr, { transform: `translate(15.5 12.5) rotate(${f(p.rot)})` });
    }
  },
  {
    name: '快捷方式',
    // A grid of sites; on hover one tile lifts out, ready to open.
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${rr(5.2, 2.2, 20.6, 20.6, KR)}" fill="${u.loS}"/></g></g>
      <path d="${rr(5.2, 2.2, 20.6, 20.6, KR)}" ${OL}/>
      ${SHORTCUT_TILES.filter((t, i) => i !== 1).map(([x, y]) => `<path d="${rr(x, y, 7.3, 7.3, CR)}" fill="#fff"/>`).join('')}
      <g data-n="lift"><g filter="${u.sh}"><path d="${rr(0, 0, 7.3, 7.3, CR)}" fill="#fff"/></g><circle cx="3.65" cy="3.65" r="1.7" data-t="fill:#5393FF"/></g>`,
    target: (h) => ({ lift: h ? [16.9, 2.6, 1.14] : [16.5, 4.2, 1] }),
    draw(p, E) {
      const [x, y, s] = p.lift;
      at(E.lift, { transform: `translate(${f(x)} ${f(y)}) translate(3.65 3.65) scale(${f(s)}) translate(-3.65 -3.65)` });
    }
  },
  {
    name: '外观',
    // Light and dark halves of one disc; hover turns the light half across.
    svg: (u) => {
      const disc = [15.5, 12.5, 11.5], half = frontPiece(disc, disc, 12.5, 2);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, 11.5)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, 11.5)}" ${OL}/>
      <g filter="${u.hi}"><g data-n="half"><path d="${half}" fill="${u.upS}"/></g></g>
      <g data-n="halfO"><path d="${half}" ${OL}/></g>`;
    },
    target: (h) => ({ rot: h ? 90 : -90 }),
    draw(p, E) {
      const t = `rotate(${f(p.rot)} 15.5 12.5)`;
      at(E.half, { transform: t }); at(E.halfO, { transform: t });
    }
  },
  {
    name: '主页',
    // The new-tab home: a house whose door swings open on hover.
    svg: (u) => {
      const roof = rp([[3.6, 12.6], [15.5, 2.4], [27.4, 12.6]], [1.4, 2.2, 1.4]);
      const door = rp(R(13.2, 15.6, 4.6, 7.4), [1.2, 1.2, 0, 0]);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${rr(7.4, 10.6, 16.2, 12.4, KR)}" fill="${u.loS}"/></g></g>
      <path d="${rr(7.4, 10.6, 16.2, 12.4, KR)}" ${OL}/>
      <path d="${door}" fill="${u.pure('#2F6FE0')}"/>
      <g data-n="door"><path d="${door}" fill="#fff"/></g>
      <g filter="${u.hi}"><path d="${roof}" fill="${u.upS}"/></g>
      <path d="${roof}" ${OL}/>`;
    },
    target: (h) => ({ door: h ? 0.3 : 1 }),
    draw(p, E) {
      at(E.door, { transform: `translate(13.2 0) scale(${f(Math.max(0.001, p.door))} 1) translate(-13.2 0)` });
    }
  },
  {
    name: '通知',
    // A bell that swings from its knob; the clapper lags behind.
    svg: (u) => {
      const bell = 'M7.8 18.4C9 17 9.3 15 9.3 12C9.3 8 12 5.2 15.5 5.2C19 5.2 21.7 8 21.7 12C21.7 15 22 17 23.2 18.4Z';
      const rim = rr(5.6, 17.4, 19.8, 3.8, 1.9);
      return `<g data-n="bell">
        <circle cx="15.5" cy="4.4" r="1.8" ${DEEP}/>
        <circle data-n="clap" cx="15.5" cy="21.4" r="2.3" ${DEEP}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${bell}" fill="${u.loS}"/></g></g><path d="${bell}" ${OL}/>
        <g filter="${u.hi}"><path d="${rim}" fill="${u.upS}"/></g><path d="${rim}" ${OL}/>
      </g>`;
    },
    target: (h) => ({ swing: h ? 14 : 0, clap: h ? -1.6 : 0 }),
    draw(p, E) {
      at(E.bell, { transform: `rotate(${f(p.swing)} 15.5 4.4)` });
      at(E.clap, { cx: f(15.5 + p.clap) });
    }
  },
  {
    name: '用户',
    // An avatar in a round frame; on hover the person looks up.
    svg: (u) => {
      const disc = circ(15.5, 12.5, 11.5);
      return `<clipPath id="${u.id('av')}"><path d="${disc}"/></clipPath>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${disc}" fill="${u.loS}"/></g></g>
        <g clip-path="url(#${u.id('av')})">
          <path data-n="body" d="${rp([[5, 27], [5, 22], [10.4, 17.4], [20.6, 17.4], [26, 22], [26, 27]], [0, 0, 4, 4, 0, 0])}" fill="#fff"/>
        </g>
        <circle data-n="head" cx="15.5" cy="10.4" r="4.4" fill="#fff"/>
        <path d="${disc}" ${OL}/>`;
    },
    target: (h) => ({ lift: h ? -1.2 : 0 }),
    draw(p, E) {
      at(E.head, { cy: f(10.4 + p.lift) });
      at(E.body, { transform: `translate(0 ${f(p.lift * 0.4)})` });
    }
  },
  {
    name: '聊天',
    // Two speech bubbles; the reply in front starts typing on hover.
    svg: (u) => {
      const back = rr(4, 3.3, 16, 11.6, KR);
      const front = rp([[10.2, 8.8], [27, 8.8], [27, 19], [17.4, 19], [13.8, 22.6], [13.8, 19], [10.2, 19]], [KR, KR, KR, 0.5, 0.6, 0.5, KR]);
      return `<g data-n="b"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${back}" fill="${u.loS}"/></g></g><path d="${back}" ${OL}/>
          <path d="${lines(7, 6.8, [6.4])}" class="ln" stroke="#fff" data-w="stroke"/></g>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g></g><path d="${front}" ${OL}/>
        <circle data-n="d1" cx="14.6" r="1.4" ${DEEP}/><circle data-n="d2" cx="18.6" r="1.4" ${DEEP}/><circle data-n="d3" cx="22.6" r="1.4" ${DEEP}/>`;
    },
    target: (h) => ({ d: h ? [-0.6, -1.5, -0.6] : [0, 0, 0], b: h ? -0.8 : 0 }),
    draw(p, E) {
      at(E.d1, { cy: f(13.9 + p.d[0]) }); at(E.d2, { cy: f(13.9 + p.d[1]) }); at(E.d3, { cy: f(13.9 + p.d[2]) });
      at(E.b, { transform: `translate(${f(p.b)} ${f(p.b)})` });
    }
  },
  {
    name: '手机',
    // A phone whose notification card slides in on hover.
    svg: (u) => {
      const body = rr(7.3, 1, 16.4, 23, 3.4), card = rr(0, 0, 10.4, 4.4, 1.4);
      return `<g data-n="ph">
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g><path d="${body}" ${OL}/>
        <path d="${rr(9.4, 3.4, 12.2, 16.6, CR)}" fill="#fff"/>
        <g data-n="card"><g filter="${u.hi}"><path d="${card}" fill="${u.upS}"/></g><path d="${card}" ${OL}/><path d="${lines(1.8, 2, [4.4])}" class="ln" ${DEEPS}/></g>
      </g>`;
    },
    target: (h) => ({ card: h ? [10.3, 6.2, 1] : [10.3, 3.4, 0], tilt: h ? -5 : 0 }),
    draw(p, E) {
      at(E.card, { transform: `translate(${f(p.card[0])} ${f(p.card[1])})`, opacity: f(p.card[2]) });
      at(E.ph, { transform: `rotate(${f(p.tilt)} 15.5 12.5)` });
    }
  },
  {
    name: '相机',
    // A camera body with a lens in front; the aperture closes on hover like a shutter.
    svg: (u) => {
      const body = rr(4, 6.6, 23, 15.1, KR), top = rp(R(9.6, 3.6, 7.4, 4), [1.6, 1.6, 0, 0]);
      return `<g filter="${u.sh}"><path d="${top}" fill="${u.loS}"/></g><path d="${top}" ${OL}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g><path d="${body}" ${OL}/>
        <g filter="${u.hi}"><path d="${circ(15.5, 14.2, 5.4)}" fill="${u.upS}"/></g><path d="${circ(15.5, 14.2, 5.4)}" ${OL}/>
        <circle data-n="iris" cx="15.5" cy="14.2" ${DEEP}/>`;
    },
    target: (h) => ({ iris: h ? 1.2 : 2.8 }),
    draw(p, E) { at(E.iris, { r: f(p.iris) }); }
  },
  {
    name: '音乐',
    // Two beamed notes that bounce on hover.
    svg: (u) => {
      const stems = rp([[12.4, 5], [25, 2.4], [25, 17.2], [22.8, 17.2], [22.8, 6.6], [14.6, 8.4], [14.6, 19.2], [12.4, 19.2]], [0.8, 0.8, 0.6, 0.6, 0.3, 0.3, 0.6, 0.6]);
      const head = (cx, cy) => `M${f(cx - 3.6)} ${f(cy)}A3.6 2.7 0 1 0 ${f(cx + 3.6)} ${f(cy)}A3.6 2.7 0 1 0 ${f(cx - 3.6)} ${f(cy)}Z`;
      const heads = head(10.8, 19.4) + head(21, 17.4);
      return `<g data-n="g">
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${stems}" fill="${u.loS}"/></g></g><path d="${stems}" ${OL}/>
        <g transform="rotate(-18 15.9 18.4)"><g filter="${u.hi}"><path d="${heads}" fill="${u.upS}"/></g><path d="${heads}" ${OL}/></g>
      </g>`;
    },
    target: (h) => ({ y: h ? -1.4 : 0, a: h ? -6 : 0 }),
    draw(p, E) { at(E.g, { transform: `translate(0 ${f(p.y)}) rotate(${f(p.a)} 15.5 12.5)` }); }
  },
  {
    name: '视频',
    // A video camera; its lens opens wider and the record light grows on hover.
    svg: (u) => {
      const body = rr(4, 6, 15.8, 13, KR);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g><path d="${body}" ${OL}/>
        <g filter="${u.hi}"><path data-n="lens" fill="${u.upS}"/></g><path data-n="lensO" ${OL}/>
        <circle data-n="dot" cx="8.8" cy="10.4" fill="#fff" data-w="fill"/>`;
    },
    target: (h) => ({ w: h ? [8.6, 6.2] : [7.6, 4.8], dot: h ? 2.3 : 1.8 }),
    draw(p, E) {
      const [wx, wy] = p.w;
      const d = rp([[18.6, 9.6], [18.6 + wx, 12.5 - wy], [18.6 + wx, 12.5 + wy], [18.6, 15.4]], [0.6, 1.4, 1.4, 0.6]);
      at(E.lens, { d }); at(E.lensO, { d });
      at(E.dot, { r: f(p.dot) });
    }
  },
  {
    name: '麦克风',
    // A microphone on its stand; sound waves appear on either side on hover.
    svg: (u) => {
      const cap = rr(10.6, 1.2, 9.8, 14.2, 4.9);
      return `<path d="M7.6 11.6C7.6 16.6 11.2 19.8 15.5 19.8C19.8 19.8 23.4 16.6 23.4 11.6M15.5 19.8V22.8M11.4 23.4H19.6" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${cap}" fill="${u.upS}"/></g></g><path d="${cap}" ${OL}/>
        <path data-n="wv" d="M4.4 4.4Q1.8 8.6 4.4 12.8M26.6 4.4Q29.2 8.6 26.6 12.8" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>`;
    },
    target: (h) => ({ wv: h ? 1 : 0 }),
    draw(p, E) { at(E.wv, { opacity: f(p.wv) }); }
  },
  {
    name: '定位',
    // A map pin that hops up on hover while its shadow on the ground shrinks.
    svg: (u) => {
      const pin = 'M15.5 22.4C12.2 18.8 7.6 14.8 7.6 9.6A7.9 7.9 0 0 1 23.4 9.6C23.4 14.8 18.8 18.8 15.5 22.4Z';
      return `<path data-n="shade" d="M11.5 23.6A4 1.1 0 1 0 19.5 23.6A4 1.1 0 1 0 11.5 23.6Z" data-t="fill:#B2CEFF"/>
        <g data-n="pin"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${pin}" fill="${u.loS}"/></g></g><path d="${pin}" ${OL}/>
          <circle cx="15.5" cy="9.6" r="3.2" fill="#fff"/></g>`;
    },
    target: (h) => ({ lift: h ? -2.4 : 0, sh: h ? 0.6 : 1 }),
    draw(p, E) {
      at(E.pin, { transform: `translate(0 ${f(p.lift)})` });
      at(E.shade, { transform: `translate(15.5 23.6) scale(${f(p.sh)} 1) translate(-15.5 -23.6)` });
    }
  },
  {
    name: '地球',
    // A globe whose meridian swings round as if it turns.
    svg: (u) => {
      const disc = circ(15.5, 12.5, 11.5);
      return `<clipPath id="${u.id('gl')}"><path d="${disc}"/></clipPath>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${disc}" fill="${u.loS}"/></g></g>
        <g clip-path="url(#${u.id('gl')})" fill="none" stroke-width="1.6" stroke="#fff" data-w="stroke">
          <path d="M3 12.5H28"/><path data-n="mer"/>
        </g>
        <path d="${disc}" ${OL}/>`;
    },
    target: (h) => ({ rx: h ? 8.6 : 4.6 }),
    draw(p, E) {
      const rx = p.rx;
      at(E.mer, { d: `M${f(15.5 - rx)} 12.5A${f(rx)} 11.5 0 1 0 ${f(15.5 + rx)} 12.5A${f(rx)} 11.5 0 1 0 ${f(15.5 - rx)} 12.5Z` });
    }
  },
  {
    name: '购物车',
    // A cart; on hover a parcel drops into its basket.
    svg: (u) => {
      const basket = rp([[7, 7], [26.8, 7], [24.6, 16.8], [9.4, 16.8]], [1.4, 1.4, 1.8, 1.8]);
      const box = rr(0, 0, 7.4, 6, 1.2);
      return `<path d="M3.4 3.6H6L9.2 16.8H23" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" ${DEEPS}/>
        <g data-n="box"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${box}" fill="${u.upS}"/></g></g><path d="${box}" ${OL}/></g>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${basket}" fill="${u.loS}"/></g></g><path d="${basket}" ${OL}/>
        <circle cx="11.4" cy="20.8" r="2" ${DEEP}/><circle cx="21.6" cy="20.8" r="2" ${DEEP}/>`;
    },
    target: (h) => ({ box: h ? [13.6, 3.2, 1] : [13.6, -1.2, 0] }),
    draw(p, E) { at(E.box, { transform: `translate(${f(p.box[0])} ${f(p.box[1])})`, opacity: f(p.box[2]) }); }
  },
  {
    name: '礼物',
    // A gift box whose lid lifts off on hover.
    svg: (u) => {
      const box = rr(6.6, 11, 17.8, 11.8, KR), lid = rr(5.2, 7.2, 20.6, 4.6, 1.6);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${box}" fill="${u.loS}"/></g></g><path d="${box}" ${OL}/>
        <path d="${rr(14.2, 11, 2.6, 11.8, 0)}" fill="#fff"/>
        <g data-n="lid">
          <path d="${circ(12.8, 5.6, 2.4) + circ(18.2, 5.6, 2.4)}" fill="${u.loS}"/><path d="${circ(12.8, 5.6, 2.4) + circ(18.2, 5.6, 2.4)}" ${OL}/>
          <g filter="${u.sh}"><g filter="${u.hi}"><path d="${lid}" fill="${u.upS}"/></g></g><path d="${lid}" ${OL}/>
          <path d="${rr(14.2, 7.2, 2.6, 4.6, 0)}" ${DEEP}/>
        </g>`;
    },
    target: (h) => ({ lid: h ? [-0.6, -3, -8] : [0, 0, 0] }),
    draw(p, E) { at(E.lid, { transform: `translate(${f(p.lid[0])} ${f(p.lid[1])}) rotate(${f(p.lid[2])} 15.5 9.5)` }); }
  },
  {
    name: '星标',
    // A star with a lighter star inset; it turns one point on hover.
    svg: (u) => {
      const big = star(11.6, 5.4), small = star(5.6, 2.6);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><g data-n="r1"><path d="${big}" fill="${u.loS}"/></g></g></g>
        <g data-n="r1o"><path d="${big}" ${OL}/></g>
        <g filter="${u.hi}"><g data-n="r2"><path d="${small}" fill="${u.upS}"/></g></g>
        <g data-n="r2o"><path d="${small}" ${OL}/></g>`;
    },
    target: (h) => ({ rot: h ? 72 : 0, s: h ? 1.05 : 1 }),
    draw(p, E) {
      const t = `translate(15.5 13.4) rotate(${f(p.rot)}) scale(${f(p.s)})`;
      ['r1', 'r1o', 'r2', 'r2o'].forEach((n) => at(E[n], { transform: t }));
    }
  },
  {
    name: '喜欢',
    // A heart with a lighter heart inside; it beats on hover.
    svg: (u) => {
      const heart = 'M0 9.6C-5.5 5.6 -10.9 1.4 -10.9 -3.6C-10.9 -7 -8.3 -9.6 -5.1 -9.6C-2.9 -9.6 -1.1 -8.4 0 -6.6C1.1 -8.4 2.9 -9.6 5.1 -9.6C8.3 -9.6 10.9 -7 10.9 -3.6C10.9 1.4 5.5 5.6 0 9.6Z';
      return `<g data-n="g">
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${heart}" fill="${u.loS}"/></g></g><path d="${heart}" ${OL}/>
        <g transform="translate(0 -0.6) scale(0.5)"><g filter="${u.hi}"><path d="${heart}" fill="${u.upS}"/></g></g>
      </g>`;
    },
    target: (h) => ({ s: h ? 1.12 : 1 }),
    draw(p, E) { at(E.g, { transform: `translate(15.5 13.2) scale(${f(p.s)})` }); }
  },
  {
    name: '编辑',
    // A pencil that writes a line on hover.
    svg: (u) => {
      const body = rr(7.1, 9.6, 15, 6.8, 0.8), tip = rp([[22.1, 9.6], [28.4, 13], [22.1, 16.4]], [0.3, 0.9, 0.3]), cap = rr(2.8, 9.6, 4.7, 6.8, 2);
      return `<path data-n="ink" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><g data-n="pen"><path d="${body}" fill="${u.loS}"/><path d="${tip}" fill="${u.upS}"/><path d="${cap}" fill="${u.upS}"/></g></g></g>
        <g data-n="penO"><path d="${body}" ${OL}/><path d="${tip}" ${OL}/><path d="${cap}" ${OL}/></g>`;
    },
    target: (h) => ({ push: h ? 1.6 : 0, ink: h ? 9 : 0 }),
    draw(p, E) {
      const t = `rotate(135 15.5 13) translate(${f(p.push)} 0)`;
      at(E.pen, { transform: t }); at(E.penO, { transform: t });
      at(E.ink, { d: `M6.4 23.6H${f(6.4 + p.ink)}`, opacity: p.ink > 0.2 ? 1 : 0 });
    }
  },
  {
    name: '便签',
    // A sticky note whose folded corner peels further on hover.
    svg: (u) => `<g filter="${u.sh}"><g filter="${u.hi}"><path data-n="note" fill="${u.loS}"/></g></g><path data-n="noteO" ${OL}/>
      <path d="${lines(8.6, 7.4, [13.8, 9.4])}" class="ln" stroke="#fff" data-w="stroke"/>
      <g filter="${u.hi}"><path data-n="fold" fill="${u.upS}"/></g><path data-n="foldO" ${OL}/>`,
    target: (h) => ({ cut: h ? 9 : 6.4 }),
    draw(p, E) {
      const c = p.cut;
      const note = rp([[5.2, 2.2], [25.8, 2.2], [25.8, 22.8 - c], [25.8 - c, 22.8], [5.2, 22.8]], [KR, KR, 0.6, 0.6, KR]);
      const fold = rp([[25.8, 22.8 - c], [25.8 - c, 22.8], [25.8 - c, 22.8 - c]], [0.5, 0.5, 1.2]);
      at(E.note, { d: note }); at(E.noteO, { d: note }); at(E.fold, { d: fold }); at(E.foldO, { d: fold });
    }
  },
  {
    name: '剪贴板',
    // A clipboard; a check gets ticked on its sheet on hover.
    svg: (u) => {
      const board = rr(6.3, 2.6, 18.4, 21.2, KR), clip = rp(R(11, 0.8, 9, 4.6), [1.6, 1.6, 1.2, 1.2]);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${board}" fill="${u.loS}"/></g></g><path d="${board}" ${OL}/>
        <path d="${rr(8.6, 6.6, 13.8, 15, CR)}" fill="#fff"/>
        <path d="${lines(11, 10.2, [9])}" ${LINE}/>
        <path data-n="chk" d="M12.2 16.2L14.6 18.6L19 14" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" ${DEEPS}/>
        <g filter="${u.hi}"><path d="${clip}" fill="${u.upS}"/></g><path d="${clip}" ${OL}/>`;
    },
    target: (h) => ({ chk: h ? 1 : 0 }),
    draw(p, E) {
      const L = 9.8;
      at(E.chk, { 'stroke-dasharray': L, 'stroke-dashoffset': f(L * (1 - Math.max(0, Math.min(1, p.chk)))) });
    }
  },
  {
    name: '复制',
    // Two sheets; the copy slides out from the original on hover.
    svg: (u) => {
      const sheet = rr(0, 0, 13.6, 15.6, KR);
      return `<g data-n="b"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${sheet}" fill="${u.loS}"/></g></g><path d="${sheet}" ${OL}/></g>
        <g data-n="fr"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${sheet}" fill="${u.up(15.6)}"/></g></g><path d="${sheet}" ${OL}/>
          <path d="${lines(2.6, 4.2, [8.4, 5.6])}" class="ln" ${DEEPS} stroke-opacity=".55"/></g>`;
    },
    target: (h) => ({ b: h ? [4.6, 1.6] : [5.2, 2.2], fr: h ? [12.8, 7.8] : [12.2, 7.2] }),
    draw(p, E) {
      at(E.b, { transform: `translate(${f(p.b[0])} ${f(p.b[1])})` });
      at(E.fr, { transform: `translate(${f(p.fr[0])} ${f(p.fr[1])})` });
    }
  },
  {
    name: '打印',
    // A printer that feeds a printed page out of its slot on hover.
    svg: (u) => {
      const tray = rp(R(8.4, 3.3, 14.2, 6.4), [1.4, 1.4, 0, 0]), body = rr(4, 8.4, 23, 9.4, KR), page = rr(0, 0, 13, 10, CR);
      return `<g filter="${u.hi}"><path d="${tray}" fill="${u.upS}"/></g><path d="${tray}" ${OL}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g><path d="${body}" ${OL}/>
        <clipPath id="${u.id('out')}"><rect x="0" y="15" width="31" height="12"/></clipPath>
        <g clip-path="url(#${u.id('out')})"><g data-n="page"><g filter="${u.hi}"><path d="${page}" fill="${u.upS}"/></g><path d="${page}" ${OL}/>
          <path d="${lines(2.2, 6, [8.6])}" class="ln" ${DEEPS} stroke-opacity=".55"/></g></g>
        <path d="M7 15H24" fill="none" stroke-width="2" stroke-linecap="round" ${DEEPS}/>`;
    },
    target: (h) => ({ y: h ? 11.6 : 8.4 }),
    draw(p, E) { at(E.page, { transform: `translate(9 ${f(p.y)})` }); }
  },
  {
    name: '天气',
    // The sun behind a cloud comes out on hover.
    svg: (u) => `<g data-n="sun"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(10.6, 10, 6)}" fill="${u.loS}"/></g></g><path d="${circ(10.6, 10, 6)}" ${OL}/></g>
      <g data-n="cl"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${cloud([12.6, 16.6, 4.4], [18.2, 12.6, 5.8], [23, 17, 4])}" fill="${u.upS}"/></g></g>
        <path d="${cloud([12.6, 16.6, 4.4], [18.2, 12.6, 5.8], [23, 17, 4])}" ${OL}/></g>`,
    target: (h) => ({ sun: h ? [-1, -1.6] : [0, 0], cl: h ? 1.2 : 0 }),
    draw(p, E) {
      at(E.sun, { transform: `translate(${f(p.sun[0])} ${f(p.sun[1])})` });
      at(E.cl, { transform: `translate(${f(p.cl)} 0)` });
    }
  },
  {
    name: '电池',
    // A battery that charges from low to nearly full on hover.
    svg: (u) => {
      const body = rr(3.6, 6.4, 21.6, 12.2, KR), nub = rp(R(24.6, 10, 2.8, 5), [0, 1.2, 1.2, 0]);
      return `<g filter="${u.sh}"><path d="${nub}" fill="${u.loS}"/></g><path d="${nub}" ${OL}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g><path d="${body}" ${OL}/>
        <path d="${rr(5.8, 8.6, 17.2, 7.8, 1.2)}" fill="#fff"/>
        <path data-n="lvl" ${DEEP}/>`;
    },
    target: (h) => ({ w: h ? 14.4 : 5.4 }),
    draw(p, E) { at(E.lvl, { d: rr(7.2, 10, p.w, 5, 0.8) }); }
  },
  {
    name: 'Wi-Fi',
    // Signal arcs that fill up from the inside out on hover.
    svg: () => `<circle cx="15.5" cy="20.6" r="2" ${DEEP}/>
      <path data-n="a1" d="M11.6 16.7A5.5 5.5 0 0 1 19.4 16.7" fill="none" stroke-width="2.8" stroke-linecap="round" ${DEEPS}/>
      <path data-n="a2" d="M8 13.1A10.6 10.6 0 0 1 23 13.1" fill="none" stroke-width="2.8" stroke-linecap="round" ${DEEPS}/>
      <path data-n="a3" d="M4.4 9.5A15.7 15.7 0 0 1 26.6 9.5" fill="none" stroke-width="2.8" stroke-linecap="round" ${DEEPS}/>`,
    target: (h) => ({ s: h ? 1 : 0 }),
    draw(p, E) {
      const lit = (i) => f(0.28 + 0.72 * Math.max(0, Math.min(1, p.s * 2 - (i - 1) * 0.8)));
      at(E.a2, { opacity: lit(1) }); at(E.a3, { opacity: lit(2) });
    }
  },
  {
    name: '灯泡',
    // A bulb that lights up on hover.
    svg: (u) => {
      const glass = 'M11 15.6C8.8 14 7.4 11.6 7.4 9A8.1 8.1 0 0 1 23.6 9C23.6 11.6 22.2 14 20 15.6V17.6H11Z';
      const base = rr(10.8, 16.8, 9.4, 6.4, 2);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${glass}" fill="${u.upS}"/></g></g><path d="${glass}" ${OL}/>
        <circle data-n="glow" cx="15.5" cy="9.4" r="5" fill="#fff"/>
        <path d="M12.8 12.6L14.2 9.8L15.5 11.8L16.8 9.8L18.2 12.6" fill="none" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" ${DEEPS}/>
        <g filter="${u.hi}"><path d="${base}" fill="${u.loS}"/></g><path d="${base}" ${OL}/>
        <path d="${lines(12.8, 20, [5.4])}" class="ln" stroke="#fff" data-w="stroke"/>`;
    },
    target: (h) => ({ glow: h ? 0.85 : 0 }),
    draw(p, E) { at(E.glow, { opacity: f(p.glow) }); }
  },
  {
    name: '钥匙',
    // A key that turns over on hover, its teeth flipping to the other side.
    svg: (u) => {
      const shaft = rp([[13.6, 10.9], [28.2, 10.9], [28.2, 17.6], [25.4, 17.6], [25.4, 14.1], [23.6, 14.1], [23.6, 18.6], [20.8, 18.6], [20.8, 14.1], [13.6, 14.1]], [0.4, 0.9, 0.7, 0.7, 0.3, 0.3, 0.7, 0.7, 0.3, 0.4]);
      const head = circ(9.4, 12.5, 7) + circ(9.4, 12.5, 2.6);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><g data-n="k"><path d="${shaft}" fill="${u.loS}"/><path d="${head}" fill-rule="evenodd" fill="${u.upS}"/></g></g></g>
        <g data-n="ko"><path d="${shaft}" ${OL}/><path d="${head}" fill-rule="evenodd" ${OL}/></g>`;
    },
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      const sy = Math.cos(Math.max(0, Math.min(1, p.o)) * Math.PI);
      const t = `translate(0 12.5) scale(1 ${f(Math.abs(sy) < 0.001 ? 0.001 : sy)}) translate(0 -12.5)`;
      at(E.k, { transform: t }); at(E.ko, { transform: t });
    }
  },
  {
    name: '盾牌',
    // A shield with a lit half; it steps forward on hover.
    svg: (u) => {
      const sh = 'M15.5 1.4L24.2 4.8V11.4C24.2 17.2 20.6 21.6 15.5 23.8C10.4 21.6 6.8 17.2 6.8 11.4V4.8Z';
      return `<g data-n="g">
        <clipPath id="${u.id('half')}"><rect x="15.5" y="-2" width="16" height="30"/></clipPath>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${sh}" fill="${u.loS}"/></g></g>
        <g clip-path="url(#${u.id('half')})"><g filter="${u.hi}"><path d="${sh}" fill="${u.upS}"/></g></g>
        <path d="${sh}" ${OL}/>
        <path d="M11.4 12.2L14.4 15.2L19.8 9.6" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" ${DEEPS}/>
      </g>`;
    },
    target: (h) => ({ y: h ? -1 : 0, s: h ? 1.06 : 1 }),
    draw(p, E) { at(E.g, { transform: `translate(15.5 ${f(12.6 + p.y)}) scale(${f(p.s)}) translate(-15.5 -12.6)` }); }
  },
  {
    name: '眼睛',
    // An eye that glances to the side on hover.
    svg: (u) => {
      const eye = 'M3.6 12.5C7 6.6 11 4.2 15.5 4.2C20 4.2 24 6.6 27.4 12.5C24 18.4 20 20.8 15.5 20.8C11 20.8 7 18.4 3.6 12.5Z';
      return `<clipPath id="${u.id('eye')}"><path d="${eye}"/></clipPath>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${eye}" fill="${u.loS}"/></g></g>
        <g clip-path="url(#${u.id('eye')})"><g data-n="iris"><g filter="${u.hi}"><path d="${circ(0, 0, 5.4)}" fill="${u.upS}"/></g><path d="${circ(0, 0, 5.4)}" ${OL}/>
          <circle data-n="pup" ${DEEP}/></g></g>
        <path d="${eye}" ${OL}/>`;
    },
    target: (h) => ({ x: h ? 2.6 : 0, pup: h ? 2.9 : 2.3 }),
    draw(p, E) { at(E.iris, { transform: `translate(${f(15.5 + p.x)} 12.5)` }); at(E.pup, { r: f(p.pup) }); }
  },
  {
    name: '筛选',
    // A funnel whose lines narrow on hover as the filter tightens.
    svg: (u) => {
      const top = rp([[5.2, 2.6], [25.8, 2.6], [18.2, 12.8], [12.8, 12.8]], [1.6, 1.6, 0.8, 0.8]);
      const spout = rp([[12.8, 12], [18.2, 12], [18.2, 21.4], [12.8, 24]], [0.4, 0.4, 1, 1]);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${top}" fill="${u.loS}"/></g></g><path d="${top}" ${OL}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${spout}" fill="${u.upS}"/></g></g><path d="${spout}" ${OL}/>
        <path data-n="ln" class="ln" stroke="#fff" data-w="stroke"/>`;
    },
    target: (h) => ({ w: h ? [8.4, 3.4] : [12.4, 6.6] }),
    draw(p, E) {
      const [a, b] = p.w;
      at(E.ln, { d: `M${f(15.5 - a / 2)} 5.8H${f(15.5 + a / 2)}M${f(15.5 - b / 2)} 8.8H${f(15.5 + b / 2)}` });
    }
  },
  {
    name: '图表',
    // A bar chart whose bars rise and fall to new values on hover.
    svg: (u) => `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${rr(5.2, 2.2, 20.6, 20.6, KR)}" fill="${u.loS}"/></g></g>
      <path d="${rr(5.2, 2.2, 20.6, 20.6, KR)}" ${OL}/>
      <path data-n="b1" fill="#fff"/><path data-n="b2" fill="#fff"/><path data-n="b3" fill="#fff"/>`,
    target: (h) => ({ hgt: h ? [10, 5.4, 13.4] : [5.4, 10.6, 7.6] }),
    draw(p, E) {
      [8.4, 13.7, 19].forEach((x, i) => {
        const hh = p.hgt[i];
        at(E['b' + (i + 1)], { d: rp(R(x, 20 - hh, 3.6, hh), [1, 1, 0.4, 0.4]) });
      });
    }
  },
  {
    name: '文档',
    // A page whose folded corner opens a little more on hover.
    svg: (u) => `<g filter="${u.sh}"><g filter="${u.hi}"><path data-n="pg" fill="${u.loS}"/></g></g><path data-n="pgO" ${OL}/>
      <path d="${lines(9.6, 13.4, [11.8, 8.2])}" class="ln" stroke="#fff" data-w="stroke"/>
      <g filter="${u.hi}"><path data-n="fold" fill="${u.upS}"/></g><path data-n="foldO" ${OL}/>`,
    target: (h) => ({ fold: h ? 8 : 6 }),
    draw(p, E) {
      const c = p.fold;
      const pg = rp([[6.3, 1.5], [24.7 - c, 1.5], [24.7, 1.5 + c], [24.7, 23.5], [6.3, 23.5]], [KR, 0.5, 0.5, KR, KR]);
      const fold = rp([[24.7 - c, 1.5], [24.7, 1.5 + c], [24.7 - c, 1.5 + c]], [0.4, 0.4, 1.2]);
      at(E.pg, { d: pg }); at(E.pgO, { d: pg }); at(E.fold, { d: fold }); at(E.foldO, { d: fold });
    }
  },
  {
    name: '包裹',
    // A parcel whose two top flaps fold open on hover.
    svg: (u) => {
      const box = rr(5.2, 8.6, 20.6, 14.2, KR);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${box}" fill="${u.lo(14.2)}"/></g></g><path d="${box}" ${OL}/>
        <path d="${rr(14.2, 8.6, 2.6, 4.6, 0.6)}" fill="#fff"/>
        <g filter="${u.hi}"><path data-n="fl" fill="${u.upS}"/></g><path data-n="flO" ${OL}/>
        <g filter="${u.hi}"><path data-n="fr" fill="${u.upS}"/></g><path data-n="frO" ${OL}/>`;
    },
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      const o = Math.max(0, Math.min(1, p.o));
      const l = rp([[5.2, 8.6], [15.4, 8.6], [15.4 - 2.6 * o, 6.2 - 2.8 * o], [5.2 - 2.8 * o, 6.2 - 1.6 * o]], [0.6, 0.6, 1, 1]);
      const r = rp([[15.6, 8.6], [25.8, 8.6], [25.8 + 2.8 * o, 6.2 - 1.6 * o], [15.6 + 2.6 * o, 6.2 - 2.8 * o]], [0.6, 0.6, 1, 1]);
      at(E.fl, { d: l }); at(E.flO, { d: l }); at(E.fr, { d: r }); at(E.frO, { d: r });
    }
  },
  {
    name: '钱包',
    // A wallet; the card tucked in it rises on hover.
    svg: (u) => {
      const body = rr(4, 5.6, 23, 16.1, KR), pocket = rp(R(4, 11, 23, 10.7), [1.6, 1.6, KR, KR]), card = rr(0, 0, 15, 9, 1.4);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g><path d="${body}" ${OL}/>
        <g data-n="card"><g filter="${u.hi}"><path d="${card}" fill="${u.upS}"/></g><path d="${card}" ${OL}/><path d="${lines(2.2, 2.6, [5.6])}" class="ln" ${DEEPS}/></g>
        <g filter="${u.hi}"><path d="${pocket}" fill="${u.up(10.7)}"/></g><path d="${pocket}" ${OL}/>
        <path d="${rr(19.4, 13.6, 7.6, 4.8, 2.4)}" fill="${u.loS}"/><path d="${rr(19.4, 13.6, 7.6, 4.8, 2.4)}" ${OL}/>`;
    },
    target: (h) => ({ y: h ? 2.4 : 4.6 }),
    draw(p, E) { at(E.card, { transform: `translate(6.6 ${f(p.y)})` }); }
  },
  {
    name: '银行卡',
    // A card in front of another; on hover they fan apart as if being drawn out.
    svg: (u) => {
      const card = rr(0, 0, 20.4, 13.4, KR);
      return `<g data-n="b"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${card}" fill="${u.upS}"/></g></g><path d="${card}" ${OL}/></g>
        <g data-n="fr"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${card}" fill="${u.loS}"/></g></g><path d="${card}" ${OL}/>
          <path d="${rr(2.8, 3.6, 4.6, 3.6, 1)}" fill="#fff"/>
          <path d="${lines(2.8, 10, [7.4])}" class="ln" stroke="#fff" data-w="stroke"/></g>`;
    },
    target: (h) => ({ b: h ? [7.4, 2.2, 6] : [6.6, 3.3, 0], fr: h ? [3.4, 8.8, -3] : [4, 8.3, 0] }),
    draw(p, E) {
      at(E.b, { transform: `translate(${f(p.b[0])} ${f(p.b[1])}) rotate(${f(p.b[2])} 10.2 6.7)` });
      at(E.fr, { transform: `translate(${f(p.fr[0])} ${f(p.fr[1])}) rotate(${f(p.fr[2])} 10.2 6.7)` });
    }
  },
  {
    name: '旗帜',
    // A flag that ripples on hover.
    svg: (u) => `<path d="M8.2 2.4V23.6" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
      <g filter="${u.sh}"><g filter="${u.hi}"><path data-n="cl" fill="${u.loS}"/></g></g><path data-n="clO" ${OL}/>`,
    target: (h) => ({ a: h ? -2 : 2 }),
    draw(p, E) {
      const a = p.a;
      const d = `M9.2 3.4C13.6 ${f(3.4 - a)} 18 ${f(3.4 + a)} 25 3.4V15.2C18 ${f(15.2 + a)} 13.6 ${f(15.2 - a)} 9.2 15.2Z`;
      at(E.cl, { d }); at(E.clO, { d });
    }
  },
  {
    name: '标签',
    // A hanging tag that swings on hover.
    svg: (u) => {
      const tag = rp([[4.4, 12.5], [11, 5.2], [26, 5.2], [26, 19.8], [11, 19.8]], [1.6, 1.6, KR, KR, 1.6]);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><g data-n="t"><path d="${tag}" fill="${u.loS}"/><circle cx="11.6" cy="12.5" r="2.2" fill="#fff"/></g></g></g>
        <g data-n="tO"><path d="${tag}" ${OL}/></g>`;
    },
    target: (h) => ({ a: h ? -22 : -34 }),
    draw(p, E) {
      const t = `rotate(${f(p.a)} 15.5 12.5)`;
      at(E.t, { transform: t }); at(E.tO, { transform: t });
    }
  },
  {
    name: '分享',
    // Three connected nodes; the shared ones spread out on hover.
    svg: (u) => `<path data-n="ln" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(9.4, 12.5, 4.4)}" fill="${u.loS}"/></g></g><path d="${circ(9.4, 12.5, 4.4)}" ${OL}/>
      <g data-n="n1"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(0, 0, 4)}" fill="${u.upS}"/></g></g><path d="${circ(0, 0, 4)}" ${OL}/></g>
      <g data-n="n2"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(0, 0, 4)}" fill="${u.upS}"/></g></g><path d="${circ(0, 0, 4)}" ${OL}/></g>`,
    target: (h) => ({ d: h ? 1.2 : 0 }),
    draw(p, E) {
      const a = [21.8 + p.d, 6.4 - p.d * 0.6], b = [21.8 + p.d, 18.6 + p.d * 0.6];
      at(E.n1, { transform: `translate(${f(a[0])} ${f(a[1])})` });
      at(E.n2, { transform: `translate(${f(b[0])} ${f(b[1])})` });
      at(E.ln, { d: `M9.4 12.5L${f(a[0])} ${f(a[1])}M9.4 12.5L${f(b[0])} ${f(b[1])}` });
    }
  },
  {
    name: '播放',
    // A play button that turns into pause on hover.
    svg: (u) => `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, 11.5)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, 11.5)}" ${OL}/>
      <path data-n="l" fill="#fff" data-w="fill"/><path data-n="r" fill="#fff" data-w="fill"/>`,
    target: (h) => ({
      l: h ? [[11, 7.2], [14.2, 7.2], [14.2, 17.8], [11, 17.8]] : [[12.2, 7.2], [16.4, 9.6], [16.4, 15.4], [12.2, 17.8]],
      r: h ? [[16.8, 7.2], [20, 7.2], [20, 17.8], [16.8, 17.8]] : [[16, 9.4], [21.4, 12.5], [21.4, 12.5], [16, 15.6]]
    }),
    draw(p, E) { at(E.l, { d: rp(p.l, 0.8) }); at(E.r, { d: rp(p.r, 0.8) }); }
  },
  {
    name: '音量',
    // A speaker whose sound waves grow louder on hover.
    svg: (u) => {
      const box = rr(4.4, 9, 6, 7, 1.4), cone = rp([[9.6, 9], [16, 4.2], [16, 20.8], [9.6, 16]], [0.6, 1.2, 1.2, 0.6]);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${box}" fill="${u.loS}"/></g></g><path d="${box}" ${OL}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${cone}" fill="${u.upS}"/></g></g><path d="${cone}" ${OL}/>
        <path data-n="w1" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
        <path data-n="w2" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>`;
    },
    target: (h) => ({ r: h ? [5.4, 9.8] : [4.6, 8.6], o: h ? 1 : 0.3 }),
    draw(p, E) {
      const w = (r) => { const a = 50 * Math.PI / 180; return `M${f(16.4 + r * Math.cos(a))} ${f(12.5 - r * Math.sin(a))}A${f(r)} ${f(r)} 0 0 1 ${f(16.4 + r * Math.cos(a))} ${f(12.5 + r * Math.sin(a))}`; };
      at(E.w1, { d: w(p.r[0]) }); at(E.w2, { d: w(p.r[1]), opacity: f(p.o) });
    }
  },
  {
    name: '耳机',
    // Headphones whose cups press in on hover.
    svg: (u) => {
      const band = 'M4.4 14.4A11.1 11.1 0 0 1 26.6 14.4H24A8.5 8.5 0 0 0 7 14.4Z';
      const cup = rr(0, 0, 6.8, 10.6, 3);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${band}" fill="${u.loS}"/></g></g><path d="${band}" ${OL}/>
        <g data-n="l"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${cup}" fill="${u.upS}"/></g></g><path d="${cup}" ${OL}/></g>
        <g data-n="r"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${cup}" fill="${u.upS}"/></g></g><path d="${cup}" ${OL}/></g>`;
    },
    target: (h) => ({ d: h ? 0.8 : 0 }),
    draw(p, E) {
      at(E.l, { transform: `translate(${f(3.6 + p.d)} 12.6)` });
      at(E.r, { transform: `translate(${f(20.6 - p.d)} 12.6)` });
    }
  },
  {
    name: '书本',
    // A closed book whose cover swings open on hover.
    svg: (u) => {
      const back = rr(6.3, 1.5, 18.4, 22, KR), cover = rr(6.3, 1.5, 18.4, 19.4, KR);
      return `<g filter="${u.sh}"><path d="${back}" fill="${u.loS}"/></g><path d="${back}" ${OL}/>
        <path d="${rr(7.8, 3, 15.6, 19.4, CR)}" fill="#fff"/>
        <path d="${lines(11.4, 8.4, [9.2, 6.6])}" ${ACC}/>
        <g data-n="cv"><g filter="${u.hi}"><path d="${cover}" fill="${u.loS}"/></g><path data-n="sh" d="${cover}" ${DEEP} opacity="0"/><path d="${cover}" ${OL}/>
          <path d="${lines(10.4, 7.6, [10.2])}" class="ln" stroke="#fff" data-w="stroke"/></g>`;
    },
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      const o = Math.max(0, Math.min(1, p.o));
      at(E.cv, { transform: `translate(6.3 0) scale(${f(Math.max(0.001, 1 - 0.72 * o))} 1) translate(-6.3 0)` });
      at(E.sh, { opacity: f(0.35 * o) });
    }
  },
  {
    name: '帮助',
    // A help badge whose question mark bobs on hover.
    svg: (u) => `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, 11.5)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, 11.5)}" ${OL}/>
      <g data-n="q"><text x="15.5" y="18.4" text-anchor="middle" font-size="16" font-weight="700" fill="#fff" data-w="fill">?</text></g>`,
    target: (h) => ({ y: h ? -1 : 0, a: h ? 10 : 0 }),
    draw(p, E) { at(E.q, { transform: `translate(0 ${f(p.y)}) rotate(${f(p.a)} 15.5 12.5)` }); }
  },
  {
    name: '闹钟',
    // An alarm clock with twin bells on two feet. On hover it rings: it rocks on its feet,
    // the swings die away and it comes to rest upright again.
    svg: (u) => {
      const body = circ(15.5, 13.4, 9.8), bells = circ(8.7, 6.6, 4.2) + circ(22.3, 6.6, 4.2);
      return `
      <g data-n="r0"><path d="M11.2 20.4L8.4 23.4M19.8 20.4L22.6 23.4" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/></g>
      <g filter="${u.sh}"><g filter="${u.hi}"><g data-n="r1"><path d="${bells}" fill="${u.upS}"/></g></g></g>
      <g data-n="r2"><path d="${bells}" ${OL}/></g>
      <g filter="${u.sh}"><g filter="${u.hi}"><g data-n="r3"><path d="${body}" fill="${u.loS}"/></g></g></g>
      <g data-n="r4"><path d="${body}" ${OL}/>
        <path d="${circ(15.5, 13.4, 7.4)}" fill="#fff"/>
        <path d="M15.5 13.4V9.6" transform="rotate(${CLOCK_MINUTES / 2} 15.5 13.4)" stroke-width="2.6" stroke-linecap="round" data-t="stroke:#89B5FF"/>
        <path d="M15.5 13.4V7.8" transform="rotate(${(CLOCK_MINUTES * 6) % 360} 15.5 13.4)" stroke-width="2" stroke-linecap="round" ${DEEPS}/>
        <circle cx="15.5" cy="13.4" r="1.7" ${DEEP}/></g>`;
    },
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      // One 0→1 progress drives a damped rattle that starts and ends upright.
      const o = Math.max(0, Math.min(1, p.o));
      const a = 12 * (1 - o) * Math.sin(5 * Math.PI * o);
      const t = `rotate(${f(a)} 15.5 23.4)`;
      ['r0', 'r1', 'r2', 'r3', 'r4'].forEach((n) => at(E[n], { transform: t }));
    }
  },
  {
    name: '笔记本',
    // A spiral notebook. On hover the cover turns over on its rings and folds away behind,
    // leaving the lined first page.
    svg: (u) => {
      const back = rr(6.3, 1, 18.4, 23, KR);
      const rings = [5.5, 10.2, 14.8, 19.5].map((y) => rr(3.8, y - 1.2, 7.4, 2.4, 1.2)).join('');
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${back}" fill="${u.loS}"/></g></g>
      <path d="${back}" ${OL}/>
      <path d="${rr(9.4, 3, 13.3, 19, CR)}" fill="#fff"/>
      <path d="${lines(13.4, 8.4, [7.4, 5])}" ${ACC}/>
      <g data-n="cvG"><g filter="${u.hi}"><path data-n="cv" fill="${u.upS}"/></g>
        <path data-n="shade" ${DEEP} opacity="0"/>
        <path data-n="cvO" ${OL}/>
        <g data-n="label"><path d="${lines(13.4, 7.4, [7])}" class="ln" ${DEEPS} stroke-opacity=".55"/></g></g>
      <path d="${rings}" ${DEEP}/>`;
    },
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      // The cover's width shrinks to its hinge on the rings, darkening as it faces away; at
      // the end it has gone round behind the back.
      const o = Math.max(0, Math.min(1, p.o));
      const s = Math.cos(o * Math.PI / 2), w = 15.3 * s;
      const d = rp(R(9.4, 1, w, 23), [1.6, KR, KR, 1.6]);
      at(E.cv, { d }); at(E.cvO, { d }); at(E.shade, { d, opacity: f(0.4 * Math.sin(o * Math.PI / 2)) });
      at(E.label, { transform: `translate(9.4 0) scale(${f(Math.max(0.001, s))} 1) translate(-9.4 0)` });
      at(E.cvG, { opacity: o > 0.985 ? 0 : 1 });
    }
  },
  {
    name: '扫码',
    // A QR code on a card with a scan bar lying across it. On hover the bar sweeps down
    // over the code and back up past the middle, then settles where it began.
    svg: (u) => {
      const card = rr(5.2, 2.2, 20.6, 20.6, KR), bar = rr(3.6, -1.2, 23.8, 2.4, 1.2);
      const finder = (x, y) => rr(x, y, 5.9, 5.9, 1.4) + rr(x + 1.6, y + 1.6, 2.7, 2.7, 0.6);
      const code = finder(7.4, 4.4) + finder(17.7, 4.4) + finder(7.4, 14.7) + rr(17.7, 14.7, 2.4, 2.4, 0.5) + rr(21.2, 18.2, 2.4, 2.4, 0.5);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${card}" fill="${u.loS}"/></g></g>
      <path d="${card}" ${OL}/>
      <path d="${code}" fill-rule="evenodd" fill="#fff" data-w="fill"/>
      <g data-n="bar"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${bar}" fill="${u.upS}"/></g></g><path d="${bar}" ${OL}/></g>`;
    },
    // At rest and at the end the bar's outline meets both rows of the code exactly.
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      const o = Math.max(0, Math.min(1, p.o));
      at(E.bar, { transform: `translate(0 ${f(12.5 + 7.6 * Math.sin(2 * Math.PI * o) * (1 - 0.35 * o))})` });
    }
  },
  {
    name: '退出',
    // A door with an arrow beside it. On hover the door swings open on its left hinge to
    // the bright outside and the arrow heads on out.
    svg: (u) => {
      const frame = rr(4, 1, 12.2, 23, KR), way = rp(R(7, 4, 6.2, 20), [1.6, 1.6, 0, 0]);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${frame}" fill="${u.loS}"/></g></g>
      <path d="${frame}" ${OL}/>
      <path d="${way}" fill="#fff"/>
      <g filter="${u.hi}"><path data-n="leaf" fill="${u.upS}"/></g>
      <path data-n="leafO" ${OL}/>
      <circle data-n="knob" cy="14" r="1.2" ${DEEP}/>
      <g data-n="arrow"><path d="M20.3 12.5H24" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
        <path d="${rp([[23.6, 9.9], [27, 12.5], [23.6, 15.1]], 0.5)}" ${DEEP}/></g>`;
    },
    target: (h) => ({ s: h ? 0.5 : 1, x: h ? 1.4 : 0 }),
    draw(p, E) {
      const w = 6.2 * p.s, d = rp(R(7, 4, w, 20), [1.6, 1.6, 0, 0]);
      at(E.leaf, { d }); at(E.leafO, { d });
      // The knob keeps to the free edge and never leaves the narrowing leaf.
      at(E.knob, { cx: f(7 + w * (0.29 + 0.42 * p.s)) });
      at(E.arrow, { transform: `translate(${f(p.x)} 0)` });
    }
  },
  {
    name: '计算器',
    // A calculator with a display and four operator keys. On hover the equals key is
    // pressed, lights up, and the display fills with the result.
    svg: (u) => {
      const body = rr(6.3, 1, 18.4, 23, KR), eq = rr(16.5, 16.8, 6.2, 5.2, CR);
      const eqMark = 'M18.3 18.1H20.9M18.3 20.7H20.9';
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g>
      <path d="${body}" ${OL}/>
      <path d="${rr(8.3, 3, 14.4, 4.6, CR)}" fill="#fff"/>
      <path data-n="read" class="ln" ${DEEPS}/>
      <path d="${rr(8.3, 9.6, 6.2, 5.2, CR) + rr(16.5, 9.6, 6.2, 5.2, CR) + rr(8.3, 16.8, 6.2, 5.2, CR)}" fill="#fff"/>
      <path d="M10.1 12.2H12.7M11.4 10.9V13.5M18.3 12.2H20.9M10.4 18.4L12.4 20.4M12.4 18.4L10.4 20.4" class="ln" ${DEEPS}/>
      <g data-n="eq"><path d="${eq}" fill="#fff"/><path data-n="lit" d="${eq}" fill="${u.pure('#2F6FE0')}"/>
        <path data-n="eqD" d="${eqMark}" class="ln" ${DEEPS}/><path data-n="eqW" d="${eqMark}" class="ln" stroke="#fff" data-w="stroke"/></g>`;
    },
    target: (h) => ({ o: h ? 1 : 0, s: h ? 0.9 : 1, n: h ? 9.6 : 3.4 }),
    draw(p, E) {
      const o = Math.max(0, Math.min(1, p.o));
      at(E.eq, { transform: `translate(19.6 19.4) scale(${f(p.s)}) translate(-19.6 -19.4)` });
      at(E.lit, { opacity: f(o) }); at(E.eqW, { opacity: f(o) }); at(E.eqD, { opacity: f(1 - o) });
      at(E.read, { d: `M${f(20.9 - p.n)} 5.3H20.9` });
    }
  },
  {
    name: '指南针',
    // A compass resting a little off north. On hover the needle swings past north and back,
    // each swing smaller, and settles pointing north.
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, 11.5)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, 11.5)}" ${OL}/>
      <path d="${circ(15.5, 12.5, 8.6)}" fill="#fff"/>
      <g data-n="needle">
        <path d="${rp([[13.1, 12.5], [15.5, 5.9], [17.9, 12.5]], [0, 0.6, 0])}" ${DEEP}/>
        <path d="${rp([[17.9, 12.5], [15.5, 19.1], [13.1, 12.5]], [0, 0.6, 0])}" data-t="fill:#89B5FF"/>
        <circle cx="15.5" cy="12.5" r="1.3" fill="#fff"/>
      </g>`,
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      const o = Math.max(0, Math.min(1, p.o));
      at(E.needle, { transform: `rotate(${f(40 * (1 - o) * Math.cos(3 * Math.PI * o))} 15.5 12.5)` });
    }
  }
];

// 保留云和桶的底子，只用各家标志区分服务。
const DISKIT_LOGOS_CHINA = {
  aliyunDrive: `<path d="M8.43 2.62L6.40 3.47L5.16 4.33L3.66 5.94L2.70 7.66L2.27 8.94L2.00 10.55L2.05 12.86L2.70 15.27L3.45 16.77L4.95 18.70L6.45 19.94L8.22 20.90L10.15 21.49L11.97 21.71L14.01 21.54L16.05 20.95L18.35 19.67L20.07 18.06L20.93 16.88L21.62 15.54L22.00 14.47L21.95 14.20L19.69 13.50L19.43 13.29L19.59 10.45L19.27 8.68L18.30 6.48L16.64 4.49L15.14 3.42L12.99 2.56L10.47 2.29ZM8.92 6.21L10.53 5.83L11.71 5.89L12.99 6.26L14.01 6.85L15.19 8.03L15.94 9.48L16.21 10.82L16.16 12.43L18.46 13.23L18.57 13.45L18.46 13.88L17.76 15.22L16.75 16.40L15.40 17.36L13.96 17.95L12.78 18.17L11.60 18.17L10.47 17.95L9.56 17.63L8.11 16.77L7.15 15.86L6.40 14.79L5.81 13.45L5.54 12.16L5.54 10.87L5.75 9.75L6.24 8.57L6.93 7.60L7.84 6.80Z" fill-rule="evenodd" ${DEEP}/>`,
  quark: `<path d="M11.43 2.00L9.78 2.23L7.91 2.85L6.15 3.88L4.61 5.24L3.42 6.83L2.62 8.48L2.11 10.41L2.00 12.45L2.23 14.16L2.97 16.32L3.88 17.85L5.35 19.50L6.72 20.52L8.42 21.38L10.64 21.94L12.80 22.00L14.90 21.60L17.00 20.69L18.25 19.84L19.56 18.59L20.69 17.00L21.60 14.90L22.00 12.80L22.00 11.15L21.83 9.95L21.26 8.14L20.18 6.20L18.70 4.56L17.06 3.36L15.35 2.57L13.53 2.11ZM11.43 7.00L13.36 7.17L15.01 8.02L16.26 9.44L16.77 10.64L16.94 11.55L16.89 12.40L16.49 12.85L14.56 13.14L13.99 13.36L13.48 13.82L13.08 14.78L12.91 16.38L12.62 16.77L12.23 16.94L10.64 16.77L8.93 15.92L8.02 15.01L7.51 14.22L7.00 12.51L7.17 10.58L7.97 8.99L8.65 8.25L9.61 7.57Z" fill-rule="evenodd" ${DEEP}/>`,
  baiduDrive: `<path d="M2.32 13.32L2.05 14.34L2.05 15.79L2.70 17.56L3.08 18.10L4.20 19.12L5.17 19.61L6.30 19.88L8.18 19.72L9.63 19.02L15.60 13.21L16.46 12.73L17.75 12.67L18.67 13.10L19.47 14.12L19.63 14.66L19.58 15.68L19.20 16.49L18.67 17.03L17.43 17.51L16.19 17.30L14.96 16.44L14.53 16.38L13.94 16.60L13.45 17.24L13.45 17.94L13.61 18.26L14.74 19.23L16.68 19.88L18.08 19.82L19.26 19.45L20.28 18.80L21.25 17.73L21.73 16.76L22.00 15.68L21.89 13.85L20.98 12.03L20.23 11.27L19.15 10.63L17.22 10.20L17.32 9.66L17.22 8.32L16.89 7.30L16.19 6.11L15.60 5.47L14.63 4.77L13.45 4.28L12.59 4.12L11.52 4.12L10.17 4.45L8.40 5.58L7.65 6.49L7.00 7.89L6.78 9.28L6.89 10.20L5.49 10.41L4.04 11.11L3.08 12.03ZM6.62 12.62L7.59 12.73L8.24 13.05L8.94 13.80L9.26 14.66L9.20 15.74L8.83 16.49L7.97 17.24L7.00 17.51L6.30 17.46L5.39 17.03L4.69 16.22L4.42 15.47L4.42 14.66L4.85 13.64L5.71 12.89ZM11.52 6.54L12.59 6.54L13.77 7.08L14.58 7.99L14.90 8.96L14.85 10.04L14.37 11.06L13.45 11.87L12.59 12.19L11.52 12.19L10.33 11.65L9.63 10.90L9.20 9.77L9.15 9.18L9.31 8.48L9.74 7.67L10.55 6.92Z" fill-rule="evenodd" ${DEEP}/>`,
  drive115: `<path d="M18.64 2.00L16.59 2.42L9.17 2.42L8.47 2.99L5.22 9.63L9.31 10.34L10.87 10.90L12.07 11.61L13.91 13.52L14.40 14.72L14.47 16.13L14.19 17.27L13.63 18.33L12.57 19.46L11.65 20.09L9.17 21.01L5.92 21.15L8.40 21.93L11.65 21.79L13.27 21.29L15.39 20.02L16.81 18.47L17.58 16.84L17.87 14.44L17.58 12.95L16.66 11.12L15.18 9.56L13.84 8.71L12.00 8.01L9.17 7.30L10.09 5.46L10.87 4.90L17.23 4.76L17.80 4.19L18.78 2.21Z" fill-rule="evenodd" ${DEEP}/>`,
  drive123: `<path d="M14.67 6.25L14.67 8.58L18.84 8.58L19.28 8.82L19.67 9.40L19.57 10.23L18.99 10.76L15.74 10.81L15.74 13.19L18.99 13.24L19.48 13.63L19.67 14.01L19.67 14.60L19.52 14.89L18.84 15.42L14.67 15.42L14.67 17.75L19.09 17.75L19.82 17.56L20.54 17.17L21.27 16.49L21.95 15.03L21.90 13.33L21.17 12.02L21.81 10.96L22.00 10.18L22.00 9.21L21.76 8.33L21.42 7.70L20.74 6.98L19.52 6.34ZM5.79 6.25L5.79 8.58L10.54 8.58L11.27 9.16L11.37 9.99L11.17 10.37L10.54 10.81L8.89 10.81L7.73 11.05L6.90 11.54L6.22 12.27L5.69 13.63L5.69 17.75L13.36 17.75L13.31 15.42L8.02 15.37L8.02 13.87L8.41 13.33L8.70 13.19L11.08 13.09L12.10 12.66L13.02 11.83L13.50 10.96L13.75 9.79L13.60 8.72L13.21 7.85L12.24 6.83L11.03 6.30ZM2.00 6.25L2.00 17.75L4.33 17.75L4.33 6.25Z" fill-rule="evenodd" ${DEEP}/>`,
  ucDrive: `<path d="M19.80 15.54L19.11 15.91L18.80 16.80L19.17 17.59L19.64 17.85L20.22 17.91L20.64 17.75L21.00 17.38L21.16 16.44L20.64 15.70ZM8.72 14.44L7.93 15.91L7.72 17.80L7.88 18.64L8.30 19.64L9.45 21.00L10.61 21.69L11.82 22.00L18.48 22.00L18.33 21.11L17.80 20.32L17.22 19.90L16.49 19.64L17.01 18.17L16.96 16.28L16.44 14.97L15.28 13.65L13.60 12.81L11.71 12.71L10.24 13.18L9.51 13.65ZM18.43 4.68L12.50 10.61L14.23 10.82L15.91 11.55L17.28 12.66L18.22 13.92L21.74 13.92L22.00 12.81L22.00 11.55L21.69 10.29L21.06 9.14L20.06 8.09L18.64 7.30L18.69 5.67ZM8.67 2.00L7.35 2.00L6.30 2.21L5.04 2.73L4.20 3.31L3.31 4.20L2.68 5.15L2.21 6.30L2.00 7.35L2.00 7.98L4.41 8.04L3.47 9.14L2.89 10.08L2.16 12.13L2.00 14.70L2.42 16.65L3.10 18.12L4.10 19.48L5.31 20.58L7.09 21.58L6.15 20.01L5.67 18.33L5.67 16.38L6.15 14.70L7.46 12.71L13.81 6.41L13.23 4.94L12.08 3.52L10.45 2.47Z" fill-rule="evenodd" ${DEEP}/>`,
  tianyiDrive: `<path d="M2.7 10.8L8.7 2.8Q9.2 2.2 9.7 2.8L15.7 10.8Q16.2 11.5 15.3 11.5H11.7C12.5 18.4 17.8 21.1 20.3 14.1L22 16.6C20.3 22.1 15.8 23.1 11.8 20.7C8.6 18.7 7.6 15.3 7.3 11.5H3.1Q2.2 11.5 2.7 10.8Z" ${DEEP}/>`,
};

const DISKIT_LOGOS_CLOUD = {
  oneDrive: `<path d="M2.899 16.286A5 5 0 0 1 6.936 8.429A6.25 6.25 0 0 1 18.212 10.314A4.062 4.062 0 1 1 17.938 18.429H7A5 5 0 0 1 2.899 16.286Z" ${DEEP}/>`,
  googleDrive: `<path d="M10.3 2H13.7Q14.8 2 15.4 3.1L21.5 13.8Q22.5 15.5 21.5 17.1L19.3 20.9Q18.7 22 17.4 22H6.6Q5.3 22 4.7 20.9L2.5 17.1Q1.5 15.5 2.5 13.8L8.6 3.1Q9.2 2 10.3 2ZM12 8.3L7.7 15.8H16.3Z" fill-rule="evenodd" ${DEEP}/>`,
  dropbox: `<path d="M2 6.8L6.9 3.8L11.8 6.8L6.9 9.8ZM12.2 6.8L17.1 3.8L22 6.8L17.1 9.8ZM2 12.9L6.9 9.9L11.8 12.9L6.9 15.9ZM12.2 12.9L17.1 9.9L22 12.9L17.1 15.9ZM7.2 17.2L12 14.3L16.8 17.2L12 20.2Z" ${DEEP}/>`,
  mobileCloud: `<path d="M4.2 5.7C7.6 2.3 13.8 4.1 19.1 2C18.1 5.3 13 5.2 8.4 5.6ZM2 10.2C7.8 6.1 15.8 8.4 22 6.1C20.1 9.7 16.5 9.5 13.7 10.1C10.9 12 6.5 16.4 7.5 18.7C8.2 20.2 14.4 19.9 17.1 19.9C19.7 19.9 20 17.8 19.5 15.9C19.1 14.1 17.8 12.8 16.2 13C14.8 13.1 13.7 14.1 14.1 15.3C14.5 16.4 15.3 16.4 16 15.7C16.5 17.4 15.9 18.3 14.4 18.3C11.7 18.3 10.7 16.3 11.5 13.9C12.5 11 15.6 10 18.2 11.2C20.8 12.4 22.2 15 22.2 17.5C22.2 20.4 20.3 22 17.1 22H8.3C4.4 22 3 20.3 4.3 17.4C5.5 14.6 8.2 12.5 9.4 10.4C7 9.7 4.6 10.5 2 10.2Z" ${DEEP}/>`,
  thunderDrive: `<path d="M2 4.9L5.6 5.8C7.3 5 9.1 6 10 7.9L20.8 2L18.1 6.2L19 6.1L16.1 10.5L22 12.8L13.6 14.8L16.7 22L9.4 16.2C6.4 15 5.4 12.8 5.6 9.8C5.7 7.6 4.5 6.2 2 4.9Z" ${DEEP}/>`,
  pikPak: `<path d="M2 6.5L3.1 4.2Q3.4 3.7 4.2 3.6L11.3 2.7L10.6 5.4ZM13.4 5.4L12.7 2.7L19.8 3.6Q20.6 3.7 20.9 4.2L22 6.5ZM2 7.4H22V18.5Q22 21.5 19 21.5H5Q2 21.5 2 18.5ZM7.3 10.8C6.6 10.8 6.1 11.3 6.1 12V13.1C6.1 13.8 6.6 14.3 7.3 14.3C8 14.3 8.5 13.8 8.5 13.1V12C8.5 11.3 8 10.8 7.3 10.8ZM16.7 10.8C16 10.8 15.5 11.3 15.5 12V13.1C15.5 13.8 16 14.3 16.7 14.3C17.4 14.3 17.9 13.8 17.9 13.1V12C17.9 11.3 17.4 10.8 16.7 10.8ZM8.2 16.7C10.6 17.8 13.4 17.8 15.8 16.7C17.1 17.8 15.6 19.4 12 19.4C8.4 19.4 6.9 17.8 8.2 16.7Z" fill-rule="evenodd" ${DEEP}/>`,
  lanzou: `<path d="M5.2 19.7H18.1C20.4 19.7 22 17.9 22 15.6C22 13.3 20.6 11.7 18.7 11.3C18.7 7.4 16.1 4.3 12.6 4.3C9.5 4.3 7 6.5 6.4 9.7C4 9.8 2 11.7 2 14.5C2 17.5 3.1 19.7 5.2 19.7Z" ${DEEP}/>`,
};

const DISKIT_LOGOS_OBJECTS = {
  s3: `<path d="M4.4 5.7C4.4 2.8 18.4 2.8 18.4 5.7C18.4 8.6 4.4 8.6 4.4 5.7ZM4.4 5.7L6.6 19.6C9 21.1 14 21.1 16.4 19.6L18.4 5.7M10.7 10.8L20 15C22.3 16.2 20.3 17.3 18 16.6" fill="none" ${DEEPS} stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/><circle cx="10.7" cy="10.8" r="1.4" ${DEEP}/>`,
  cloudflareR2: `<g transform="translate(2 7.425) scale(.058651)"><path d="M275.125 68.25C311.507 68.25 341 97.9335 341 134.55C341 141.077 340.063 147.385 338.317 153.343C337.848 154.943 336.363 156 334.706 156H243.056C241.697 156 240.76 154.628 241.247 153.351L242.999 148.76C248.595 134.03 264.56 121.963 279.331 121.256L307.33 119.813C308.826 119.736 310 118.492 310 116.985C310 115.485 308.838 114.245 307.351 114.157L281.059 112.601C266.924 111.877 260.018 99.2932 263.82 86.179L268.195 71.0866C268.64 69.5514 269.971 68.4343 271.557 68.3476C272.738 68.2831 273.928 68.25 275.125 68.25Z" ${DEEP} /><path d="M184.062 0C222 0 253.868 26.1297 262.882 61.4824C263.26 62.967 263.142 64.5333 262.601 65.9662L255.383 85.0897C249.787 99.8196 235.406 112.593 219.134 112.593L93.7928 114.043C92.2801 114.061 91.063 115.3 91.0625 116.823C91.0625 118.344 92.2776 119.585 93.789 119.605L217.365 121.248C231.531 121.248 238.406 134.556 234.606 147.671L233.011 153.189C232.53 154.855 231.014 156 229.291 156H3.90889C1.98075 156 0.330745 154.574 0.17634 152.64C0.0594555 151.175 0 149.695 0 148.2C0 119.723 21.6617 96.3403 49.306 93.8266C48.7387 91.2419 48.4375 88.5564 48.4375 85.8C48.4375 65.3379 64.919 48.75 85.25 48.75C93.3413 48.75 100.822 51.3789 106.897 55.8321C117.716 23.3806 148.176 0 184.062 0Z" ${DEEP} /></g>`,
  aliyunOSS: `<g transform="translate(2 5.6624) scale(.0124403)"><path d="M537.6 445.44H1075.2v122.88H537.6z" ${DEEP} /><path d="M1341.44 5.12h-353.28L1075.2 128l256 81.92c46.08 15.36 76.8 61.44 76.8 107.52v389.12c0 46.08-30.72 92.16-76.8 107.52l-256 81.92-87.04 122.88h353.28c148.48 0 266.24-117.76 266.24-266.24V276.48c0-148.48-117.76-271.36-266.24-271.36zM276.48 814.08c-46.08-15.36-76.8-61.44-76.8-107.52V317.44c0-46.08 30.72-92.16 76.8-107.52l256-81.92L619.52 5.12H266.24C117.76 5.12 0 128 0 276.48v471.04c0 148.48 117.76 266.24 266.24 266.24h353.28l-87.04-122.88-256-76.8z" ${DEEP} /></g>`,
  tencentCOS: `<path d="M5.5 10.1C5.5 5.4 8.7 2.4 12.7 2.4C16.6 2.4 19.8 4.9 20.6 8.4L17.2 8.9C16.6 6.7 14.9 5.5 12.7 5.5C10.1 5.5 8.5 7.4 8.5 10.1Z" ${DEEP}/><path d="M7 9.1C3.8 9.1 2 11.6 2 15.1C2 18.6 4.4 20.8 7.8 20.8H9.7L12.7 17.8H7.7C5.7 17.8 5 16.7 5 15.1C5 13.5 5.7 12.3 7.1 12.3C8.2 12.3 9.2 12.9 10.6 14.1L12.8 11.8C11 10 9.1 9.1 7 9.1Z" ${DEEP}/><path d="M16.8 9C15 9 13.5 9.9 11.8 11.5L3.2 20.8H15.9C19.9 20.8 22 18.4 22 15.2C22 11.5 19.8 9 16.8 9ZM16.8 12.3C18.2 12.3 19 13.4 19 15.1C19 16.8 18.2 17.8 16.1 17.8H10.2L14 13.9C15.3 12.7 16 12.3 16.8 12.3Z" fill-rule="evenodd" ${DEEP}/>`,
  qiniuKodo: `<path d="M2 4.4C4.3 7.2 6.6 8.5 9.1 9L8.3 5.3C9.9 6.1 10.1 7.7 10.2 8.8C15 8.7 18.8 6.6 22 4.2C20.8 8.7 16.7 11.2 11.6 11.6L11.2 16.3H15L16.4 12.9L18.4 12.1L18 17.1C17.8 19 16.8 19.8 15 19.8H11.2C9.6 19.8 8.7 19.1 8.3 17.4L7 11.2C4.2 9.5 2.5 7.5 2 4.4Z" ${DEEP}/>`,
  minIO: `<path d="M13.6 2C10.2 2 9.7 5.7 11.8 7.8L14.6 10.6C16 12 15.2 14.2 13.6 14.8L12.8 17.8C18.9 16.1 20 11.6 16.8 8.5L13.8 5.4C13.2 4.8 13.4 4.3 13.9 4.3L20.5 8.8L16.1 3.5C15.4 2.5 14.5 2 13.6 2Z" ${DEEP}/><path d="M16.1 9.5C10.2 11.5 5.6 15.2 4 19.2L16.1 15.6Z" ${DEEP}/><path d="M11.5 14.8H14.5V22L11.5 20Z" ${DEEP}/>`,
  backblazeB2: `<g transform="translate(5.9394 2) scale(.606061)"><path d="M16.5197 29.8661C15.003 30.3528 11.6662 30.5961 9.96747 28.4671C7.84405 25.8515 9.36077 23.8441 8.08672 24.1483C3.11186 25.304 0.867101 22.1409 0.442418 21.2285C0.442418 21.2285 0.26041 20.6202 0.139072 21.1677C-0.0429352 21.8976 -0.103604 23.6617 0.32108 25.2432C0.806433 27.2505 2.26249 30.5961 6.38799 32.2993C9.84613 33.6983 14.275 33.0292 17.1871 30.0486C17.9151 29.3795 17.7331 29.5012 16.5197 29.8661Z" ${DEEP} /><path d="M8.69376 2.18981C7.54104 0.790766 6.32766 0 6.32766 0C7.2377 1.88567 8.45108 5.65702 4.38625 9.915C1.89882 12.5306 0.139423 15.2071 1.1708 18.3093C1.65615 19.83 2.80886 21.7765 5.11428 22.1415C5.96365 22.2631 6.93435 22.1415 7.48038 21.959C10.8778 20.8032 10.3925 17.2752 9.60379 15.0246C9.48245 14.7204 9.36112 13.9905 9.30045 13.7472C8.81509 11.5574 10.3925 10.0975 10.8778 8.51595C10.9385 8.39429 10.9385 8.27264 10.9992 8.15098C11.0598 7.84684 11.1205 7.5427 11.1205 7.29939C11.1205 4.68377 9.7858 3.52804 8.69376 2.18981Z" ${DEEP} /><path d="M19.9792 22.3841C19.7972 20.1943 18.8872 18.6127 16.2178 15.5713C14.883 14.0506 14.0337 12.2258 14.0943 10.8875C14.2764 9.24519 15.0044 8.33276 15.0044 8.33276C15.0044 8.33276 14.0337 8.81939 13.3056 9.54933C12.699 10.2184 12.0923 10.7659 11.5462 12.1041C11.4856 12.2866 11.4856 12.4691 11.4249 12.7124C11.1216 14.963 13.0023 17.0312 12.3956 19.8901C12.2136 20.6201 11.9103 20.8634 11.3036 22.1408C10.5755 23.6615 10.7576 25.7296 11.7889 27.007C12.699 28.1628 14.3977 28.7102 15.9751 28.3452C18.8872 27.6153 20.2219 25.1214 19.9792 22.3841Z" ${DEEP} /></g>`
};

const DISKIT_LOGOS = { ...DISKIT_LOGOS_CHINA, ...DISKIT_LOGOS_CLOUD, ...DISKIT_LOGOS_OBJECTS };
function diskitMark(label, cx, cy, u) {
  const scale = 0.8;
  const centerY = Math.min(cy, 14);
  const logo = DISKIT_LOGOS[label].replaceAll('diskit-logo-v4-onedrive-mask', u.id('service-logo-mask'));
  return `<g transform="translate(${cx - 12 * scale} ${centerY - 12 * scale}) scale(${scale})">${logo}</g>`;
}
function diskitCloud(label) {
  return {
    svg(u) {
      const back = cloud([8.4, 9.2, 4.6], [15.5, 6.5, 5.8], [22.5, 9.6, 4.8]);
      const front = rp([[4,10.2],[11.7,10.2],[14,12.4],[27,12.4],[27,23],[4,23]], [1.7,1.3,1.3,1.7,KR,KR]);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${back}" fill="${u.loS}"/></g></g><path d="${back}" ${OL}/><path d="${rr(8,8.2,15.4,9,CR)}" fill="#fff"/><g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g><path d="${front}" ${OL}/>${diskitMark(label,15.5,18.2,u)}`;
    }, target: () => ({}), draw() {}
  };
}
function diskitBucket(label) {
  return {
    svg(u) {
      const back = rp([[4.4,4.2],[26.6,4.2],[24.7,23],[6.3,23]], [KR,KR,KR,KR]);
      const front = rp([[5.1,10],[25.9,10],[24.7,23],[6.3,23]], [1.8,1.8,KR,KR]);
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${back}" fill="${u.loS}"/></g></g><path d="${back}" ${OL}/><path d="M8 6.8H23" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/><g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g><path d="${front}" ${OL}/>${diskitMark(label,15.5,16.7,u)}`;
    }, target: () => ({}), draw() {}
  };
}
function diskitPhone(wireless) {
  return {
    svg(u) {
      const body=rr(6.3,1,18.4,23,KR), front=rr(6.3,17.6,18.4,6.4,1.8);
      const mark = wireless
        ? `<path d="M10.2 10Q15.5 5.5 20.8 10M12.6 13Q15.5 10.6 18.4 13" fill="none" ${DEEPS} stroke-width="1.6" stroke-linecap="round"/><circle cx="15.5" cy="15.2" r="1.2" ${DEEP}/>`
        : `<path d="M15.5 6V14M12 10V13Q12 15.7 15.5 15.7Q19 15.7 19 13V10" fill="none" ${DEEPS} stroke-width="1.6" stroke-linecap="round"/><path d="M13.5 8L15.5 5.3L17.5 8Z" ${DEEP}/>`;
      return `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g><path d="${body}" ${OL}/><path d="${rr(8.5,3.2,14,14.5,CR)}" fill="#fff"/>${mark}<g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g><path d="${front}" ${OL}/><path d="M12.9 21H18.1" fill="none" ${DEEPS} stroke-width="1.6" stroke-linecap="round"/>`;
    }, target: () => ({}), draw() {}
  };
}
ICONS.push(
  { name: 'androidUSB', ...diskitPhone(false) },
  { name: 'androidWiFi', ...diskitPhone(true) },
  { name: 'smb', svg(u) {
    const body=rr(4,2,23,15.4,KR), foot=rr(10,21,11,2.4,1.2), folder=rp([[12.4,12],[17.1,12],[19,14],[27,14],[27,23],[12.4,23]], [1.6,1,1,1.6,KR,KR]);
    return `<g filter="${u.sh}"><path d="${body}" fill="${u.loS}"/></g><path d="${body}" ${OL}/><path d="${rr(6.3,4.3,18.4,10.2,CR)}" fill="#fff"/><path d="${rr(13.8,17.4,3.4,4,0.6)}" fill="${u.loS}"/><path d="${foot}" fill="${u.loS}" ${OL}/><g filter="${u.hi}"><path d="${folder}" fill="${u.upS}"/></g><path d="${folder}" ${OL}/>`;
  },target:()=>({}),draw(){} },
  { name:'webdav', svg(u) {
    const back=rp([[4,3],[12,3],[14.5,6],[27,6],[27,23],[4,23]], [KR,1.4,1.4,KR,KR,KR]);
    const front=rr(4,10,23,13,1.8);
    return `<g filter="${u.sh}"><path d="${back}" fill="${u.loS}"/></g><path d="${back}" ${OL}/><path d="${rr(8,7,15,8,CR)}" fill="#fff"/><g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g><path d="${front}" ${OL}/><circle cx="15.5" cy="16.4" r="4.6" fill="#fff"/><circle cx="15.5" cy="16.4" r="4.6" fill="none" ${DEEPS} stroke-width="1.6"/><path d="M11.1 16.4H19.9M15.5 11.8Q11.7 16.4 15.5 21Q19.3 16.4 15.5 11.8" fill="none" ${DEEPS} stroke-width="1.6"/>`;
  },target:()=>({}),draw(){} },
  { name:'nfs', svg(u) {
    const body=rr(6.3,1,18.4,23,KR);
    return `<g filter="${u.sh}"><path d="${body}" fill="${u.loS}"/></g><path d="${body}" ${OL}/><path d="${rr(8.6,3.5,13.8,6.4,CR)}" fill="#fff"/><g filter="${u.hi}"><path d="${rr(6.3,12,18.4,12,1.8)}" fill="${u.upS}"/></g><path d="${rr(6.3,12,18.4,12,1.8)}" ${OL}/><path d="M9.9 6.7H16.1M9.9 17.4H16.1" fill="none" ${DEEPS} stroke-width="1.6" stroke-linecap="round"/><circle cx="20" cy="6.7" r="1.2" ${DEEP}/><circle cx="20" cy="17.4" r="1.2" ${DEEP}/>`;
  },target:()=>({}),draw(){} },
  { name:'ricohGR', svg(u) {
    const body=rr(4,4.8,23,16.9,KR), front=rr(4,12.3,23,9.4,1.8);
    return `<g filter="${u.sh}"><path d="${rr(19.3,2.4,5,3,1.2)}" fill="${u.loS}"/><path d="${body}" fill="${u.loS}"/></g><path d="${body}" ${OL}/><g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g><path d="${front}" ${OL}/><path d="${circ(12,13.3,5.5)}" fill="#fff"/><path d="${circ(12,13.3,5.5)}" ${OL}/><path d="${circ(12,13.3,2.8)}" ${DEEP}/><path d="M20.5 8H23.5" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/>`;
  },target:()=>({}),draw(){} },
  { name:'cameraUSB', svg(u) {
    const top=rp([[9,7],[11,2.5],[20,2.5],[22,7]], [1,1.5,1.5,1]), body=rr(4,6.2,23,16.2,KR), front=rr(4,13,23,9.4,1.8);
    return `<g filter="${u.sh}"><path d="${top}" fill="${u.loS}"/></g><path d="${top}" ${OL}/><g filter="${u.sh}"><path d="${body}" fill="${u.loS}"/></g><path d="${body}" ${OL}/><g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g><path d="${front}" ${OL}/><path d="${circ(15.5,13.5,6)}" fill="#fff"/><path d="${circ(15.5,13.5,6)}" ${OL}/><path d="${circ(15.5,13.5,3.3)}" ${DEEP}/>`;
  },target:()=>({}),draw(){} },
  {name:'aliyunDrive',...diskitCloud('aliyunDrive')}, {name:'quark',...diskitCloud('quark')}, {name:'baiduDrive',...diskitCloud('baiduDrive')},
  {name:'drive115',...diskitCloud('drive115')}, {name:'drive123',...diskitCloud('drive123')}, {name:'oneDrive',...diskitCloud('oneDrive')},
  {name:'googleDrive',...diskitCloud('googleDrive')}, {name:'dropbox',...diskitCloud('dropbox')}, {name:'ucDrive',...diskitCloud('ucDrive')},
  {name:'tianyiDrive',...diskitCloud('tianyiDrive')}, {name:'mobileCloud',...diskitCloud('mobileCloud')}, {name:'thunderDrive',...diskitCloud('thunderDrive')},
  {name:'pikPak',...diskitCloud('pikPak')}, {name:'lanzou',...diskitCloud('lanzou')},
  {name:'s3',...diskitBucket('s3')}, {name:'cloudflareR2',...diskitBucket('cloudflareR2')}, {name:'aliyunOSS',...diskitBucket('aliyunOSS')},
  {name:'tencentCOS',...diskitBucket('tencentCOS')}, {name:'qiniuKodo',...diskitBucket('qiniuKodo')}, {name:'minIO',...diskitBucket('minIO')}, {name:'backblazeB2',...diskitBucket('backblazeB2')},
  {name:'emptyLink',svg(u) {
    const back=rp([[4,3],[11.5,3],[14,6],[27,6],[27,22],[4,22]], [KR,1.4,1.4,KR,KR,KR]), front=rr(4,10,23,12,1.8);
    return `<g filter="${u.sh}"><path d="${back}" fill="${u.loS}"/></g><path d="${back}" ${OL}/><path d="${rr(8,7.5,15,8,CR)}" fill="#fff"/><g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g><path d="${front}" ${OL}/><g transform="translate(15.5 16.3) rotate(-35)"><path d="${rr(-6.3,-3,8.5,6,3)}" fill="none" ${DEEPS} stroke-width="2.2"/><path d="${rr(-2.2,-3,8.5,6,3)}" fill="none" ${DEEPS} stroke-width="2.2"/></g>`;
  },target:()=>({}),draw(){} }
);
