import { useEffect, useState } from "react";

// A pretend fleet for the demo. Numbers wander every couple of seconds, like the real thing.
export type Server = {
  id: string; cpu: number; ram: number; disk: number; uptime: number; history: number[];
  problems: string[]; silent: boolean; cores: number; memTotal: number; diskTotal: number;
  load: [number, number, number]; os: string; kernel: string;
  pm2: { name: string; status: string; cpu: number; mem: number; restarts: number }[];
  docker: { name: string; ok: boolean; status: string }[];
};

const seed = (id: string, cpu: number, ram: number, disk: number, days: number, extra: Partial<Server> = {}): Server => ({
  id, cpu, ram, disk, uptime: days * 86400 + 37000, problems: [], silent: false, cores: 4, memTotal: 6, diskTotal: 50,
  load: [0.42, 0.31, 0.27], os: "Ubuntu 24.04.1 LTS", kernel: "6.8.0-45-generic", pm2: [], docker: [],
  history: Array.from({ length: 60 }, (_, i) => clamp(cpu + 9 * Math.sin(i / 4) + ((i * 37 + id.length * 11) % 23) - 11)),
  ...extra,
});

const clamp = (n: number) => Math.max(1, Math.min(99, n));

export const initial = (): Server[] => [
  seed("web-1", 12, 41, 48, 18, {
    pm2: [{ name: "storefront", status: "online", cpu: 2, mem: 159, restarts: 0 }, { name: "admin", status: "online", cpu: 1, mem: 283, restarts: 3 }],
    docker: [{ name: "analytics", ok: true, status: "Up 2 weeks" }, { name: "analytics-db", ok: true, status: "Up 2 weeks (healthy)" }],
  }),
  seed("web-2", 18, 52, 48, 18, { pm2: [{ name: "storefront", status: "online", cpu: 4, mem: 171, restarts: 0 }] }),
  seed("api-1", 34, 61, 33, 10, { pm2: [{ name: "api", status: "online", cpu: 21, mem: 412, restarts: 1 }, { name: "jobs", status: "online", cpu: 8, mem: 230, restarts: 0 }] }),
  seed("api-2", 46, 58, 61, 4, { pm2: [{ name: "api", status: "online", cpu: 30, mem: 455, restarts: 0 }, { name: "jobs", status: "online", cpu: 11, mem: 512, restarts: 2 }] }),
  seed("worker-1", 55, 47, 72, 30, { docker: [{ name: "queue", ok: true, status: "Up 30 days" }] }),
  seed("db-1", 22, 71, 84, 64, { docker: [{ name: "postgres", ok: true, status: "Up 9 weeks (healthy)" }] }),
  seed("db-2", 17, 66, 58, 64, { docker: [{ name: "replica", ok: true, status: "Up 9 weeks (healthy)" }] }),
  seed("edge-eu", 15, 30, 26, 2),
];

export function useFleet() {
  const [servers, setServers] = useState(initial);
  const [checked, setChecked] = useState(() => Date.now());
  const [outage, setOutage] = useState(false);

  useEffect(() => {
    const id = setInterval(() => {
      setServers(list => list.map(s => {
        if (s.silent) return s;
        const cpu = clamp(s.cpu + (Math.random() - 0.5) * 10);
        return { ...s, cpu, ram: clamp(s.ram + (Math.random() - 0.5) * 2), uptime: s.uptime + 2, history: [...s.history.slice(1), cpu] };
      }));
      setChecked(Date.now());
    }, 2000);
    return () => clearInterval(id);
  }, []);

  // the demo outage: api-2 runs out of memory and loses an app, db-2 stops answering
  const toggleOutage = () => {
    setOutage(on => {
      const next = !on;
      setServers(list => list.map(s => {
        if (s.id === "api-2") return next
          ? { ...s, ram: 93, cpu: 76, problems: ["ram above 90%", "pm2 api down"], pm2: s.pm2.map(a => a.name === "api" ? { ...a, status: "errored", cpu: 0, mem: 0, restarts: 15 } : a) }
          : { ...s, ram: 58, cpu: 46, problems: [], pm2: s.pm2.map(a => a.name === "api" ? { ...a, status: "online", cpu: 30, mem: 455, restarts: 15 } : a) };
        if (s.id === "db-2") return { ...s, silent: next, problems: next ? ["can't reach it over ssh"] : [] };
        return s;
      }));
      return next;
    });
  };

  return { servers, checked, outage, toggleOutage };
}

export const healthy = (s: Server) => !s.silent && s.problems.length === 0;
export const short = (s: number) => (s >= 86400 ? `${Math.floor(s / 86400)}d` : s >= 3600 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 60)}m`);
export const long = (s: number) => (s >= 86400 ? `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h` : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`);
