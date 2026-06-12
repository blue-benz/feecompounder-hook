import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// FeeCompounder Hook frontend — Vite + React (JSX, automatic runtime)
export default defineConfig({
  plugins: [react()],
  server: { host: "0.0.0.0", port: 5173 },
});
