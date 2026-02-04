import svelte from 'rollup-plugin-svelte';
import commonjs from '@rollup/plugin-commonjs';
import resolve from '@rollup/plugin-node-resolve';
import sveltePreprocess from 'svelte-preprocess';

export default {
  input: 'src/main.ts',
  output: {
    file: 'client.js',
    format: 'iife',
    name: 'app',
    sourcemap: false,
  },
  plugins: [
    svelte({
      preprocess: sveltePreprocess(),
      compilerOptions: {
        dev: false,
        css: 'injected', // Inject CSS into JS
      },
    }),
    resolve({
      browser: true,
      dedupe: ['svelte'],
      extensions: ['.svelte', '.ts', '.js'],
    }),
    commonjs(),
  ],
};
