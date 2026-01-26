#!/usr/bin/env node

const path = require('path');
const termweb = require('termweb');
const { startServer } = require('../lib/server');

const args = process.argv.slice(2);
const verbose = args.includes('--verbose') || args.includes('-v');

if (args.includes('--help') || args.includes('-h')) {
  console.log(`
@termweb/dashboard - System Monitoring Dashboard

Usage: termweb-dashboard [options]

Options:
  -v, --verbose   Debug output
  -h, --help      Show help

Displays system metrics:
  - CPU usage (overall and per-core)
  - Memory usage (RAM and swap)
  - Disk usage
  - Network I/O
  - Process list
`);
  process.exit(0);
}

async function main() {
  try {
    // Start WebSocket server (random port)
    const { port, wss } = await startServer(0);
    if (verbose) console.log(`[Dashboard] WebSocket server on port ${port}`);

    // Open page with WebSocket port
    const url = `http://127.0.0.1:${port}/`;

    termweb.onClose(() => {
      if (verbose) console.log('[Dashboard] Viewer closed');
      process.exit(0);
    });

    // Track current view - only forward key bindings on main view
    let currentView = 'main';

    // Listen for view changes from page via WebSocket
    wss.on('connection', (ws) => {
      ws.on('message', (message) => {
        try {
          const msg = JSON.parse(message.toString());
          if (msg.type === 'viewChange') {
            currentView = msg.view;
            if (verbose) console.log(`[View] Changed to: ${currentView}`);
          }
        } catch (e) {}
      });
    });

    // SDK handles keys, but only forward to page when on main view
    termweb.onKeyBinding((key, action) => {
      if (verbose) console.log(`[KeyBinding] ${key} -> ${action} (view: ${currentView})`);
      if (currentView === 'main') {
        termweb.sendToPage({ type: 'action', action });
      }
    });

    termweb.openAsync(url, {
      toolbar: false,
      allowedHotkeys: ['quit'],
      singleTab: true,
      keyBindings: {
        p: 'view:processes',
        c: 'view:cpu',
        m: 'view:memory',
        n: 'view:network',
        d: 'view:disk'
      },
      verbose
    });

    if (verbose) console.log('[Dashboard] Started, press Ctrl+Q to quit...');

  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

main();
