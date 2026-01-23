/**
 * App lifecycle management (Electron-like)
 */

const EventEmitter = require('events');

class App extends EventEmitter {
  constructor() {
    super();
    this._ready = false;
    this._windows = new Set();

    // Auto-ready on next tick (like Electron)
    process.nextTick(() => {
      this._ready = true;
      this.emit('ready');
    });

    // Handle process signals
    process.on('SIGINT', () => this.quit());
    process.on('SIGTERM', () => this.quit());
  }

  /**
   * Check if app is ready
   */
  isReady() {
    return this._ready;
  }

  /**
   * Wait for app to be ready
   */
  whenReady() {
    if (this._ready) return Promise.resolve();
    return new Promise((resolve) => this.once('ready', resolve));
  }

  /**
   * Register a window
   * @internal
   */
  _registerWindow(win) {
    this._windows.add(win);
    win.on('closed', () => {
      this._windows.delete(win);
      if (this._windows.size === 0) {
        this.emit('window-all-closed');
      }
    });
  }

  /**
   * Get all windows
   */
  getAllWindows() {
    return Array.from(this._windows);
  }

  /**
   * Quit the application
   */
  quit() {
    this.emit('before-quit');
    for (const win of this._windows) {
      win.close();
    }
    this.emit('quit');
    process.exit(0);
  }

  /**
   * Get app version from package.json
   */
  getVersion() {
    return require('../package.json').version;
  }

  /**
   * Get app name
   */
  getName() {
    return 'termweb';
  }
}

// Singleton
module.exports = new App();
