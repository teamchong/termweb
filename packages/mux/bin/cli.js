#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

// Find the native binary
const platform = process.platform;
const arch = process.arch;

if (platform !== 'darwin') {
  console.error('Error: termweb-mux currently only supports macOS');
  console.error(`Your platform: ${platform}`);
  process.exit(1);
}

// Binary location relative to this script
const binaryPath = path.join(__dirname, '..', 'native', 'zig-out', 'bin', 'termweb-mux');

if (!fs.existsSync(binaryPath)) {
  console.error('Error: Native binary not found at:', binaryPath);
  console.error('');
  console.error('Please build it first:');
  console.error('  cd native && zig build -Doptimize=ReleaseFast');
  process.exit(1);
}

// Web root for serving static files
const webRoot = path.join(__dirname, '..', 'web');

// Parse arguments
const args = process.argv.slice(2);

// Default HTTP port - WS ports are auto-calculated as HTTP+1 and HTTP+2
let httpPort = 8080;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' || args[i] === '-p') {
    httpPort = parseInt(args[++i], 10);
  } else if (args[i] === '--help' || args[i] === '-h') {
    console.log('termweb-mux - Remote terminal multiplexer');
    console.log('');
    console.log('Usage: termweb-mux [options]');
    console.log('');
    console.log('Options:');
    console.log('  -p, --port <port>   HTTP server port (default: 8080)');
    console.log('  -h, --help          Show this help');
    console.log('');
    console.log('WebSocket ports are auto-assigned to avoid conflicts.');
    console.log('Open http://localhost:<port> in your browser after starting.');
    process.exit(0);
  }
}

console.log('Starting termweb-mux...');
console.log(`  HTTP server: http://localhost:${httpPort}`);
console.log('  WebSocket ports: auto-assigned (see /config)');
console.log('');

// Launch the native binary
const child = spawn(binaryPath, [
  '--port', String(httpPort),
  '--web-root', webRoot
], {
  stdio: 'inherit',
  env: { ...process.env }
});

child.on('error', (err) => {
  console.error('Failed to start termweb-mux:', err.message);
  process.exit(1);
});

child.on('exit', (code) => {
  process.exit(code || 0);
});

// Handle signals
process.on('SIGINT', () => {
  child.kill('SIGINT');
});

process.on('SIGTERM', () => {
  child.kill('SIGTERM');
});
