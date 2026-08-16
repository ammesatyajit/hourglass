import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const projectRoot = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  root: resolve(projectRoot, "github-pages-src"),
  base: "/hourglass/",
  publicDir: resolve(projectRoot, "public"),
  plugins: [react()],
  build: {
    outDir: resolve(projectRoot, "../docs"),
    emptyOutDir: false,
    rollupOptions: {
      input: {
        main: resolve(projectRoot, "github-pages-src/index.html"),
        privacy: resolve(projectRoot, "github-pages-src/privacy/index.html"),
      },
    },
  },
});
