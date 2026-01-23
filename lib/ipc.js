/**
 * IPC (Inter-Process Communication) - Electron-like messaging
 *
 * Main process uses ipcMain to handle messages from renderer.
 * Renderer uses ipcRenderer (injected via preload) to send messages.
 */

const EventEmitter = require('events');

/**
 * IPC Main - handles messages in the main process
 */
class IpcMain extends EventEmitter {
  constructor() {
    super();
    this._handlers = new Map();
  }

  /**
   * Handle a channel with async response
   * @param {string} channel
   * @param {Function} handler - async (event, ...args) => result
   */
  handle(channel, handler) {
    this._handlers.set(channel, handler);
  }

  /**
   * Remove a handler
   * @param {string} channel
   */
  removeHandler(channel) {
    this._handlers.delete(channel);
  }

  /**
   * Handle an invoke from renderer
   * @internal
   */
  async _handleInvoke(channel, args, sender) {
    const handler = this._handlers.get(channel);
    if (!handler) {
      throw new Error(`No handler for channel: ${channel}`);
    }
    const event = { sender };
    return handler(event, ...args);
  }
}

/**
 * WebContents - represents the web content in a BrowserWindow
 */
class WebContents extends EventEmitter {
  constructor(browserWindow) {
    super();
    this._browserWindow = browserWindow;
    this._messageQueue = [];
  }

  /**
   * Send a message to the renderer
   * @param {string} channel
   * @param {...any} args
   */
  send(channel, ...args) {
    // Queue message to be sent via console bridge
    this._messageQueue.push({ channel, args });
    this._flush();
  }

  /**
   * Execute JavaScript in the renderer
   * @param {string} code
   */
  async executeJavaScript(code) {
    // This will be implemented when we add CDP support
    throw new Error('executeJavaScript not yet implemented - use CDP directly');
  }

  /**
   * Flush message queue
   * @private
   */
  _flush() {
    // Messages are sent via __TERMWEB_IPC__ console marker
    // The termweb binary will intercept these
  }

  /**
   * Get the owner BrowserWindow
   */
  getOwnerBrowserWindow() {
    return this._browserWindow;
  }
}

// Singleton ipcMain
const ipcMain = new IpcMain();

/**
 * Create webContents for a BrowserWindow
 */
function createWebContents(browserWindow) {
  return new WebContents(browserWindow);
}

module.exports = {
  ipcMain,
  IpcMain,
  WebContents,
  createWebContents,
};
