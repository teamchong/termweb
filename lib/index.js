/**
 * Termweb SDK - Web browser in your terminal
 *
 * Usage:
 *   const termweb = require('termweb');
 *   termweb.open('https://example.com', { toolbar: false });
 */

const path = require('path');
const fs = require('fs');

// Load native module
const platform = process.platform === 'darwin' ? 'macos' : 'linux';
const arch = process.arch === 'arm64' ? 'aarch64' : 'x86_64';

// Try multiple locations for native module
const searchPaths = [
  // Development: zig-out/lib/termweb.node
  path.join(__dirname, '..', 'zig-out', 'lib', 'termweb.node'),
  // Installed: native/termweb-{platform}-{arch}.node
  path.join(__dirname, '..', 'native', `termweb-${platform}-${arch}.node`),
  // Fallback: native/termweb.node
  path.join(__dirname, '..', 'native', 'termweb.node'),
];

let native = null;
for (const modulePath of searchPaths) {
  if (fs.existsSync(modulePath)) {
    try {
      native = require(modulePath);
      break;
    } catch (e) {
      // Continue searching
    }
  }
}

/**
 * Open a URL in termweb
 * @param {string} url - URL to open
 * @param {Object} [options] - Options
 * @param {boolean} [options.toolbar=true] - Show navigation toolbar
 * @param {boolean} [options.hotkeys=true] - Enable keyboard shortcuts (Ctrl+L, Ctrl+R, etc.)
 * @param {boolean} [options.hints=true] - Enable Ctrl+H hint mode (Vimium-style navigation)
 * @param {boolean} [options.mobile=false] - Use mobile viewport
 * @param {number} [options.scale=1.0] - Page zoom scale
 * @param {boolean} [options.noProfile=false] - Start with fresh profile
 * @returns {Promise<void>}
 */
function open(url, options = {}) {
  if (!native) {
    return Promise.reject(new Error('Native module not found. Build with: zig build'));
  }
  // Wrap synchronous blocking call in a Promise
  return new Promise((resolve, reject) => {
    try {
      native.open(url, options);
      resolve();
    } catch (err) {
      reject(err);
    }
  });
}

/**
 * Get termweb version
 * @returns {string}
 */
function version() {
  if (native) {
    return native.version();
  }
  return require('../package.json').version;
}

/**
 * Check if terminal supports Kitty graphics
 * @returns {boolean}
 */
function isSupported() {
  if (native) {
    return native.isSupported();
  }
  return false;
}

/**
 * Check if native module is available
 * @returns {boolean}
 */
function isAvailable() {
  return native !== null;
}

module.exports = {
  open,
  version,
  isSupported,
  isAvailable,
};
