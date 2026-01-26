/**
 * WebSocket server for real-time system metrics
 */
const http = require('http');
const path = require('path');
const fs = require('fs');
const WebSocket = require('ws');
const { collectMetrics, collectLightMetrics, getMetricsCached, startBackgroundPolling, killProcess, getConnections, getFolderSizes } = require('./metrics');

/**
 * Start the metrics server
 * @param {number} port - Port to listen on
 * @returns {Promise<{server: http.Server, wss: WebSocket.Server, port: number}>}
 */
function startServer(port = 0) {
  return new Promise((resolve, reject) => {
    const distPath = path.join(__dirname, '..', 'dist');

    const mimeTypes = {
      '.html': 'text/html',
      '.js': 'application/javascript',
      '.css': 'text/css',
      '.json': 'application/json',
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.svg': 'image/svg+xml'
    };

    // Create HTTP server for static files
    const server = http.createServer((req, res) => {
      let filePath = req.url === '/' ? '/index.html' : req.url;
      // Remove query string
      filePath = filePath.split('?')[0];
      const fullPath = path.join(distPath, filePath);
      const ext = path.extname(fullPath);
      const contentType = mimeTypes[ext] || 'application/octet-stream';

      fs.readFile(fullPath, (err, data) => {
        if (err) {
          res.writeHead(404);
          res.end('Not found');
          return;
        }
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(data);
      });
    });

    // Create WebSocket server
    const wss = new WebSocket.Server({ server });

    // Start background polling for metrics (every 2 seconds)
    // This ensures metrics are always cached and ready
    startBackgroundPolling(2000);

    wss.on('connection', async (ws) => {
      // Send initial full metrics (from cache, instant)
      try {
        const metrics = await getMetricsCached();
        ws.send(JSON.stringify({ type: 'full', data: metrics }));
      } catch (err) {
        console.error('Error collecting initial metrics:', err);
      }

      // Send light metrics every second
      const interval = setInterval(async () => {
        if (ws.readyState !== WebSocket.OPEN) {
          clearInterval(interval);
          return;
        }

        try {
          const metrics = await collectLightMetrics();
          ws.send(JSON.stringify({ type: 'update', data: metrics }));
        } catch (err) {
          console.error('Error collecting metrics:', err);
        }
      }, 1000);

      // Send full metrics every 5 seconds (from cache, instant)
      const fullInterval = setInterval(async () => {
        if (ws.readyState !== WebSocket.OPEN) {
          clearInterval(fullInterval);
          return;
        }

        try {
          const metrics = await getMetricsCached();
          ws.send(JSON.stringify({ type: 'full', data: metrics }));
        } catch (err) {
          console.error('Error collecting full metrics:', err);
        }
      }, 5000);

      ws.on('close', () => {
        clearInterval(interval);
        clearInterval(fullInterval);
      });

      ws.on('message', async (message) => {
        try {
          const cmd = JSON.parse(message.toString());
          if (cmd.type === 'refresh') {
            const metrics = await getMetricsCached();
            ws.send(JSON.stringify({ type: 'full', data: metrics }));
          } else if (cmd.type === 'kill' && cmd.pid) {
            const success = killProcess(cmd.pid);
            ws.send(JSON.stringify({ type: 'kill', success, pid: cmd.pid }));
          } else if (cmd.type === 'connections') {
            const connections = await getConnections();
            ws.send(JSON.stringify({ type: 'connections', data: connections }));
          } else if (cmd.type === 'folderSizes' && cmd.path) {
            // Progressive scanning - returns estimates immediately, pushes updates
            const onUpdate = (path, data) => {
              if (ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ type: 'folderSizes', path, data }));
              }
            };
            const sizes = await getFolderSizes(cmd.path, onUpdate);
            ws.send(JSON.stringify({ type: 'folderSizes', path: cmd.path, data: sizes }));
          }
        } catch (err) {
          // Ignore invalid messages
        }
      });
    });

    server.listen(port, '127.0.0.1', () => {
      const actualPort = server.address().port;
      console.log(`Dashboard server running on http://127.0.0.1:${actualPort}`);
      resolve({ server, wss, port: actualPort });
    });

    server.on('error', reject);
  });
}

module.exports = { startServer };
