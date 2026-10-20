import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import Lenis from "lenis";
import "lenis/dist/lenis.css";
import App from "./App";
import "./styles.css";

// smooth, inertial scrolling, left off for people who ask their system for less motion
if (!matchMedia("(prefers-reduced-motion: reduce)").matches) new Lenis({ autoRaf: true, anchors: true, lerp: 0.12 });

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
