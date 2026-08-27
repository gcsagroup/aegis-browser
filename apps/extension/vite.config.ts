import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { crx } from "@crxjs/vite-plugin";
import manifest from "./manifest.config";
import path from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [react(), crx({ manifest })],
  resolve: {
    alias: [
      {
        find: "@gcsa-aegis/ui/styles.css",
        replacement: path.resolve(rootDir, "../../packages/ui/src/styles.css"),
      },
      {
        find: /^@gcsa-aegis\/core$/,
        replacement: path.resolve(rootDir, "../../packages/core/src/index.ts"),
      },
      {
        find: /^@gcsa-aegis\/i18n$/,
        replacement: path.resolve(rootDir, "../../packages/i18n/src/index.ts"),
      },
      {
        find: /^@gcsa-aegis\/model-runtime$/,
        replacement: path.resolve(
          rootDir,
          "../../packages/model-runtime/src/index.ts",
        ),
      },
      {
        find: /^@gcsa-aegis\/ui$/,
        replacement: path.resolve(rootDir, "../../packages/ui/src/index.ts"),
      },
    ],
  },
  build: {
    rollupOptions: {
      input: {
        blocked: path.resolve(rootDir, "src/blocked/index.html"),
      },
    },
  },
  server: {
    port: 5173,
    strictPort: true,
    hmr: {
      port: 5173,
    },
  },
});
