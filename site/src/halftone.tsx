import { useEffect, useRef } from "react";

// The same halftone as the Mac app: colour blobs printed as dots, fading into the paper at the top,
// with a lub-dub heartbeat rolling through. When something is down it turns red and holds still.
type Blob = [x: number, y: number, r: number, rgb: [number, number, number]];

const calm: Blob[] = [
  [0.1, 0.9, 0.3, [255, 189, 77]], [0.28, 0.7, 0.26, [255, 133, 56]], [0.5, 0.98, 0.3, [255, 41, 115]],
  [0.42, 0.62, 0.18, [255, 102, 158]], [0.74, 0.8, 0.26, [158, 97, 255]], [0.92, 0.45, 0.24, [133, 168, 255]],
  [0.03, 1.05, 0.2, [255, 230, 92]], [0.64, 1.05, 0.18, [255, 77, 71]],
];
const flatlined: Blob[] = [
  [0.15, 0.85, 0.34, [255, 77, 92]], [0.45, 1.0, 0.34, [240, 36, 102]], [0.4, 0.62, 0.18, [255, 117, 133]],
  [0.78, 0.75, 0.3, [255, 102, 107]], [0.95, 0.45, 0.22, [219, 51, 92]], [0.04, 1.05, 0.22, [209, 20, 61]],
];
const holes: [number, number, number][] = [[0.36, 0.5, 0.15], [0.86, 0.98, 0.12]];

const noise = (i: number, j: number) => {
  const s = Math.sin(i * 12.9898 + j * 78.233) * 43758.5453;
  return s - Math.floor(s);
};

// Per-dot noise never changes, so it is worked out once per canvas size instead of every frame.
type Grid = { cols: number; rows: number; jitter: Float32Array; grain: Float32Array };
function grid(cols: number, rows: number, blobs: number): Grid {
  const jitter = new Float32Array(cols * rows * blobs), grain = new Float32Array(cols * rows);
  for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) {
    grain[j * cols + i] = 0.8 + 0.4 * noise(i, j);
    for (let n = 0; n < blobs; n++) jitter[(j * cols + i) * blobs + n] = 0.7 + 0.6 * noise(i + 31 * n, j + 17 * n);
  }
  return { cols, rows, jitter, grain };
}

function paint(canvas: HTMLCanvasElement, g: { current: Grid | null }, t: number, alarm: boolean, step: number, dark: boolean) {
  const ratio = Math.min(window.devicePixelRatio || 1, 1.5);  // dots don't need retina sharpness
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !h) return;
  if (canvas.width !== Math.round(w * ratio) || canvas.height !== Math.round(h * ratio)) {
    canvas.width = Math.round(w * ratio);
    canvas.height = Math.round(h * ratio);
  }
  const blobs = alarm ? flatlined : calm, nb = blobs.length;
  const cols = Math.ceil(w / step), rows = Math.ceil(h / step);
  if (!g.current || g.current.cols !== cols || g.current.rows !== rows || g.current.jitter.length !== cols * rows * nb) g.current = grid(cols, rows, nb);
  const { jitter, grain } = g.current;
  const ctx = canvas.getContext("2d")!;
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, w, h);

  // everything that depends only on time is computed once per frame, not once per dot
  const bx = blobs.map((b, n) => b[0] + 0.12 * Math.sin(t * 0.55 + n * 1.9));
  const by = blobs.map((b, n) => b[1] + 0.09 * Math.cos(t * 0.45 + n * 1.9));
  const r2 = blobs.map(b => b[2] * b[2]);
  const hx = holes.map((hole, n) => hole[0] + 0.08 * Math.cos(t * 0.35 + n));
  const beat = (t / 1.4) % 1, paper = dark ? 0 : 255;
  const buckets = new Map<number, Path2D>();  // dots of one (rounded) colour are filled together

  for (let j = 0; j < rows; j++) {
    const y = j * step + step / 2, v = y / h, fade = Math.min(1, Math.max(0, (v - 0.08) / 0.6));
    if (fade <= 0) continue;
    for (let i = 0; i < cols; i++) {
      const x = i * step + step / 2, u = x / w, cell = j * cols + i;
      let weight = 0, r = 0, gr = 0, b = 0;
      for (let n = 0; n < nb; n++) {
        const du = u - bx[n], dv = v - by[n], d = (du * du * 2.2 + dv * dv) / r2[n];
        if (d > 9) continue;  // too far away to matter
        const k = Math.exp(-d) * jitter[cell * nb + n], c = blobs[n][3];
        weight += k; r += k * c[0]; gr += k * c[1]; b += k * c[2];
      }
      if (weight < 0.001) continue;
      let ink = Math.min(1, weight) * fade * grain[cell];
      for (let n = 0; n < holes.length; n++) {
        const du = u - hx[n], dv = v - holes[n][1];
        ink *= 1 - 0.9 * Math.exp(-(du * du * 2.2 + dv * dv) / (holes[n][2] * holes[n][2]));
      }
      let pulse = 0;
      if (!alarm) {
        const d = Math.hypot((u - 0.5) * 1.732, v - 1.15), a = (d - beat * 1.5) / 0.07;
        pulse = Math.exp(-a * a) * (1 - beat);
        if (beat > 0.16) { const c = (d - (beat - 0.16) * 1.5) / 0.06; pulse += 0.7 * Math.exp(-c * c) * (1 - beat); }
      }
      const radius = Math.min(step * 0.62, step * 0.58 * Math.sqrt(Math.min(1, ink + 0.35 * pulse)));
      if (radius < 0.35) continue;
      const wash = Math.min(0.85, (1 - fade) * 0.55 + 0.4 * pulse);
      const q = (c: number) => Math.round((c / weight + (paper - c / weight) * wash) / 17);  // 16 shades per channel
      const key = (q(r) << 8) | (q(gr) << 4) | q(b);
      let path = buckets.get(key);
      if (!path) buckets.set(key, (path = new Path2D()));
      path.moveTo(x + radius, y);
      path.arc(x, y, radius, 0, 6.2832);
    }
  }
  for (const [key, path] of buckets) {
    ctx.fillStyle = `rgb(${((key >> 8) & 15) * 17},${((key >> 4) & 15) * 17},${(key & 15) * 17})`;
    ctx.fill(path);
  }
}

export function Halftone({ alarm = false, step = 4.5, dark = false, className }: { alarm?: boolean; step?: number; dark?: boolean; className?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const cache = useRef<Grid | null>(null);
  useEffect(() => {
    const canvas = ref.current!;
    const still = alarm || matchMedia("(prefers-reduced-motion: reduce)").matches;
    let visible = false, frame = 0, last = 0;
    const draw = () => paint(canvas, cache, performance.now() / 1000, alarm, step, dark);
    const tick = (now: number) => {
      if (visible && !document.hidden && now - last > 45) { last = now; draw(); }  // ~22 fps, only on screen
      frame = requestAnimationFrame(tick);
    };
    const seen = new IntersectionObserver(([e]) => (visible = e.isIntersecting), { rootMargin: "100px" });
    const resized = new ResizeObserver(draw);
    seen.observe(canvas);
    resized.observe(canvas);
    draw();
    if (!still) frame = requestAnimationFrame(tick);
    return () => { cancelAnimationFrame(frame); seen.disconnect(); resized.disconnect(); };
  }, [alarm, step, dark]);
  return <canvas ref={ref} className={className} aria-hidden="true" />;
}
