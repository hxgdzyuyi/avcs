import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "/web/",
  plugins: [react()],
  build: {
    outDir: "../priv/static/assets/web",
    emptyOutDir: true,
    manifest: true,
    rollupOptions: {
      input: "/index.html",
    },
  },
  server: {
    host: "127.0.0.1",
    port: Number(process.env.VITE_PORT || 9501),
    strictPort: true,
    hmr: {
      host: "127.0.0.1",
      port: Number(process.env.VITE_PORT || 9501),
    },
    proxy: {
      "/socket": {
        target: `ws://127.0.0.1:${process.env.PHX_PORT || 9500}`,
        ws: true,
      },
      "/api": {
        target: `http://127.0.0.1:${process.env.PHX_PORT || 9500}`,
      },
    },
  },
});
