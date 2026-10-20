import { useState, type ReactNode } from "react";
import { ArrowDown, ArrowRight, BadgeCheck, Check, Copy, Download, EyeOff, FileText, Lock, Moon, Pencil, Pin, Plus, Send, UserX, X } from "lucide-react";
import { MacDemo } from "./MacDemo";
import { Detail } from "./Panel";
import { initial } from "./data";
import * as A from "./Illustrations";

const REPO = "https://github.com/teqyiyen-del/flatline";
const DMG = `${REPO}/releases/latest/download/Flatline.dmg`;
const INSTALL = `curl -fsSL ${REPO}/releases/latest/download/install.sh | sudo bash`;
const SOURCE = `git clone ${REPO} && ./flatline/app/build.sh`;
const POLICY = `${REPO}/blob/main/SECURITY.md`;
const web1 = initial()[0];  // a frozen copy of the demo's web-1: no interval, nothing moves

const GitHub = () => (
  <svg viewBox="0 0 16 16" width="15" height="15" fill="currentColor" aria-hidden="true">
    <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
  </svg>
);

function Command({ text, compact = false }: { text: string; compact?: boolean }) {
  const [done, setDone] = useState(false);
  return (
    <div className={compact ? "command compact" : "command"}>
      <code>{text.split(/(?<=\/)/).map((part, i) => <span key={i}>{part}<wbr /></span>)}</code>
      <button type="button" onClick={async () => { await navigator.clipboard.writeText(text); setDone(true); setTimeout(() => setDone(false), 1500); }} aria-label="Copy command">
        {done ? <Check size={14} /> : <Copy size={14} />}
      </button>
    </div>
  );
}

const Sec = ({ id, title, line, children }: { id: string; title: string; line?: string; children: ReactNode }) => (
  <section id={id} className="sec" aria-labelledby={`${id}-h`}>
    <h2 id={`${id}-h`}>{title}</h2>
    {line && <p className="lead">{line}</p>}
    {children}
  </section>
);

// Story: fixed-size drawings with HTML captions, joined by dotted links
const Node = ({ art, title, sub, more, n }: { art: ReactNode; title: string; sub?: ReactNode; more?: ReactNode; n?: number }) => (
  <figure className="node">
    <div className="node-art">{art}</div>
    <figcaption>
      {n && <span className="num-dot">{n}</span>}
      <b>{title}</b>
      {sub && <span>{sub}</span>}
      {more}
    </figcaption>
  </figure>
);
const Link = ({ label, flow = "" }: { label?: string; flow?: string }) => (
  <div className={`link ${flow}`}>{label && <span>{label}</span>}<i aria-hidden="true" /></div>
);
const Code = ({ children }: { children: ReactNode }) => <code className="code">{children}</code>;
const ic = { size: 14, strokeWidth: 1.6 };

export default function App() {
  return (
    <>
      <A.HalftoneDefs />
      <header className="top">
        <a className="brand" href="#"><img src="./icon.png" alt="" />Flatline</a>
        <div className="top-right">
          <a className="text-link" href="#security">Security</a>
          <a className="icon-link" href={REPO} aria-label="GitHub"><GitHub /></a>
          <a className="button small" href={DMG}>Download</a>
        </div>
      </header>

      <main>
        <section className="hero">
          <h1>Know before your server flatlines.</h1>
          <p className="lead">Your Linux servers in the Mac menu bar. Alerts on Telegram.</p>
          <div className="actions">
            <a className="button" href={DMG}><Download size={15} />Download for Mac</a>
            <a className="button quiet" href={REPO}><GitHub />Source</a>
          </div>
          <p className="meta">Free and open source (MIT) · macOS 14+ · Apple silicon and Intel</p>
        </section>

        <section className="wrap demo-wrap" aria-labelledby="demo-h">
          <h2 id="demo-h" className="sr-only">Live demo</h2>
          <MacDemo />
        </section>

        <How />
        <Checks />
        <Alerts />
        <ServerPage />
        <Easy />
        <Sharing />
        <Security />
        <Install />
        <Faq />
      </main>

      <footer className="foot">
        <div className="flat" aria-hidden="true"><i /><A.FooterBeat /><i /></div>
        <div className="foot-row">
          <a className="brand" href="#"><img src="./icon.png" alt="" />Flatline</a>
          <nav><a href={REPO}>Source</a><a href={`${REPO}/releases`}>Releases</a><a href={POLICY}>Security policy</a><a href={`${REPO}/blob/main/LICENSE`}>MIT license</a></nav>
        </div>
      </footer>
    </>
  );
}

function How() {
  return (
    <Sec id="how" title="How it works" line="An agent on each server sends the alerts. Your Mac asks it for the details.">
      <div className="story how">
        <Node art={<A.PhoneArt />} title="Telegram" sub="alerts from your own bot" />
        <Link label="alerts" flow="left" />
        <Node art={<A.ServerArt />} title="your server" sub="one Python file, checks every 60 s" more={<small>/usr/local/bin/flatline</small>} />
        <Link label="ssh" flow="left slow" />
        <Node art={<A.MacArt />} title="your Mac" sub="asks over SSH every 30 s" />
      </div>
      <p className="support">Alerts come from the servers themselves, so they keep coming while your Mac is off.</p>
    </Sec>
  );
}

const checks = [
  [A.CheckDisk, "disk", "90% full or more"],
  [A.CheckMemory, "memory", "90% used or more"],
  [A.CheckSystemd, "systemd", "any failed service"],
  [A.CheckPm2, "pm2", "an app not online, or the pm2 daemon dying"],
  [A.CheckDocker, "Docker", <>a container unhealthy or <span className="nb">restart-looping</span>, or Docker stopping</>],
  [A.CheckSites, "websites", "5xx, timeout or certificate error"],
  [A.CheckPeers, "other servers", "stop answering on their SSH port"],
  [A.CheckHeartbeat, "heartbeat", "pinged every check, optional"],
  [A.CheckItself, "itself", "says so if one of its own checks breaks"],
] as const;

function Checks() {
  return (
    <Sec id="checks" title="What it checks" line="Every 60 seconds by default, or anything from 10 seconds to an hour. You set the disk and memory limits.">
      <ul className="checks">
        {checks.map(([Icon, title, sub]) => <li key={title}><Icon /><b>{title}</b><span>{sub}</span></li>)}
      </ul>
      <p className="note">Any ping URL works, like healthchecks.io or an Uptime Kuma push monitor. If the pings stop, that service warns you.</p>
    </Sec>
  );
}

const strip = ["ok", "ok", "blip", "ok", "ok", "bad", "bad", "bad", "ok", "ok"];
const at = (i: number) => ({ left: `${(i * 100) / 9}%` });

function Alerts() {
  return (
    <Sec id="alerts" title="Alerts on Telegram" line="From your own bot. A problem must show up on two checks in a row. You also hear when it's fixed.">
      <div className="alerts">
        <div className="strip">
          <div className="strip-line" aria-hidden="true">{strip.map((s, i) => <i key={i} className={`sd ${s}`} style={at(i)} />)}</div>
          <span className="tag up" style={at(6)}><Send size={12} strokeWidth={1.6} />alert sent</span>
          <span className="tag down" style={at(2)}>blip · no message</span>
          <span className="tag down" style={at(8)}><Check size={12} strokeWidth={2.2} className="ok" />recovered</span>
          <span className="time" style={at(0)}>14:01</span><span className="time" style={at(9)}>14:10</span>
          <span className="strip-cap">one dot = one check</span>
        </div>

        <div className="phone-wrap">
          <div className="phone">
            <div className="phone-head"><img src="./icon.png" alt="" /><b>Flatline bot</b></div>
            <div className="pinned"><Pin size={12} strokeWidth={1.6} /><span>FLATLINE  3/3 alive · 14:09</span></div>
            <div className="chat">
              <div className="msg m1">
                <p className="msg-h"><i className="red-dot" /><b>api-2</b></p>
                <p>• pm2 api down</p><p>• ram above 90%</p><time>14:07</time>
              </div>
              <div className="msg m2">
                <p className="msg-h"><span className="green-check"><Check size={9} strokeWidth={3} /></span><b>api-2 recovered</b></p>
                <p>• pm2 api down</p><p>• ram above 90%</p><time>14:09</time>
              </div>
            </div>
          </div>
          <p className="side-note">
            <svg className="drawing hand" width="48" height="30" viewBox="0 0 48 30" aria-hidden="true"><path d="M46 23C32 27 15 22 5 9" /><path d="M5.5 17L4.5 8.5l8 .8" /></svg>
            Optional: a live dashboard pinned in the chat, kept fresh by your Mac app.
          </p>
        </div>
        <p className="support">Set up once in the app's settings. The token is kept in your Keychain and in a root-only file on each server.</p>
      </div>
    </Sec>
  );
}

const legend = ["opens SSH in Terminal", "memory and disk, in GB", "CPU, last 30 minutes", "load, OS, kernel", "pm2 apps", "Docker containers"];

function ServerPage() {
  return (
    <Sec id="server-page" title="A page for every server" line="Click a server in the menu bar to see what it's doing.">
      <div className="sp">
        <div className="sp-wrap">
          <svg className="sp-dots" viewBox="0 0 240 200" aria-hidden="true"><ellipse cx="120" cy="100" rx="120" ry="100" fill="url(#ht-violet)" mask="url(#ht-fade)" /></svg>
          <div className="list-card sp-card">
            <div className="sp-head">
              <div className="headline">web-1<br />is breathing.</div>
              <p className="subtitle">up 18d 10h · checked 4 sec ago</p>
              <div className="sp-pill"><span className="pill">Open SSH →</span></div>
            </div>
            <Detail server={web1} />
          </div>
        </div>
        <ol className="legend">{legend.map((t, i) => <li key={t}><span>{i + 1}</span>{t}</li>)}</ol>
      </div>
    </Sec>
  );
}

const removed = [["program", "/usr/local/bin/flatline"], ["service", "flatline.service"], ["settings", "/etc/flatline.conf"], ["state", "/var/lib/flatline"], ["sharing account", "flatline user"]];

function Easy() {
  return (
    <Sec id="easy" title="Easy to try, easy to remove" line="Look at a server without installing anything on it. Remove Flatline in one step.">
      <div className="duo">
        <article className="card">
          <h3>No-install mode</h3>
          <A.NoInstallFig />
          <div className="card-foot">
            <Code>python3 - status --json --live</Code>
            <p className="cap">No agent on a server? The app runs the same check once over SSH and writes nothing there.</p>
            <p className="trade"><Moon {...ic} />No Telegram alerts for it. You see problems in the menu bar while your Mac is on.</p>
          </div>
        </article>
        <article className="card removal">
          <h3>Clean removal</h3>
          <div className="rm">
            <A.RemovalArt />
            <div className="rm-lists">
              <ul className="rm-list">{removed.map(([w, p]) => <li key={w}><span>{w}</span><code>{p}</code></li>)}</ul>
              <p className="rm-journal"><span>old journal lines</span><code>rotate away</code></p>
            </div>
          </div>
          <div className="ways">
            <span className="rm-btn">× next to the server →<span className="pill">Remove from server too</span></span>
            <span className="or">or</span>
            <Command text="sudo flatline uninstall" compact />
          </div>
        </article>
      </div>
    </Sec>
  );
}

function Sharing() {
  return (
    <Sec id="sharing" title="Share a server with a partner" line="Send a one-time invite. They see the status, nothing else.">
      <div className="story share">
        <Node n={1} art={<A.Share1 />} title="create an invite" sub="on the server's page. Works once, expires after 24 h." />
        <Link flow="right" />
        <Node n={2} art={<A.Share2 />} title="they paste it" sub="into their own Flatline" />
        <Link flow="right" />
        <Node n={3} art={<A.Share3 />} title="keys swap" sub="their app trades the invite's throwaway key for its own ed25519 key" />
        <Link flow="right" />
        <Node n={4} art={<A.Share4 />} title="one line on your server" sub="read only. See Security below." />
      </div>
      <p className="revoke"><UserX {...ic} />Revoke any time in the app, or run <Code>sudo flatline revoke NAME</Code></p>
      <p className="note">Your partner needs to reach the server's SSH port.</p>
    </Sec>
  );
}

const attempts: [string, string, string][] = [
  ["read the status", "status", "good"],
  ["ask for a shell", "just the status", ""],
  ["run another command", "just the status", ""],
  ["forward a port", "refused", "no"],
  ["reuse the invite", "refused", "no"],
];

function Security() {
  return (
    <Sec id="security" title="What Flatline can and can't do" line="It opens no ports, never runs a shell, and lives in a tight sandbox.">
      <div className="sec-grid">
        <article className="sc full sc-a">
          <h3>What the agent does</h3>
          <div className="sc-a-body">
            <A.SandboxFig />
            <div className="can">
              <h4>It can</h4>
              <ul>
                <li><Check {...ic} className="ok" />read system state: disk, memory, services, pm2, Docker</li>
                <li><Check {...ic} className="ok" />reach Telegram, your sites, your peers and your heartbeat URL</li>
              </ul>
              <h4>It never</h4>
              <ul>
                <li><X {...ic} className="bad" />opens a port or accepts a connection</li>
                <li><X {...ic} className="bad" />runs a shell</li>
              </ul>
              <h4>The sandbox stops it from</h4>
              <ul>
                <li><X {...ic} className="bad" />changing system files or home folders</li>
                <li><X {...ic} className="bad" />gaining new privileges</li>
              </ul>
            </div>
          </div>
        </article>

        <article className="sc">
          <h3>The sandbox</h3>
          <ul className="tree">
            <li><code>/</code><span><Lock {...ic} />read-only</span></li>
            <li><code>/home</code><span><Lock {...ic} />read-only</span></li>
            <li><code>/tmp, /dev</code><span><EyeOff {...ic} />private</span></li>
            <li className="own"><code>/var/lib/flatline</code><span><Pencil {...ic} />its own, writable</span></li>
          </ul>
          <p className="chips"><span className="chip">no capabilities</span><span className="chip">NoNewPrivileges</span><span className="chip">system call filter</span></p>
          <A.Gauge />
          <p className="cap center">systemd-analyze rates its exposure 2.0, OK. Lower is safer.</p>
        </article>

        <article className="sc">
          <h3>Where secrets live</h3>
          <div className="story mini">
            <Node art={<A.KeychainArt />} title="Keychain" sub="on your Mac" />
            <Link label="SSH standard input" flow="right" />
            <Node art={<A.ConfArt />} title="/etc/flatline.conf" more={<span className="chip">root only · 600</span>} />
          </div>
          <p className="never"><X {...ic} className="bad" />never on a command line</p>
          <div className="url">
            <code className="code">
              <s>https://</s><wbr /><s>user:pass@</s><wbr />shop.example.com/health<wbr /><s>?key=abc</s>
            </code>
            <ArrowDown size={14} strokeWidth={1.6} className="url-arrow" aria-hidden="true" />
            <code className="code">site shop.example.com/health down</code>
            <p className="cap">Passwords and query strings are cut from alerts.</p>
          </div>
          <p className="strict"><span>strict input checks</span><span className="chip">exact token format</span><span className="chip">no line breaks in config</span><span className="chip">unknown keys ignored</span></p>
        </article>

        <article className="sc full sc-d">
          <h3>What a partner can do</h3>
          <div className="sc-d-body">
            <A.PartnerFig />
            <div>
              <p className="ak-title"><FileText {...ic} />authorized_keys · flatline account</p>
              <code className="code ak-line">
                <mark className="v">restrict</mark>,<wbr /><mark className="o">command="/usr/local/bin/flatline status <span className="nb">--json"</span></mark> ssh-ed25519 AAAAC3Nz… flatline-guest-ayse
              </code>
              <ul className="attempts">
                {attempts.map(([a, r, k]) => <li key={a}><span className="chip">{a}</span><ArrowRight size={12} strokeWidth={1.6} /><span className={`chip ${k}`}>{r}</span></li>)}
              </ul>
              <p className="pinline"><Pin {...ic} />Their app pins your server's host key from the invite.</p>
            </div>
          </div>
        </article>

        <article className="sc full sc-e" id="verify">
          <h3>How downloads are checked</h3>
          <div className="story e">
            <Node art={<><A.TagArt /><i className="vcheck" /></>} title="tagged commit" />
            <Link />
            <Node art={<><A.BuildArt /><i className="vcheck" /></>} title="built by GitHub Actions" sub="signed build provenance" />
            <Link />
            <Node art={<><A.PackageArt /><i className="vcheck" /></>} title="release + SHA256 checksums" />
            <Link />
            <Node art={<><A.VerifyArt /><i className="vcheck" /></>} title="installer checks" sub="HTTPS only, checksum must match, refuses local files other users could swap" />
          </div>
          <p className="hash"><code>9f2c…e41a</code><b>=</b><code>9f2c…e41a</code></p>
          <div className="verify"><span>Check any download yourself</span><Command text="gh attestation verify Flatline.dmg --repo teqyiyen-del/flatline" compact /></div>
        </article>
      </div>
      <p className="review"><BadgeCheck {...ic} /><span>Every commit is tested and security-scanned on GitHub. Found a problem? <a href={POLICY}>Report it privately →</a></span></p>
    </Sec>
  );
}

function Install() {
  return (
    <Sec id="install" title="Install" line="The app on your Mac. The agent on each server, if you want alerts.">
      <div className="duo">
        <article className="card">
          <h3>Mac</h3>
          <A.DmgFig />
          <ol className="steps">
            <li><a href={DMG}>Download Flatline.dmg</a></li>
            <li>Drag it to Applications</li>
            <li><span>First launch only: System Settings → Privacy & Security → <span className="mock-btn">Open Anyway</span></span></li>
          </ol>
          <p className="cap">Not notarized yet, so you can <a href="#verify">check the download</a> yourself. macOS 14+, Apple silicon and Intel.</p>
        </article>
        <article className="card">
          <h3>Server</h3>
          <A.ServerInstallFig />
          <Command text={INSTALL} />
          <p className="cap">HTTPS only. Checked against the release's SHA256 checksums, then started as a systemd service.</p>
          <p className="cap">Then add the server in the app (user@host or an SSH alias) and connect Telegram in its settings. The app hands the token over SSH.</p>
        </article>
      </div>
      <div className="from-source"><span>From source</span><Command text={SOURCE} compact /></div>
    </Sec>
  );
}

const faq: [string, ReactNode][] = [
  ["Is it free?", "Yes. Flatline is MIT licensed and free, and Telegram bots are free too."],
  ["Do alerts still come when my Mac is off?", "Yes. The agent on each server sends alerts to Telegram itself. Only the menu bar view and the pinned dashboard pause. A server in no-install mode has no agent, so it never sends alerts. You only see it in the menu bar while your Mac is on."],
  ["Does Flatline open a port on my server?", "No. The agent accepts no connections. It only makes outgoing requests: to Telegram, the sites and peers you list, and your heartbeat URL. Your Mac reads it over the SSH you already use, with your existing keys."],
  ["What does a server need?", "Linux with systemd and Python 3.8 or newer. The agent is one file of about 570 lines that uses only the standard library, so you can read it before you run it."],
  ["What if a whole server dies?", "A dead server can't send anything. Your other servers can watch it as a peer and tell you when its SSH port stops answering. With a single server, add a heartbeat URL (healthchecks.io or an Uptime Kuma push monitor). That service warns you when the pings stop."],
  ["Will a short spike wake me up?", "No. A problem has to show up on two checks in a row before you get a message. You get one more message when it recovers."],
  ["How do I connect Telegram?", <>In the app's settings: create a bot with <Code>@BotFather</Code>, paste its token, send the bot a message, then press Connect. The token stays in your macOS Keychain and reaches your servers over SSH standard input, never on a command line.</>],
  ["Why does macOS warn me the first time?", "The app isn't notarized yet. Open System Settings → Privacy & Security and click Open Anyway. You only do this once."],
];

function Faq() {
  return (
    <Sec id="faq" title="Questions">
      <div className="faq">
        {faq.map(([q, a]) => <details key={q}><summary>{q}<Plus size={14} strokeWidth={1.6} /></summary><p>{a}</p></details>)}
      </div>
    </Sec>
  );
}
