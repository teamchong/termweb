/**
 * Notebook server - serves notebook UI and handles kernel communication
 */
const http = require('http');
const path = require('path');
const fs = require('fs');
const WebSocket = require('ws');
const { findPython, executeCode } = require('./kernel');

/**
 * Parse notebook file
 */
function parseNotebook(content) {
  try {
    return JSON.parse(content);
  } catch (e) {
    return {
      nbformat: 4,
      nbformat_minor: 5,
      metadata: { kernelspec: { name: 'python3', display_name: 'Python 3' } },
      cells: []
    };
  }
}

/**
 * Start the notebook server
 */
function startServer(notebookPath, port = 0) {
  return new Promise((resolve, reject) => {
    const python = findPython();
    let notebook = null;
    let notebookFile = notebookPath;

    // Load notebook
    if (notebookFile && fs.existsSync(notebookFile)) {
      notebook = parseNotebook(fs.readFileSync(notebookFile, 'utf-8'));
    } else {
      notebook = parseNotebook('{}');
    }

    // Create HTTP server
    const server = http.createServer((req, res) => {
      const distPath = path.join(__dirname, '..', 'dist');

      if (req.url === '/' || req.url === '/index.html') {
        fs.readFile(path.join(distPath, 'index.html'), (err, data) => {
          if (err) {
            res.writeHead(500);
            res.end('Error loading page');
            return;
          }
          res.writeHead(200, { 'Content-Type': 'text/html' });
          res.end(data);
        });
      } else if (req.url === '/notebook.json') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          notebook,
          path: notebookFile,
          pythonAvailable: !!python
        }));
      } else {
        res.writeHead(404);
        res.end('Not found');
      }
    });

    // Create WebSocket server for kernel communication
    const wss = new WebSocket.Server({ server });

    wss.on('connection', (ws) => {
      ws.on('message', async (message) => {
        try {
          const msg = JSON.parse(message.toString());

          if (msg.type === 'execute') {
            if (!python) {
              ws.send(JSON.stringify({
                type: 'error',
                cellId: msg.cellId,
                error: 'Python not found'
              }));
              return;
            }

            ws.send(JSON.stringify({
              type: 'status',
              cellId: msg.cellId,
              status: 'running'
            }));

            const result = await executeCode(python, msg.code);

            ws.send(JSON.stringify({
              type: 'result',
              cellId: msg.cellId,
              output: result.output,
              error: result.error,
              exitCode: result.exitCode
            }));
          } else if (msg.type === 'save') {
            if (notebookFile) {
              fs.writeFileSync(notebookFile, JSON.stringify(msg.notebook, null, 2));
              ws.send(JSON.stringify({ type: 'saved' }));
            }
          }
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', error: err.message }));
        }
      });
    });

    server.listen(port, '127.0.0.1', () => {
      const actualPort = server.address().port;
      console.log(`Notebook server running on http://127.0.0.1:${actualPort}`);
      resolve({ server, wss, port: actualPort });
    });

    server.on('error', reject);
  });
}

module.exports = { startServer };
