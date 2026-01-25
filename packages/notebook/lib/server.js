/**
 * Notebook server - serves notebook UI for viewing/editing
 * No code execution (view/edit mode only)
 */
const http = require('http');
const path = require('path');
const fs = require('fs');

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
    let notebook = null;
    let notebookFile = notebookPath;

    // Load notebook
    if (notebookFile && fs.existsSync(notebookFile)) {
      notebook = parseNotebook(fs.readFileSync(notebookFile, 'utf-8'));
    } else {
      notebook = parseNotebook('{}');
    }

    const distPath = path.join(__dirname, '..', 'dist');
    const mimeTypes = {
      '.html': 'text/html',
      '.js': 'application/javascript',
      '.css': 'text/css',
      '.json': 'application/json'
    };

    // Create HTTP server
    const server = http.createServer((req, res) => {
      const urlPath = req.url.split('?')[0];

      if (req.method === 'GET' && urlPath === '/notebook.json') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          notebook,
          path: notebookFile
        }));
      } else if (req.method === 'POST' && urlPath === '/save') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
          try {
            const newNotebook = JSON.parse(body);
            if (notebookFile) {
              fs.writeFileSync(notebookFile, JSON.stringify(newNotebook, null, 2));
              notebook = newNotebook;
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ success: true }));
            } else {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'No file path' }));
            }
          } catch (err) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: err.message }));
          }
        });
      } else if (req.method === 'GET') {
        // Serve static files
        let filePath = urlPath === '/' ? '/index.html' : urlPath;
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
      } else {
        res.writeHead(404);
        res.end('Not found');
      }
    });

    server.listen(port, '127.0.0.1', () => {
      const actualPort = server.address().port;
      console.log(`Notebook server running on http://127.0.0.1:${actualPort}`);
      resolve({ server, port: actualPort });
    });

    server.on('error', reject);
  });
}

module.exports = { startServer };
