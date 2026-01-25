#!/usr/bin/env node

const path = require('path');
const termweb = require('termweb');
const { collectMetrics, collectLightMetrics, killProcess } = require('../lib/metrics');

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
    const htmlPath = path.join(__dirname, '..', 'dist', 'index.html');
    const url = `file://${htmlPath}`;

    // Register message handler for metrics requests
    termweb.onMessage(async (message) => {
      if (verbose) console.log('[IPC] Received:', message);

      // Parse message: id:type or id:kill:pid
      const parts = message.split(':');
      if (parts.length < 2) return;

      const id = parts[0];
      const type = parts[1];

      try {
        if (type === 'kill' && parts.length >= 3) {
          // Kill process: id:kill:pid
          const pid = parseInt(parts[2], 10);
          const success = killProcess(pid);
          const script = `window.__termwebKillResponse(${id}, ${success})`;
          termweb.evalJS(script);
        } else {
          // Metrics request
          let metrics;
          if (type === 'full') {
            metrics = await collectMetrics();
          } else {
            metrics = await collectLightMetrics();
          }

          // Send metrics back to browser via evalJS
          const script = `window.__termwebMetricsResponse(${id}, ${JSON.stringify(metrics)})`;
          termweb.evalJS(script);
        }
      } catch (err) {
        if (verbose) console.error('[IPC] Error:', err);
      }
    });

    // Register close handler
    termweb.onClose(() => {
      if (verbose) console.log('[Dashboard] Viewer closed');
      process.exit(0);
    });

    // Open viewer asynchronously (non-blocking)
    // allowedHotkeys: only allow Ctrl+Q to quit, disable all other termweb shortcuts
    // keyBindings: map keys to JS functions (handled by termweb, works across page navigations)
    termweb.openAsync(url, {
      toolbar: false,
      allowedHotkeys: ['quit'],
      keyBindings: {
        p: 'window.__termwebView && window.__termwebView("processes")',
        n: 'window.__termwebView && window.__termwebView("network")',
        d: 'window.__termwebView && window.__termwebView("disk")',
        m: 'window.__termwebView && window.__termwebView("memory")',
        c: 'window.__termwebView && window.__termwebView("cpu")',
        f: 'window.__termwebFilter && window.__termwebFilter()'
      },
      verbose
    });

    if (verbose) console.log('[Dashboard] Started, press Ctrl+Q to quit...');

    // Keep process alive
    process.stdin.resume();

  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

main();
