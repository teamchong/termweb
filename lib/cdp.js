/**
 * CDP (Chrome DevTools Protocol) client
 *
 * Direct access to Chrome for advanced use cases.
 * Similar to Puppeteer but lighter weight.
 */

const { spawn: nodeSpawn } = require('child_process');
const http = require('http');

// Lazy-load ws (optional dependency)
let WebSocket;
function getWebSocket() {
  if (!WebSocket) {
    try {
      WebSocket = require('ws');
    } catch (e) {
      throw new Error('ws package is required for CDP. Install with: npm install ws');
    }
  }
  return WebSocket;
}

class CDP {
  /**
   * Create a CDP client
   * @param {Object} options
   * @param {string} [options.host] - Chrome debug host
   * @param {number} [options.port] - Chrome debug port
   * @param {WebSocket} [options.ws] - Existing WebSocket connection
   */
  constructor(options = {}) {
    this._host = options.host || 'localhost';
    this._port = options.port || 9222;
    this._ws = options.ws || null;
    this._messageId = 1;
    this._callbacks = new Map();
    this._eventHandlers = new Map();
  }

  /**
   * Connect to Chrome
   */
  async connect() {
    if (this._ws) return;

    // Get WebSocket URL from Chrome
    const targets = await this._getTargets();
    const page = targets.find((t) => t.type === 'page');
    if (!page) {
      throw new Error('No page target found');
    }

    const WS = getWebSocket();
    this._ws = new WS(page.webSocketDebuggerUrl);

    await new Promise((resolve, reject) => {
      this._ws.on('open', resolve);
      this._ws.on('error', reject);
    });

    this._ws.on('message', (data) => this._handleMessage(data));
  }

  /**
   * Send CDP command
   * @param {string} method - CDP method (e.g., 'Page.navigate')
   * @param {Object} params - Method parameters
   */
  async send(method, params = {}) {
    if (!this._ws) {
      throw new Error('Not connected');
    }

    const id = this._messageId++;
    const message = JSON.stringify({ id, method, params });

    return new Promise((resolve, reject) => {
      this._callbacks.set(id, { resolve, reject });
      this._ws.send(message);
    });
  }

  /**
   * Subscribe to CDP event
   * @param {string} event - Event name (e.g., 'Page.loadEventFired')
   * @param {Function} handler
   */
  on(event, handler) {
    if (!this._eventHandlers.has(event)) {
      this._eventHandlers.set(event, []);
    }
    this._eventHandlers.get(event).push(handler);
  }

  /**
   * Unsubscribe from CDP event
   */
  off(event, handler) {
    const handlers = this._eventHandlers.get(event);
    if (handlers) {
      const index = handlers.indexOf(handler);
      if (index !== -1) {
        handlers.splice(index, 1);
      }
    }
  }

  /**
   * Close connection
   */
  close() {
    if (this._ws) {
      this._ws.close();
      this._ws = null;
    }
  }

  /**
   * Handle incoming message
   * @private
   */
  _handleMessage(data) {
    const message = JSON.parse(data.toString());

    if (message.id !== undefined) {
      // Response to a command
      const callback = this._callbacks.get(message.id);
      if (callback) {
        this._callbacks.delete(message.id);
        if (message.error) {
          callback.reject(new Error(message.error.message));
        } else {
          callback.resolve(message.result);
        }
      }
    } else if (message.method) {
      // Event
      const handlers = this._eventHandlers.get(message.method);
      if (handlers) {
        for (const handler of handlers) {
          handler(message.params);
        }
      }
    }
  }

  /**
   * Get targets from Chrome
   * @private
   */
  _getTargets() {
    return new Promise((resolve, reject) => {
      const url = `http://${this._host}:${this._port}/json`;
      http
        .get(url, (res) => {
          let data = '';
          res.on('data', (chunk) => (data += chunk));
          res.on('end', () => {
            try {
              resolve(JSON.parse(data));
            } catch (e) {
              reject(e);
            }
          });
        })
        .on('error', reject);
    });
  }

  /**
   * Launch Chrome with debugging enabled
   * @param {Object} options
   * @param {string} [options.executablePath] - Path to Chrome
   * @param {number} [options.port] - Debug port
   * @param {boolean} [options.headless] - Run headless
   */
  static async launch(options = {}) {
    const port = options.port || 9222;
    const executablePath =
      options.executablePath ||
      process.env.CHROME_BIN ||
      CDP._findChrome();

    const args = [
      `--remote-debugging-port=${port}`,
      '--no-first-run',
      '--no-default-browser-check',
    ];

    if (options.headless !== false) {
      args.push('--headless=new');
    }

    const chromeProcess = nodeSpawn(executablePath, args, {
      stdio: 'ignore',
      detached: true,
    });

    // Wait for Chrome to start
    await new Promise((resolve) => setTimeout(resolve, 1000));

    const cdp = new CDP({ port });
    cdp._chromeProcess = chromeProcess;
    await cdp.connect();

    return cdp;
  }

  /**
   * Find Chrome executable
   * @private
   */
  static _findChrome() {
    const paths = [
      // macOS
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
      // Linux
      '/usr/bin/google-chrome',
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
    ];

    const fs = require('fs');
    for (const p of paths) {
      if (fs.existsSync(p)) return p;
    }

    throw new Error('Chrome not found. Set CHROME_BIN environment variable.');
  }
}

module.exports = CDP;
