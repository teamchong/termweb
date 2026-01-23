/**
 * Low-level API example - Direct access to CDP, Kitty, Terminal
 *
 * This shows how to use termweb components directly for custom use cases.
 *
 * Usage: node examples/low-level.js
 */

const { CDP, KittyGraphics, Terminal } = require('../lib');

async function main() {
  const terminal = new Terminal();
  const kitty = new KittyGraphics();

  // Check terminal support
  console.log('Terminal info:', KittyGraphics.getTerminalInfo());

  if (!KittyGraphics.isSupported()) {
    console.log('Warning: Terminal may not support Kitty graphics');
  }

  // Setup terminal
  terminal.enterAltScreen();
  terminal.hideCursor();
  terminal.enableMouse({ pixels: true });

  // Clean up on exit
  process.on('SIGINT', () => {
    terminal.cleanup();
    process.exit(0);
  });

  try {
    // Launch Chrome and connect via CDP
    console.log('Launching Chrome...');
    const cdp = await CDP.launch({ headless: true });

    // Enable page events
    await cdp.send('Page.enable');

    // Navigate to a page
    await cdp.send('Page.navigate', { url: 'https://example.com' });

    // Wait for load
    await new Promise((resolve) => {
      cdp.on('Page.loadEventFired', resolve);
    });

    console.log('Page loaded!');

    // Take a screenshot
    const { data } = await cdp.send('Page.captureScreenshot', {
      format: 'png',
    });

    // Display in terminal using Kitty graphics
    terminal.clear();
    terminal.moveCursor(1, 1);
    kitty.displayBase64(data, { width: 80, height: 24 });

    console.log('\nPress Ctrl+C to exit');

    // Keep running
    await new Promise(() => {});
  } catch (err) {
    console.error('Error:', err.message);
    terminal.cleanup();
    process.exit(1);
  }
}

main();
