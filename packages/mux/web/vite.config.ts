import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  build: {
    outDir: '.',
    emptyOutDir: false,
    rollupOptions: {
      input: 'src/main.ts',
      output: {
        entryFileNames: 'client.js',
        format: 'iife',
      },
    },
    minify: true,
    sourcemap: false,
  },
});
