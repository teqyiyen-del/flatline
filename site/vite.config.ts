import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// relative base, so the build works on any path (GitHub Pages serves it under /flatline/)
export default defineConfig({ base: "./", plugins: [react()] });
