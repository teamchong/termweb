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
  // Bundled: native/termweb-{platform}-{arch}.node
  path.join(__dirname, '..', 'native', `termweb-${platform}-${arch}.node`),
  // Development: zig-out/lib/termweb.node
  path.join(__dirname, '..', 'zig-out', 'lib', 'termweb.node'),
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
 * Open a URL in termweb (blocking)
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
 * Open a URL in termweb (non-blocking)
 * Returns immediately, viewer runs in background
 * @param {string} url - URL to open
 * @param {Object} [options] - Same options as open()
 * @returns {void}
 */
function openAsync(url, options = {}) {
  if (!native) {
    throw new Error('Native module not found. Build with: zig build');
  }
  native.openAsync(url, options);
}

/**
 * Evaluate JavaScript in the active viewer
 * @param {string} script - JavaScript code to execute
 * @returns {boolean} - true if successful
 */
function evalJS(script) {
  if (!native) {
    return false;
  }
  return native.evalJS(script);
}

/**
 * Close the active viewer
 * @returns {boolean} - true if there was a viewer to close
 */
function close() {
  if (!native) {
    return false;
  }
  return native.close();
}

/**
 * Check if a viewer is currently open
 * @returns {boolean}
 */
function isOpen() {
  if (!native) {
    return false;
  }
  return native.isOpen();
}

/**
 * Register a callback to be called when the viewer closes
 * @param {Function} callback - Function to call on close
 */
function onClose(callback) {
  if (!native) {
    return;
  }
  native.onClose(callback);
}

/**
 * Register a callback to receive IPC messages from the browser
 * Browser sends messages via: console.log('__TERMWEB_IPC__:' + yourMessage)
 * @param {Function} callback - Function to call with the message string
 */
function onMessage(callback) {
  if (!native) {
    return;
  }
  native.onMessage(callback);
}

/**
 * Register a callback to receive key binding events
 * Called when a key defined in keyBindings option is pressed
 * @param {Function} callback - Function to call with (key, action)
 */
function onKeyBinding(callback) {
  if (!native) {
    return;
  }
  native.onKeyBinding(callback);
}

/**
 * Add a key binding dynamically
 * @param {string} key - Single letter a-z
 * @param {string} action - Action string to send when key is pressed
 * @returns {boolean} - true if successful
 */
function addKeyBinding(key, action) {
  if (!native) {
    return false;
  }
  return native.addKeyBinding(key, action);
}

/**
 * Remove a key binding dynamically
 * @param {string} key - Single letter a-z
 * @returns {boolean} - true if successful
 */
function removeKeyBinding(key) {
  if (!native) {
    return false;
  }
  return native.removeKeyBinding(key);
}

/**
 * Send a message to the page via SDK IPC
 * Page receives via: window.__termweb.onMessage(callback)
 * @param {Object|string} message - Message to send (will be JSON serialized)
 * @returns {boolean} - true if successful
 */
function sendToPage(message) {
  if (!native) {
    return false;
  }
  const json = typeof message === 'string' ? message : JSON.stringify(message);
  // Escape for JavaScript string literal
  const escaped = json.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n').replace(/\r/g, '\\r');
  const script = `(function(){
    if(window.__termweb && window.__termweb._receive){
      window.__termweb._receive('${escaped}');
    }
  })()`;
  return native.evalJS(script);
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
  openAsync,
  evalJS,
  sendToPage,
  close,
  isOpen,
  onClose,
  onMessage,
  onKeyBinding,
  addKeyBinding,
  removeKeyBinding,
  version,
  isSupported,
  isAvailable,
};
