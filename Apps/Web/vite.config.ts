import path from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// The reference tables the iOS app bundles (airports.tsv for the globe), shared rather than copied.
const flightkit = path.resolve(import.meta.dirname, "../../Packages/FlightKit/Sources/FlightKit/Resources");

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(import.meta.dirname, "src"), "@flightkit": flightkit } },
  server: {
    fs: { allow: [import.meta.dirname, flightkit] },
    proxy: {
      // Development only: the edge functions send no CORS headers yet, so the
      // browser talks to Supabase through this same-origin proxy.
      "/sb": {
        target: "https://qhzglupzzrnixfvkepze.supabase.co",
        changeOrigin: true,
        ws: true,
        rewrite: (p) => p.replace(/^\/sb/, ""),
      },
    },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.{ts,tsx}"],
  },
});
