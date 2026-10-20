import type { ReactNode, SVGProps } from "react";

// Pencil-line drawings for the page: 1.5px ink strokes, white fills, halftone dots in the brand colours.
// Stroke and fill are set on the <svg> and inherited, so a fill="…" attribute on a shape wins.
const RED = "#f0384f", RED_T = "#fde7ea", GREEN = "#2fbf71", INK = "#18181b";
const tones = { orange: "#ff8538", pink: "#ff2973", violet: "#9e61ff", peri: "#85a8ff" };
type Tone = keyof typeof tones;
const ht = (t: Tone) => `url(#ht-${t})`;

export const HalftoneDefs = () => (
  <svg width="0" height="0" className="defs" aria-hidden="true">
    <defs>
      {Object.entries(tones).map(([name, c]) => (
        <pattern key={name} id={`ht-${name}`} width="4.5" height="4.5" patternUnits="userSpaceOnUse"><circle cx="2.25" cy="2.25" r="1.1" fill={c} /></pattern>
      ))}
      <radialGradient id="ht-fade-g"><stop offset=".3" stopColor="#fff" /><stop offset="1" stopColor="#000" /></radialGradient>
      <mask id="ht-fade" maskContentUnits="objectBoundingBox"><rect width="1" height="1" fill="url(#ht-fade-g)" /></mask>
    </defs>
  </svg>
);

// a patch of halftone dots that fades out at its edges
export const Puddle = ({ tone, ...p }: { tone: Tone } & SVGProps<SVGEllipseElement>) => <ellipse {...p} fill={ht(tone)} stroke="none" mask="url(#ht-fade)" />;

const at = (x: number, y: number, s = 1) => `translate(${x} ${y})${s === 1 ? "" : ` scale(${s})`}`;
const Art = ({ w, h, vb, children }: { w: number; h: number; vb?: string; children: ReactNode }) => (
  <svg className="drawing" width={w} height={h} viewBox={vb ?? `0 0 ${w} ${h}`} aria-hidden="true">{children}</svg>
);
const Fig = ({ vb, label, children, className = "" }: { vb: string; label: string; children: ReactNode; className?: string }) => (
  <svg className={`drawing fig ${className}`} viewBox={vb} role="img" aria-label={label}>{children}</svg>
);

/* the cast: server, phone, Mac, invite ticket */

export const Server = ({ x = 0, y = 0, s = 1, blink = false, slots = 3 }) => (
  <g transform={at(x, y, s)}>
    {[0, 34, 68].slice(0, slots).map((top, i) => (
      <g key={top}>
        <rect y={top} width="120" height="28" rx="6" fill="#fff" />
        <circle cx="16" cy={top + 14} r="3" className={blink ? "led blink" : "led"} style={blink ? { animationDelay: `${i * 0.8}s` } : undefined} />
        <line x1="34" y1={top + 14} x2="96" y2={top + 14} />
      </g>
    ))}
  </g>
);

const Phone = ({ x = 0, y = 0 }) => (
  <g transform={at(x, y)}>
    <rect width="58" height="100" rx="12" fill="#fff" /><line x1="22" y1="88" x2="36" y2="88" />
    <rect x="9" y="16" width="40" height="16" rx="5" className="bubble-red" /><rect x="9" y="38" width="32" height="14" rx="5" className="bubble" />
  </g>
);

export const Mac = ({ x = 0, y = 0, s = 1, pulse = true, children }: { x?: number; y?: number; s?: number; pulse?: boolean; children?: ReactNode }) => (
  <g transform={at(x, y, s)}>
    <rect width="128" height="82" rx="8" fill="#fff" /><line x1="0" y1="14" x2="128" y2="14" />
    {pulse && <path d="M104 7h8l2-3 3 6 2-3h3" className="pulse-mark" />}
    <path d="M44 82l-6 14h52l-6-14" fill="#fff" /><line x1="30" y1="96" x2="98" y2="96" />
    {children}
  </g>
);

// The invite: a ticket with notches and a dashed perforation. Drawn at any size without scaling,
// so its halftone dots stay the same size as everywhere else.
function ticketPath(w: number, h: number) {
  const c = (h * 8) / 52, n = (h * 10) / 52, v = (h * 8) / 52;
  return `M0 ${c}a${c} ${c} 0 0 1 ${c}-${c}h${w - 2 * c}a${c} ${c} 0 0 1 ${c} ${c}v${v}a${n} ${n} 0 0 0 0 ${2 * n}v${v}a${c} ${c} 0 0 1-${c} ${c}H${c}a${c} ${c} 0 0 1-${c}-${c}v-${v}a${n} ${n} 0 0 0 0-${2 * n}z`;
}
const zig = (h: number) => `l2-${h / 10}-2-${h / 10}`.repeat(5);  // a torn edge, bottom to top
export const Ticket = ({ x = 0, y = 0, w = 128, h = 52, tone, torn = false, label = false }: { x?: number; y?: number; w?: number; h?: number; tone?: Tone; torn?: boolean; label?: boolean }) => {
  const p = (w * 40) / 128, c = (h * 8) / 52, n = (h * 10) / 52, v = (h * 8) / 52;
  const body = `M${p} 0H${w - c}a${c} ${c} 0 0 1 ${c} ${c}v${v}a${n} ${n} 0 0 0 0 ${2 * n}v${v}a${c} ${c} 0 0 1-${c} ${c}H${p}${zig(h)}z`;
  const stub = `M${p} 0H${c}a${c} ${c} 0 0 0-${c} ${c}v${v}a${n} ${n} 0 0 1 0 ${2 * n}v${v}a${c} ${c} 0 0 0 ${c} ${c}H${p}${zig(h)}z`;
  const fill = tone ? ht(tone) : "#fff";
  return (
    <g transform={at(x, y)}>
      {torn ? <>
        <path d={body} fill="#fff" stroke="none" /><path d={body} fill={fill} />
        <g className="stub"><path d={stub} fill="#fff" /></g>
      </> : <>
        <path d={ticketPath(w, h)} fill="#fff" stroke="none" /><path d={ticketPath(w, h)} fill={fill} />
        <line x1={p} y1={h * 0.12} x2={p} y2={h * 0.88} className="dash" />
      </>}
      {label && <text x={(p + w) / 2} y={h / 2 + 4.5} className="ink big">once</text>}
    </g>
  );
};

/* how it works */

export const PhoneArt = () => <Art w={62} h={104} vb="-2 -2 62 104"><Phone /></Art>;
export const ServerArt = () => <Art w={180} h={118}><Puddle tone="orange" cx="90" cy="98" rx="96" ry="26" /><Server x={30} y={2} blink /></Art>;
export const MacArt = () => <Art w={132} h={100} vb="-2 -2 132 100"><Mac /></Art>;

/* what it checks: 64x44 tiles, the broken part in red */

const Tile = ({ children }: { children: ReactNode }) => <Art w={64} h={44}>{children}</Art>;
const Accent = ({ cx, cy }: { cx: number; cy: number }) => <Puddle tone="pink" cx={cx} cy={cy} rx="16" ry="12" />;
function gear(cx: number, cy: number, ro: number, ri: number, n: number) {
  const step = (Math.PI * 2) / n, pt = (r: number, a: number) => `${(cx + r * Math.cos(a)).toFixed(1)} ${(cy + r * Math.sin(a)).toFixed(1)}`;
  return Array.from({ length: n }, (_, i) => {
    const a = i * step - Math.PI / 2;
    return `${i ? "L" : "M"}${pt(ri, a - step * 0.3)}L${pt(ro, a - step * 0.15)}L${pt(ro, a + step * 0.15)}L${pt(ri, a + step * 0.3)}`;
  }).join("") + "Z";
}

export const CheckDisk = () => (
  <Tile>
    <Accent cx={56} cy={38} />
    <rect x="4" y="7" width="56" height="30" rx="6" fill="#fff" />
    <rect x="10" y="15" width="44" height="9" rx="2.5" />
    {Array.from({ length: 9 }, (_, i) => <line key={i} x1={14.5 + i * 4} y1="17.8" x2={14.5 + i * 4} y2="21.2" strokeWidth="2" stroke={i === 8 ? RED : undefined} className={i === 8 ? "bad-part" : undefined} />)}
    <line x1="48.5" y1="10.5" x2="48.5" y2="12.5" />
    <line x1="10" y1="30.5" x2="24" y2="30.5" /><circle cx="53" cy="30.5" r="1.4" fill={INK} stroke="none" />
  </Tile>
);

export const CheckMemory = () => (
  <Tile>
    <Accent cx={8} cy={38} />
    <rect x="4" y="7" width="56" height="23" rx="2.5" fill="#fff" />
    {Array.from({ length: 10 }, (_, i) => {
      const bad = i === 9;
      return <rect key={i} x={8.5 + (i % 5) * 10} y={11 + Math.floor(i / 5) * 8.5} width="7" height="5" rx="1" fill={bad ? RED_T : "#fff"} stroke={bad ? RED : undefined} className={bad ? "bad-part" : undefined} />;
    })}
    {[9, 13, 17, 21, 25, 39, 43, 47, 51, 55].map(x => <line key={x} x1={x} y1="30" x2={x} y2="34" />)}
  </Tile>
);

export const CheckSystemd = () => (
  <Tile>
    <Accent cx={10} cy={38} />
    <path d={gear(28, 24, 15, 11, 8)} fill="#fff" /><circle cx="28" cy="24" r="4.5" />
    <g className="bad-part" stroke={RED}><circle cx="47" cy="10" r="6.5" fill={RED_T} /><path d="M44.6 7.6l4.8 4.8m0-4.8l-4.8 4.8" /></g>
  </Tile>
);

export const CheckPm2 = () => (
  <Tile>
    <Accent cx={58} cy={40} />
    {[0, 1, 2].map(i => (
      <g key={i}>
        <rect x="6" y={4 + i * 12.5} width="52" height="9" rx="3" fill="#fff" />
        <circle cx="12" cy={8.5 + i * 12.5} r="2" fill={i === 1 ? RED : GREEN} stroke="none" className={i === 1 ? "bad-part" : undefined} />
        <line x1="19" y1={8.5 + i * 12.5} x2={i === 1 ? 33 : 44} y2={8.5 + i * 12.5} />
      </g>
    ))}
  </Tile>
);

export const CheckDocker = () => (
  <Tile>
    <Accent cx={10} cy={38} />
    <path d="M32 11l11 6v12l-11 6-11-6V17z" fill="#fff" /><path d="M21 17l11 6 11-6M32 23v12" />
    <g className="bad-part" stroke={RED}><path d="M41.5 6.6A19 19 0 1 1 25.5 5.2" /><path d="M20.7 3.9l4.8 1.3-2.9 4.1" /></g>
  </Tile>
);

export const CheckSites = () => (
  <Tile>
    <Accent cx={58} cy={40} />
    <rect x="5" y="4" width="54" height="36" rx="5" fill="#fff" /><line x1="5" y1="12" x2="59" y2="12" />
    {[10, 14.5, 19].map(x => <circle key={x} cx={x} cy="8" r=".8" fill={INK} />)}
    <g className="bad-part" stroke={RED}>
      <path d="M28 25v-3.5a4 4 0 0 1 7.6-1.8" /><path d="M36 23.3v1.2" />
      <rect x="25.5" y="25" width="13" height="10" rx="2" fill={RED_T} /><path d="M32.4 27.2l-1.3 2.1 2.1 1.3-1.2 2.2" />
    </g>
  </Tile>
);

export const CheckPeers = () => (
  <Tile>
    <Accent cx={58} cy={40} />
    {[3, 41].map(x => (
      <g key={x}>
        <rect x={x} y="9" width="20" height="11" rx="2.5" fill="#fff" /><rect x={x} y="23" width="20" height="11" rx="2.5" fill="#fff" />
        <circle cx={x + 5} cy="14.5" r="1.2" fill={INK} stroke="none" /><circle cx={x + 5} cy="28.5" r="1.2" fill={INK} stroke="none" />
      </g>
    ))}
    <path d="M25.5 21.5h2.5M36 21.5h2.5" />
    <path d="M30 19.2l4 4.6m0-4.6l-4 4.6" stroke={RED} className="bad-part" />
  </Tile>
);

export const CheckHeartbeat = () => (
  <Tile>
    <Accent cx={8} cy={38} />
    <path d="M25 37C12 29 5.5 21 8 14 10.5 7.5 18.5 7 22 12l3 3.5 3-3.5c3.5-5 11.5-4.5 14 2 2.5 7-4 15-17 23z" fill="#fff" />
    <path d="M11.5 22.5h6l2.5-5.5 3.5 11 3-8 1.5 2.5h10" />
    <path d="M46 17l11-7.5M52 9l5-.5-.8 5" />
  </Tile>
);

export const CheckItself = () => (
  <Tile>
    <Accent cx={56} cy={40} />
    <circle cx="25" cy="19" r="13.5" fill="#fff" /><path d="M34.8 28.8l9.7 9.7" strokeWidth="2.6" />
    <path d="M15 20h4l2-5 3.5 10 2.5-7 1.5 2h5.5" />
    <circle cx="24.5" cy="25" r="2.2" fill={RED} stroke="none" className="bad-part" />
  </Tile>
);

/* easy to try, easy to remove */

export const NoInstallFig = () => (
  <Fig vb="0 0 300 124" label="Your Mac sends a small Python check to the server over SSH, a status card comes back, and nothing is written on the server" className="fig-300">
    <Puddle tone="orange" cx="248" cy="88" rx="56" ry="14" />
    <Mac x={10} y={24} s={0.62} />
    <Server x={212} y={26} s={0.6} />
    <path d="M98 58H202" className="dash" />
    <rect x="136" y="51" width="28" height="14" fill="#fff" stroke="none" /><text x="150" y="62">ssh</text>
    <g className="go">
      <text x="150" y="23" className="ink">python3 -</text>
      <path d="M143 29h9l5 5v14h-14z" fill="#fff" /><path d="M152 29v5h5" /><path d="M146 39h7M146 43h5" className="thin" />
    </g>
    <g className="back">
      <rect x="135" y="69" width="30" height="18" rx="4" fill="#fff" />
      <circle cx="141" cy="75.5" r="2" fill={GREEN} stroke="none" /><path d="M146 75.5h13M140 81h19" className="thin" />
    </g>
    <path d="M171 104v8a7 2.5 0 0 0 14 0v-8" fill="#fff" /><ellipse cx="178" cy="104" rx="7" ry="2.5" fill="#fff" />
    <text x="191" y="112" className="start">writes nothing</text>
  </Fig>
);

export const RemovalArt = () => <Art w={130} h={112}><Puddle tone="orange" cx="65" cy="94" rx="65" ry="17" /><Server x={11} y={6} s={0.9} /></Art>;

/* sharing: four panels, 120x84 */

export const Share1 = () => (
  <Art w={120} h={84}>
    <rect x="10" y="3" width="62" height="78" rx="9" fill="#fff" />
    <path d="M22 16h28M22 24h20" /><path d="M22 52h38M22 60h38M22 68h30" className="hair" />
    <Ticket x={48} y={30} w={64} h={26} tone="pink" />
  </Art>
);
export const Share2 = () => (
  <Art w={120} h={84}>
    <Mac x={4} y={8} s={0.72} pulse={false} />
    <Ticket x={26} y={30} w={50} h={21} tone="pink" />
    <path d="M118 14c-4 14-12 22-34 26" className="dash" /><path d="M89.5 35.5l-5.5 4.5 6.5 2.5" />
  </Art>
);
export const Share3 = () => (
  <Art w={120} h={84}>
    <Ticket x={10} y={6} w={66} h={27} tone="pink" torn />
    <path d="M44 40c0 18 6 25 18 26" /><path d="M58 62l4.5 4-5 3" />
    <circle cx="76" cy="66" r="9" fill="#fff" stroke="none" /><circle cx="76" cy="66" r="9" fill={ht("pink")} /><circle cx="76" cy="66" r="2.5" fill="#fff" />
    <path d="M85 66h25M104 66v6M110 66v5" />
  </Art>
);
export const Share4 = () => (
  <Art w={120} h={84}>
    <path d="M3 3h98l16 16v62H3z" fill="#fff" /><path d="M101 3v16h16" />
    <text x="60" y="33" className="ink small">authorized_keys</text>
    <path d="M12 44h80M12 70h64" className="hair" />
    <rect x="9" y="51" width="102" height="12" rx="3" fill={ht("pink")} stroke="none" /><path d="M13 57h94" />
  </Art>
);

/* security */

export const SandboxFig = () => (
  <Fig vb="0 0 360 340" label="The agent sits in a sandbox. It reads disk, memory and services, writes only to /var/lib/flatline, never runs a shell, sends out to Telegram, your sites, your peers and your heartbeat URL, and accepts no incoming connections">
    {/* where it may send */}
    <path d="M96 33l30-14-12 26-6-9z" fill="#fff" /><path d="M108 36l18-17" />
    <circle cx="200" cy="31" r="13" fill="#fff" /><ellipse cx="200" cy="31" rx="5.5" ry="13" /><path d="M187 31h26" />
    <path d="M290 44c-10-6-15-11-13.5-17 1.4-5.5 8-6.5 11-2.5l2.5 3 2.5-3c3-4 9.6-3 11 2.5 1.5 6-3.5 11-13.5 17z" fill="#fff" /><path d="M280 31h4l2-4 3 8 2-5 1.5 1h5.5" className="thin" />
    <text x="111" y="64">Telegram</text><text x="200" y="64">sites, peers</text><text x="290" y="64">heartbeat</text>
    {[[111, 72], [200, 72], [290, 72]].map(([x, y]) => <path key={x} d={`M170 168L${x} ${y + 4}`} className="flow s16" />)}
    <path d="M106.8 81.5l3.8-5.1.5 6.4M197 80.5l3-4.4 2.5 4.6M286.5 80l4.9-3.6-.4 6" />
    {/* the sandbox */}
    <rect x="16" y="118" width="328" height="150" rx="16" className="dash ink-dash" />
    <rect x="30" y="110" width="66" height="16" fill="#fff" stroke="none" /><text x="63" y="122" className="ink">sandbox</text>
    {/* what it reads */}
    {[["disk", 140], ["memory", 177], ["services", 214]].map(([t, y]) => (
      <g key={t}>
        <rect x="34" y={y} width="76" height="23" rx="11.5" fill="#fff" /><text x="72" y={+y + 15.5}>{t}</text>
        <path d={`M112 ${+y + 11.5}L148 188`} className="dots" />
      </g>
    ))}
    <rect x="150" y="168" width="40" height="40" rx="11" fill="#fff" stroke="none" /><rect x="150" y="168" width="40" height="40" rx="11" fill={ht("violet")} />
    <path d="M155 189h7l3-8 5 16 4-11 2 3h8" />
    {/* no shell */}
    <rect x="222" y="138" width="36" height="26" rx="5" fill="#fff" /><path d="M229 145.5l5 5-5 5M237 157h8" />
    <path d="M216 168l48-34" stroke={RED} />
    <text x="240" y="184">no shell</text>
    {/* its own folder */}
    <path d="M192 196l90 18" className="dots" /><path d="M276 210l6.5 4-6 3" />
    <path d="M288 204h13l4 4.5h29v24h-46z" fill="#fff" /><path d="M318 230l13-13 3.2 3.2-13 13h-3.2z" fill="#fff" />
    <text x="336" y="254" className="end">/var/lib/flatline</text>
    {/* nothing comes in */}
    <path d="M150 316v-34M200 316v-34M145 287l5-6 5 6M195 287l5-6 5 6" className="soft" />
    <path d="M126 275h98" stroke={RED} strokeWidth="2.4" />
    <path d="M171 293l8 8m0-8l-8 8" stroke={RED} />
    <text x="232" y="290" className="start">no open ports</text>
    <text x="175" y="334">connections</text>
  </Fig>
);

// solid green up to 2.0, then a pale green → amber → red scale so "low is good" reads on its own
const scale = (i: number) => (i <= 4 ? GREEN : i <= 6 ? "#cdeedb" : i <= 12 ? "#fde3b8" : "#fcd0d6");
export const Gauge = () => {
  const pt = (v: number, r: number) => { const a = Math.PI - (v / 10) * Math.PI; return [100 + r * Math.cos(a), 100 - r * Math.sin(a)]; };
  return (
    <svg className="drawing gauge" viewBox="0 0 200 120" role="img" aria-label="Exposure scale from 0 (safe) to 10 (exposed), Flatline scores 2.0, OK">
      {Array.from({ length: 21 }, (_, i) => { const [x, y] = pt(i / 2, 84); return <circle key={i} cx={x} cy={y} r="3.6" fill={scale(i)} stroke="none" />; })}
      <text x="100" y="86" className="ink gnum">2.0</text>
      <text x="100" y="104" className="ok-t">OK</text>
      <text x="16" y="119" className="tiny">0</text><text x="184" y="119" className="tiny">10</text>
    </svg>
  );
};

export const KeychainArt = () => (
  <Art w={96} h={74}>
    <Mac x={2} y={2} s={0.72} pulse={false}>
      <circle cx="54" cy="44" r="9" />
      <circle cx="70" cy="58" r="6" fill="#fff" stroke="none" /><circle cx="70" cy="58" r="6" fill={ht("violet")} />
      <path d="M61 51l4 3M74.5 62.5L86 74M81 69l4-4M84 72l3-3" />
    </Mac>
  </Art>
);
export const ConfArt = () => (
  <Art w={70} h={76}>
    <path d="M10 3h36l15 15v55H10z" fill="#fff" /><path d="M46 3v15h15" />
    <path d="M18 30h32M18 40h32M18 50h22" className="hair" />
    <rect x="38" y="54" width="14" height="11" rx="2" fill="#fff" /><path d="M41 54v-3a4 4 0 0 1 8 0v3" />
  </Art>
);

export const PartnerFig = () => (
  <Fig vb="0 0 360 204" label="Your server is a building with a locked door and one small open window. Only a status card passes out of the window to your partner's Mac; a shell and a tunnel bounce off the door">
    <path d="M8 178h344" className="hair" />
    <path d="M28 66L100 28l72 38" /><rect x="36" y="62" width="128" height="116" fill="#fff" />
    <rect x="54" y="78" width="30" height="26" rx="2" /><path d="M69 78v26M54 91h30" className="thin" />
    <rect x="116" y="78" width="34" height="26" rx="2" /><path d="M116 78l-8-4v34l8-4M150 78l8-4v34l-8-4" fill="#fff" />
    <rect x="114" y="122" width="40" height="56" rx="3" fill="#fff" />
    <path d="M129 147v-4a5 5 0 0 1 10 0v4" /><rect x="126" y="147" width="16" height="12" rx="2.5" fill="#fff" />
    <path d="M161 91h6" className="dots" />
    <rect x="171" y="78" width="46" height="26" rx="5" fill="#fff" />
    <circle cx="180" cy="87" r="3" fill={GREEN} stroke="none" /><path d="M187 87h22M178 96h31" className="thin" />
    <path d="M222 91h26" className="dots" /><path d="M244 87.5l4.5 3.5-4.5 3.5" />
    <Mac x={254} y={50} s={0.72} pulse={false} />
    <rect x="276" y="130" width="30" height="22" rx="4" fill="#fff" /><path d="M282 136.5l4 4-4 4M289 146h7" className="thin" />
    <path d="M280 176a12 12 0 0 1 24 0M286 176a6 6 0 0 1 12 0" />
    <path d="M270 141H174M270 168H174" className="dash" />
    <path d="M174 136c4-7 10-9 16-7M174 163c4-7 10-9 16-7" className="soft" />
    <path d="M160 137l7 7m0-7l-7 7M160 164l7 7m0-7l-7 7" stroke={RED} />
    <text x="312" y="145" className="start small">shell</text><text x="312" y="174" className="start small">tunnel</text>
    <text x="100" y="198" className="ink">a window, not a door</text>
  </Fig>
);

export const TagArt = () => <Art w={64} h={52}><path d="M8 26l12-13h34v26H20z" fill="#fff" /><circle cx="24" cy="26" r="2.6" /><path d="M32 22h14M32 30h9" className="thin" /></Art>;
export const BuildArt = () => (
  <Art w={64} h={52}>
    <rect x="10" y="5" width="38" height="38" rx="7" fill="#fff" /><path d={gear(29, 24, 11, 8, 8)} /><circle cx="29" cy="24" r="3.2" />
    <path d="M45 45l-3 7M53 45l3 7" /><circle cx="49" cy="40" r="7.5" fill="#fff" stroke="none" /><circle cx="49" cy="40" r="7.5" fill={ht("violet")} />
  </Art>
);
export const PackageArt = () => (
  <Art w={64} h={52}>
    <rect x="6" y="9" width="52" height="36" rx="3" fill="#fff" /><path d="M6 18h52M28 9v9M36 9v9" />
    <rect x="6" y="25" width="52" height="13" fill="#fff" /><text x="32" y="35" className="ink small">SHA256</text>
  </Art>
);
export const VerifyArt = () => (
  <Art w={64} h={52}>
    <Server x={4} y={8} s={0.3} slots={3} />
    <path d="M50 10l10 4v9c0 8-5 12-10 14-5-2-10-6-10-14v-9z" fill="#fff" /><path d="M45.5 23l3.2 3.2 5.8-6.4" stroke={GREEN} />
  </Art>
);

/* install */

export const DmgFig = () => (
  <Fig vb="0 0 280 124" label="Drag the Flatline icon into the Applications folder" className="fig-280">
    <Puddle tone="peri" cx="140" cy="122" rx="110" ry="14" />
    <rect x="4" y="4" width="272" height="112" rx="10" fill="#fff" />
    <path d="M4 26h272" className="hair" />
    {[18, 31, 44].map(x => <circle key={x} cx={x} cy="15" r="3.6" stroke="#dcdce0" />)}
    <image href="./icon.png" x="40" y="38" width="52" height="52" />
    <text x="66" y="106">Flatline</text>
    <path d="M100 56c22-22 56-22 82-2" className="flow" /><path d="M176 48.5l6.5 5.5-8 2" />
    <path d="M190 46h16l5 5h29v35h-50z" fill="#fff" /><path d="M207 79l8-20 8 20M210 72h10" className="thin" />
    <text x="215" y="106">Applications</text>
  </Fig>
);

export const ServerInstallFig = () => (
  <Fig vb="0 0 280 124" label="The installer downloads the agent over HTTPS, checks it and starts it as a service" className="fig-280">
    <Puddle tone="peri" cx="140" cy="112" rx="96" ry="18" />
    <Server x={97} y={44} s={0.72} />
    <path d="M140 4v28M132 25l8 8 8-8" />
    <path d="M206 54l13 5v12c0 10-6 15-13 18-7-3-13-8-13-18v-12z" fill="#fff" /><path d="M200 71l4 4 7.5-8" stroke={GREEN} />
  </Fig>
);

export const FooterBeat = () => (
  <svg className="drawing beat" width="40" height="24" viewBox="0 0 40 24" aria-hidden="true"><path d="M0 12h12l3-6 5 13 4-10 2 3h14" /></svg>
);
