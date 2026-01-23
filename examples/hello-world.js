/**
 * Hello World - Basic termweb SDK example
 *
 * Usage: node examples/hello-world.js
 */

const { app, BrowserWindow } = require('../lib');

app.on('ready', () => {
  console.log('App ready, creating window...');

  const win = new BrowserWindow({
    width: 120,
    height: 40,
  });

  // Load a URL
  win.loadURL('https://example.com');

  win.on('closed', () => {
    console.log('Window closed');
  });
});

app.on('window-all-closed', () => {
  app.quit();
});
