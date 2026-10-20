import { useState } from "react";
import { ChevronLeft, Settings, X } from "lucide-react";
import { Halftone } from "./halftone";
import { healthy, long, short, type Server } from "./data";

// The menu bar panel, rebuilt for the web so visitors can click through it like the real app.
type Page = { name: "list" } | { name: "detail"; id: string } | { name: "settings" };

export function Panel({ servers, checked, onCheck }: { servers: Server[]; checked: number; onCheck: () => void }) {
  const [page, setPage] = useState<Page>({ name: "list" });
  const shown = page.name === "detail" ? servers.find(s => s.id === page.id) : undefined;
  const sick = servers.filter(s => !healthy(s));
  const alarm = shown ? !healthy(shown) : sick.length > 0;

  let headline: [string, string];
  if (shown) headline = [shown.id, shown.silent ? "is silent." : healthy(shown) ? "is breathing." : "needs you."];
  else if (sick.length === 0) headline = [`All ${servers.length} servers`, "are breathing."];
  else if (sick.length === 1) headline = [sick[0].id, "needs you."];
  else headline = [`${sick.length} servers`, "need you."];

  const ago = Math.max(1, Math.round((Date.now() - checked) / 1000));
  const subtitle = shown
    ? shown.silent ? "can't reach it over ssh" : `up ${long(shown.uptime)} · checked ${ago} sec ago`
    : sick.length ? sick.map(s => `${s.id}: ${s.problems[0]}`).join(" · ") : `Checked ${ago} sec ago · Telegram connected`;

  return (
    <div className="panel">
      <div className="hero-card">
        <div className="corner">
          {page.name === "detail" ? <button className="round" onClick={() => setPage({ name: "list" })} aria-label="Back"><ChevronLeft size={15} /></button> : <span />}
          <button className="round" onClick={() => setPage(page.name === "settings" ? { name: "list" } : { name: "settings" })} aria-label="Settings">
            {page.name === "settings" ? <X size={14} /> : <Settings size={14} />}
          </button>
        </div>
        <div className="headline" key={headline.join()}>{headline[0]}<br />{headline[1]}</div>
        <p className="subtitle">{subtitle}</p>
        <div className="art">
          <Halftone alarm={alarm} className="fill" />
          <button className="pill" onClick={onCheck}>{shown ? "Open SSH →" : "Check now →"}</button>
        </div>
      </div>
      <div className="list-card" key={page.name}>
        {page.name === "list" && <List servers={servers} open={id => setPage({ name: "detail", id })} />}
        {shown && <Detail server={shown} />}
        {page.name === "settings" && <Settings2 servers={servers} />}
      </div>
    </div>
  );
}

function List({ servers, open }: { servers: Server[]; open: (id: string) => void }) {
  return (
    <>
      <div className="cols head"><span>SERVERS</span><span>PULSE</span><span>CPU</span><span>RAM</span><span>DISK</span><span>UP</span></div>
      {servers.map(s => (
        <button key={s.id} className="row" onClick={() => open(s.id)}>
          <div className="cols">
            <span className="name"><i className={healthy(s) ? "dot ok" : "dot bad"} />{s.id}</span>
            {s.silent ? <span className="bad wide">no signal</span> : <>
              <Sparkline values={s.history.slice(-12)} bad={!healthy(s)} />
              <Num v={s.cpu} /><Num v={s.ram} /><Num v={s.disk} /><span className="muted">{short(s.uptime)}</span>
            </>}
          </div>
          {s.problems.length > 0 && <div className="problem">{s.problems.join(" · ")}</div>}
        </button>
      ))}
    </>
  );
}

export function Detail({ server: s }: { server: Server }) {
  if (s.silent) return (
    <div className="detail">
      <h4>NO SIGNAL</h4>
      <p className="bad">can't reach it over ssh</p>
      <p className="muted">Flatline couldn't run flatline status here over SSH. Check that the server is up and the agent is installed.</p>
    </div>
  );
  const peak = Math.round(Math.max(...s.history));
  return (
    <div className="detail">
      <div className="tiles">
        <Tile label="CPU" v={s.cpu} caption={`${s.cores} cores`} />
        <Tile label="RAM" v={s.ram} caption={`${Math.round((s.ram / 100) * s.memTotal * 10) / 10} / ${s.memTotal} GB`} />
        <Tile label="DISK" v={s.disk} caption={`${Math.round((s.disk / 100) * s.diskTotal)} / ${s.diskTotal} GB`} />
      </div>
      <h4>CPU · LAST 30 MIN · PEAK {peak}%</h4>
      <DotChart values={s.history} />
      {s.problems.length > 0 && <><h4>PROBLEMS</h4>{s.problems.map(p => <p key={p} className="bad">• {p}</p>)}</>}
      <h4>SYSTEM</h4>
      <Info k="Uptime" v={long(s.uptime)} /><Info k="Load" v={s.load.map(n => n.toFixed(2)).join("  ")} /><Info k="OS" v={s.os} /><Info k="Kernel" v={s.kernel} /><Info k="SSH" v={s.id} />
      {s.pm2.length > 0 && <><h4>PM2 · {s.pm2.length}</h4>{s.pm2.map(a => <Item key={a.name} ok={a.status === "online"} name={a.name} detail={`${a.cpu}%  ${a.mem} MB  ↺ ${a.restarts}`} />)}</>}
      {s.docker.length > 0 && <><h4>DOCKER · {s.docker.length}</h4>{s.docker.map(c => <Item key={c.name} ok={c.ok} name={c.name} detail={c.status} />)}</>}
    </div>
  );
}

function Settings2({ servers }: { servers: Server[] }) {
  const [live, setLive] = useState(true);
  const [login, setLogin] = useState(false);
  return (
    <div className="detail settings">
      <h4>SERVERS</h4>
      {servers.slice(0, 3).map(s => <div key={s.id} className="field">{s.id}<X size={12} /></div>)}
      <div className="field-row"><input placeholder="user@host or ssh alias" aria-label="Server" /><button className="pill light">Add</button></div>
      <h4>TELEGRAM</h4>
      <p className="muted small">1. Open @BotFather, send /newbot and paste the token.<br />2. Send your bot any message, then connect.</p>
      <div className="field-row"><input placeholder="Connected · paste a new token to switch" aria-label="Bot token" type="password" /><button className="pill">Connect →</button></div>
      <Switch label="Live dashboard in Telegram" on={live} set={setLive} />
      <h4>GENERAL</h4>
      <Switch label="Open at login" on={login} set={setLogin} />
    </div>
  );
}

const level = (v: number) => (v >= 90 ? "bad" : v >= 70 ? "warn" : "");
const Num = ({ v }: { v: number }) => <span className={`num ${level(v)}`}>{Math.round(v)}</span>;
const Info = ({ k, v }: { k: string; v: string }) => <div className="info"><span className="muted">{k}</span><span>{v}</span></div>;
const Item = ({ ok, name, detail }: { ok: boolean; name: string; detail: string }) => (
  <div className="info"><span><i className={ok ? "dot ok" : "dot bad"} />{name}</span><span className={ok ? "muted" : "bad"}>{detail}</span></div>
);
const Switch = ({ label, on, set }: { label: string; on: boolean; set: (v: boolean) => void }) => (
  <button className="switch-row" onClick={() => set(!on)}><span>{label}</span><span className={on ? "switch on" : "switch"}><i /></span></button>
);

function Tile({ label, v, caption }: { label: string; v: number; caption: string }) {
  return (
    <div className="tile">
      <span className="muted tiny">{label}</span>
      <b className={level(v)}>{Math.round(v)}%</b>
      <span className="bar"><i className={level(v) || "ok"} style={{ width: `${Math.min(v, 100)}%` }} /></span>
      <span className="muted tiny">{caption}</span>
    </div>
  );
}

export function Sparkline({ values, bad }: { values: number[]; bad: boolean }) {
  const low = Math.min(...values), span = Math.max(Math.max(...values) - low, 10);
  const points = values.map((v, i) => `${(i / (values.length - 1)) * 40},${14 - ((v - low) / span) * 14}`).join(" ");
  return <svg className="spark" viewBox="-1 -1 42 16"><polyline points={points} fill="none" stroke={bad ? "#f0384f" : "#c2c2c8"} strokeWidth="1.3" strokeLinejoin="round" strokeLinecap="round" /></svg>;
}

// CPU history printed as halftone columns, on its own scale so a calm server still shows a pulse
export function DotChart({ values }: { values: number[] }) {
  const columns = 60, rows = 12, top = Math.max(Math.max(...values) * 1.25, 10);
  const ink = (h: number) => {
    const stops = [[140, 168, 255], [255, 51, 128], [255, 158, 66]];
    const x = h * 2, i = Math.min(Math.floor(x), 1), f = x - i;
    return `rgb(${stops[i].map((a, n) => Math.round(a + (stops[i + 1][n] - a) * f)).join(",")})`;
  };
  return (
    <svg className="chart" viewBox={`0 0 ${columns * 5} ${rows * 5}`}>
      {values.slice(-columns).flatMap((v, c) => {
        const lit = Math.max(1, Math.ceil((v / top) * rows));
        return Array.from({ length: rows }, (_, r) => (
          <circle key={`${c}-${r}`} cx={c * 5 + 2.5} cy={(rows - r) * 5 - 2.5} r={r < lit ? 1.6 : 0.7} fill={r < lit ? ink(r / (rows - 1)) : "#ececef"} />
        ));
      })}
    </svg>
  );
}
