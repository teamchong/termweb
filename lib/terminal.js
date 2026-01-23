/**
 * Terminal utilities - raw mode, mouse, size, etc.
 */

const tty = require('tty');
const readline = require('readline');

// ANSI escape codes
const ESC = '\x1b';
const CSI = `${ESC}[`;

class Terminal {
  constructor() {
    this._rawMode = false;
    this._mouseEnabled = false;
    this._originalMode = null;
  }

  /**
   * Enter raw mode (no echo, no line buffering)
   */
  enterRawMode() {
    if (this._rawMode) return;

    if (process.stdin.isTTY) {
      this._originalMode = process.stdin.isRaw;
      process.stdin.setRawMode(true);
    }

    this._rawMode = true;
  }

  /**
   * Exit raw mode
   */
  exitRawMode() {
    if (!this._rawMode) return;

    if (process.stdin.isTTY && this._originalMode !== null) {
      process.stdin.setRawMode(this._originalMode);
    }

    this._rawMode = false;
  }

  /**
   * Enable mouse tracking
   * @param {Object} options
   * @param {boolean} [options.sgr] - Use SGR extended mode
   * @param {boolean} [options.pixels] - Use pixel coordinates
   */
  enableMouse(options = {}) {
    if (this._mouseEnabled) return;

    // Enable mouse tracking
    process.stdout.write(`${CSI}?1000h`); // Basic mouse
    process.stdout.write(`${CSI}?1002h`); // Button events
    process.stdout.write(`${CSI}?1003h`); // All motion events

    if (options.sgr !== false) {
      process.stdout.write(`${CSI}?1006h`); // SGR extended mode
    }

    if (options.pixels) {
      process.stdout.write(`${CSI}?1016h`); // Pixel coordinates
    }

    this._mouseEnabled = true;
  }

  /**
   * Disable mouse tracking
   */
  disableMouse() {
    if (!this._mouseEnabled) return;

    process.stdout.write(`${CSI}?1016l`);
    process.stdout.write(`${CSI}?1006l`);
    process.stdout.write(`${CSI}?1003l`);
    process.stdout.write(`${CSI}?1002l`);
    process.stdout.write(`${CSI}?1000l`);

    this._mouseEnabled = false;
  }

  /**
   * Get terminal size
   * @returns {{ cols: number, rows: number, width: number, height: number }}
   */
  getSize() {
    const cols = process.stdout.columns || 80;
    const rows = process.stdout.rows || 24;

    // Try to get pixel size via ioctl
    let width = cols * 10; // Fallback
    let height = rows * 20;

    // Use TIOCGWINSZ if available
    try {
      const size = process.stdout.getWindowSize?.();
      if (size) {
        width = size[0] || width;
        height = size[1] || height;
      }
    } catch (e) {
      // Ignore
    }

    return { cols, rows, width, height };
  }

  /**
   * Clear the screen
   */
  clear() {
    process.stdout.write(`${CSI}2J`);
    process.stdout.write(`${CSI}H`);
  }

  /**
   * Move cursor to position
   * @param {number} row - 1-indexed row
   * @param {number} col - 1-indexed column
   */
  moveCursor(row, col) {
    process.stdout.write(`${CSI}${row};${col}H`);
  }

  /**
   * Hide cursor
   */
  hideCursor() {
    process.stdout.write(`${CSI}?25l`);
  }

  /**
   * Show cursor
   */
  showCursor() {
    process.stdout.write(`${CSI}?25h`);
  }

  /**
   * Set terminal title
   * @param {string} title
   */
  setTitle(title) {
    process.stdout.write(`${ESC}]0;${title}\x07`);
  }

  /**
   * Enable alternate screen buffer
   */
  enterAltScreen() {
    process.stdout.write(`${CSI}?1049h`);
  }

  /**
   * Exit alternate screen buffer
   */
  exitAltScreen() {
    process.stdout.write(`${CSI}?1049l`);
  }

  /**
   * Read keyboard input
   * @returns {AsyncGenerator<{ key: string, ctrl: boolean, meta: boolean, shift: boolean }>}
   */
  async *readKeys() {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
      terminal: true,
    });

    readline.emitKeypressEvents(process.stdin, rl);

    if (process.stdin.isTTY) {
      process.stdin.setRawMode(true);
    }

    for await (const [str, key] of this._keyEvents()) {
      yield {
        key: key?.name || str,
        sequence: str,
        ctrl: key?.ctrl || false,
        meta: key?.meta || false,
        shift: key?.shift || false,
      };
    }
  }

  /**
   * Internal key event generator
   * @private
   */
  async *_keyEvents() {
    const events = [];
    let resolve;

    const handler = (str, key) => {
      if (resolve) {
        resolve([str, key]);
        resolve = null;
      } else {
        events.push([str, key]);
      }
    };

    process.stdin.on('keypress', handler);

    try {
      while (true) {
        if (events.length > 0) {
          yield events.shift();
        } else {
          yield await new Promise((r) => (resolve = r));
        }
      }
    } finally {
      process.stdin.off('keypress', handler);
    }
  }

  /**
   * Cleanup - restore terminal state
   */
  cleanup() {
    this.disableMouse();
    this.exitRawMode();
    this.showCursor();
    this.exitAltScreen();
    process.stdout.write(`${CSI}0m`); // Reset attributes
  }
}

module.exports = Terminal;
