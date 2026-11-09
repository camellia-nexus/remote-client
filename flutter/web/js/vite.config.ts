import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  build: {
    target: 'es2019',
    outDir: 'dist',
    emptyOutDir: true,
    chunkSizeWarningLimit: 550,
    rollupOptions: {
      input: './src/main.ts',
      output: {
        entryFileNames: 'web_bridge.js',
        chunkFileNames: 'web_bridge.[hash].js',
        assetFileNames: 'web_bridge.[hash][extname]'
      }
    }
  }
});
