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

    // Key bindings for main view
    const mainBindings = { c: 'view:cpu', m: 'view:memory', n: 'view:network', d: 'view:disk', p: 'view:processes' };

    function addMainBindings() {
      for (const [key, action] of Object.entries(mainBindings)) {
        termweb.addKeyBinding(key, action);
      }
    }

    function removeMainBindings() {
      for (const key of Object.keys(mainBindings)) {
        termweb.removeKeyBinding(key);
      }
    }

    // Listen for view/state changes from page via WebSocket
    wss.on('connection', (ws) => {
      ws.on('message', (message) => {
        try {
          const msg = JSON.parse(message.toString());
          if (msg.type === 'viewChange') {
            if (verbose) console.log(`[View] Changed to: ${msg.view}`);
            if (msg.view === 'main') {
              addMainBindings();
            } else {
              removeMainBindings();
            }
          } else if (msg.type === 'killConfirm') {
            // Add y/n bindings for kill confirmation
            if (verbose) console.log('[Kill] Confirm mode');
            termweb.addKeyBinding('y', 'kill:confirm');
            termweb.addKeyBinding('n', 'kill:cancel');
          } else if (msg.type === 'killCancel') {
            // Remove y/n bindings
            if (verbose) console.log('[Kill] Cancel mode');
            termweb.removeKeyBinding('y');
            termweb.removeKeyBinding('n');
          } else if (msg.type === 'deleteConfirm') {
            // Add y/n bindings for delete confirmation
            if (verbose) console.log('[Delete] Confirm mode');
            termweb.addKeyBinding('y', 'delete:confirm');
            termweb.addKeyBinding('n', 'delete:cancel');
          } else if (msg.type === 'deleteCancel') {
            // Remove y/n bindings
            if (verbose) console.log('[Delete] Cancel mode');
            termweb.removeKeyBinding('y');
            termweb.removeKeyBinding('n');
          }
        } catch (e) {}
      });
    });

    // SDK handles keys, sends action to page
    termweb.onKeyBinding((key, action) => {
      if (verbose) console.log(`[KeyBinding] ${key} -> ${action}`);
      termweb.sendToPage({ type: 'action', action });
    });

    termweb.openAsync(url, {
      toolbar: false,
      allowedHotkeys: ['quit', 'copy', 'cut', 'paste'],
      singleTab: true,
      keyBindings: mainBindings,
      verbose
    });

    if (verbose) console.log('[Dashboard] Started, press Ctrl+Q to quit...');

  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

main();
