import { useEffect, useState } from "react";
import { Activity, BatteryFull, Folder, Globe, HeartCrack, Mail, Search, Send, SquareTerminal, Wifi } from "lucide-react";
import { Panel } from "./Panel";
import { Halftone } from "./halftone";
import { healthy, useFleet } from "./data";

// A pretend Mac screen with Flatline running in the menu bar. Everything in it is clickable.
export function MacDemo() {
  const { servers, checked, outage, toggleOutage } = useFleet();
  const [open, setOpen] = useState(true);
  const [toast, setToast] = useState(false);
  const [now, setNow] = useState(() => new Date());
  const down = servers.filter(s => !healthy(s)).length;

  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), 15000);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    if (!outage) return;
    setToast(true);
    const id = setTimeout(() => setToast(false), 5200);
    return () => clearTimeout(id);
  }, [outage]);

  const clock = now.toLocaleString("en-US", { weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false }).replace(",", "");

  return (
    <div className="demo">
      <div className="screen">
        <div className="wallpaper"><Halftone dark step={8} className="wall-art" /></div>
        <header className="menubar">
          <b>Flatline</b><span>File</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span>
          <div className="tray">
            <button className={`tray-btn ${open ? "active" : ""} ${down ? "alarm" : ""}`} onClick={() => setOpen(o => !o)} aria-label="Flatline">
              {down ? <><HeartCrack size={15} /><small>{down}</small></> : <Activity size={15} />}
            </button>
            <Wifi size={15} /><BatteryFull size={17} /><Search size={14} />
            <span className="clock">{clock}</span>
          </div>
        </header>

        <div className={`toast ${toast ? "in" : ""}`} role="status">
          <span className="toast-icon"><Send size={15} /></span>
          <div><b>Flatline bot</b><p>api-2 · pm2 api down · ram above 90%</p></div>
          <span className="muted tiny">now</span>
        </div>

        <div className={`drop ${open ? "open" : ""}`}>
          <Panel servers={servers} checked={checked} onCheck={() => setOpen(true)} />
        </div>

        <nav className="dock" aria-hidden="true">
          <span><Folder size={22} /></span><span><Globe size={22} /></span><span><Mail size={22} /></span>
          <span><SquareTerminal size={22} /></span><span className="me"><img src="./icon.png" alt="" /></span>
        </nav>
      </div>
      <div className="demo-bar">
        <span>Try it: open the panel from the menu bar, click a server, open the gear.</span>
        <button className={`btn ${outage ? "light" : ""}`} onClick={toggleOutage}>{outage ? "Recover everything" : "Simulate an outage"}</button>
      </div>
    </div>
  );
}
