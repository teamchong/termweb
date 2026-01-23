/**
 * BrowserWindow - Render web content in terminal (Electron-like)
 */

const EventEmitter = require('events');
const path = require('path');
const app = require('./app');
const { spawn, getBinaryPath } = require('./binary');
const { ipcMain, createWebContents } = require('./ipc');

class BrowserWindow extends EventEmitter {
  /**
   * Create a new browser window
   * @param {Object} options
   * @param {number} [options.width] - Width in terminal columns
   * @param {number} [options.height] - Height in terminal rows
   * @param {string} [options.preload] - Path to preload script
   * @param {Object} [options.webPreferences] - Web preferences
   * @param {boolean} [options.webPreferences.nodeIntegration] - Enable Node.js in renderer
   * @param {boolean} [options.webPreferences.contextIsolation] - Isolate preload context
   */
  constructor(options = {}) {
    super();

    this.id = BrowserWindow._nextId++;
    this._options = options;
    this._process = null;
    this._url = null;
    this._closed = false;

    // Create webContents for IPC
    this.webContents = createWebContents(this);

    // Register with app
    app._registerWindow(this);
  }

  /**
   * Load a URL
   * @param {string} url
   */
  async loadURL(url) {
    this._url = url;
    await this._ensureProcess();
    // URL is passed to process on spawn
  }

  /**
   * Load a local HTML file
   * @param {string} filePath
   */
  async loadFile(filePath) {
    const absolutePath = path.resolve(filePath);
    await this.loadURL(`file://${absolutePath}`);
  }

  /**
   * Start the termweb process
   * @private
   */
  async _ensureProcess() {
    if (this._process) return;

    const args = ['open', this._url];

    // Add options as needed
    if (this._options.profile) {
      args.push('--profile', this._options.profile);
    }

    this._process = spawn(args, {
      stdio: ['inherit', 'inherit', 'inherit'],
      env: {
        ...process.env,
        TERMWEB_SDK: '1',
        TERMWEB_WINDOW_ID: String(this.id),
      },
    });

    this._process.on('exit', (code) => {
      this._closed = true;
      this.emit('closed');
    });

    this._process.on('error', (err) => {
      this.emit('error', err);
    });
  }

  /**
   * Close the window
   */
  close() {
    if (this._process && !this._closed) {
      this._process.kill('SIGTERM');
    }
    this._closed = true;
    this.emit('closed');
  }

  /**
   * Check if window is closed
   */
  isDestroyed() {
    return this._closed;
  }

  /**
   * Focus the window (bring to front)
   */
  focus() {
    // In terminal, this is a no-op for now
  }

  /**
   * Set window title (updates terminal title)
   */
  setTitle(title) {
    // ANSI escape to set terminal title
    process.stdout.write(`\x1b]0;${title}\x07`);
  }

  /**
   * Get all BrowserWindow instances
   */
  static getAllWindows() {
    return app.getAllWindows();
  }

  /**
   * Get focused window
   */
  static getFocusedWindow() {
    // In terminal, there's typically only one
    const windows = BrowserWindow.getAllWindows();
    return windows[0] || null;
  }
}

BrowserWindow._nextId = 1;

module.exports = BrowserWindow;
