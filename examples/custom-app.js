/**
 * Custom App - Build a terminal app with your own HTML
 *
 * This example shows how to load local HTML and communicate via IPC.
 *
 * Usage: node examples/custom-app.js
 */

const { app, BrowserWindow, ipcMain } = require('../lib');
const path = require('path');
const fs = require('fs');

// Create a simple HTML file for the app
const htmlContent = `
<!DOCTYPE html>
<html>
<head>
  <title>My Terminal App</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100vh;
      margin: 0;
    }
    h1 { font-size: 3em; margin-bottom: 0.5em; }
    p { font-size: 1.5em; opacity: 0.9; }
    button {
      margin-top: 2em;
      padding: 1em 2em;
      font-size: 1.2em;
      border: none;
      border-radius: 8px;
      background: white;
      color: #667eea;
      cursor: pointer;
      transition: transform 0.2s;
    }
    button:hover { transform: scale(1.05); }
    #counter {
      font-size: 4em;
      margin: 0.5em 0;
    }
  </style>
</head>
<body>
  <h1>Terminal App</h1>
  <p>Running in your terminal with Kitty graphics!</p>
  <div id="counter">0</div>
  <button onclick="increment()">Click Me!</button>
  <script>
    let count = 0;
    function increment() {
      count++;
      document.getElementById('counter').textContent = count;
      // Send message to main process
      console.log('__TERMWEB_IPC__', JSON.stringify({ type: 'click', count }));
    }
  </script>
</body>
</html>
`;

// Write HTML to temp file
const tmpDir = path.join(__dirname, '.tmp');
if (!fs.existsSync(tmpDir)) fs.mkdirSync(tmpDir);
const htmlPath = path.join(tmpDir, 'app.html');
fs.writeFileSync(htmlPath, htmlContent);

app.on('ready', () => {
  console.log('Creating custom app window...');

  const win = new BrowserWindow({
    width: 100,
    height: 30,
  });

  // Load local HTML
  win.loadFile(htmlPath);

  // Handle IPC messages from renderer
  ipcMain.on('click', (event, data) => {
    console.log(`Button clicked! Count: ${data.count}`);
  });

  win.on('closed', () => {
    // Cleanup temp files
    fs.unlinkSync(htmlPath);
    fs.rmdirSync(tmpDir);
  });
});

app.on('window-all-closed', () => {
  app.quit();
});
