#!/usr/bin/env node

const termweb = require('termweb');
const { startServer } = require('../lib/server');
const { resolveDisplayMode } = require('@termweb/shared');

const args = process.argv.slice(2);
const verbose = args.includes('--verbose') || args.includes('-v');

// Parse mode flag
let requestedMode = 'auto';
const modeIdx = args.indexOf('--mode');
if (modeIdx !== -1 && args[modeIdx + 1]) {
  requestedMode = args[modeIdx + 1];
}

if (args.includes('--help') || args.includes('-h')) {
  console.log(`
@termweb/dashboard - System Monitoring Dashboard

Usage: termweb-dashboard [options]

Options:
  --mode <mode>   Display mode: auto, embedded, standalone
  -v, --verbose   Debug output
  -h, --help      Show help

Displays real-time system metrics:
  - CPU usage (overall and per-core)
  - Memory usage (RAM and swap)
  - Disk usage
  - Network I/O
  - Process list
  - Temperature sensors
`);
  process.exit(0);
}

async function main() {
  try {
    // Start the metrics server
    const { port } = await startServer(0);

    const url = `http://127.0.0.1:${port}`;

    // Resolve mode and open
    const mode = resolveDisplayMode(requestedMode);

    await termweb.open(url, { toolbar: false, verbose, mode });
    process.exit(0);
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

main();
