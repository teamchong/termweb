/**
 * Termweb SDK - Web browser in your terminal
 *
 * Usage:
 *   const termweb = require('termweb');
 *   termweb.open('https://example.com', { toolbar: false });
 *
 *   // Tauri-style invoke with return values
 *   const result = await termweb.invoke('myCommand', { arg1: 'value' });
 *
 *   // Event system
 *   termweb.emit('my-event', { data: 123 });
 *   termweb.listen('backend-event', (payload) => console.log(payload));
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

// ============================================================================
// Internal State
// ============================================================================

// Pending invoke calls waiting for response
const pendingInvokes = new Map();
let invokeId = 0;

// Event listeners
const eventListeners = new Map();

// Channel callbacks
const channelCallbacks = new Map();
let channelId = 0;

// Command handlers (registered via termweb.command())
const commandHandlers = new Map();

// Setup internal message router
function setupMessageRouter() {
  if (!native) return;

  native.onMessage((rawMsg) => {
    try {
      // Try to parse as JSON for structured messages
      if (rawMsg.startsWith('{') || rawMsg.startsWith('[')) {
        const msg = JSON.parse(rawMsg);

        // Invoke response: { __invokeId: number, result?: any, error?: string }
        if (msg.__invokeId !== undefined) {
          const pending = pendingInvokes.get(msg.__invokeId);
          if (pending) {
            pendingInvokes.delete(msg.__invokeId);
            if (msg.error) {
              pending.reject(new Error(msg.error));
            } else {
              pending.resolve(msg.result);
            }
          }
          return;
        }

        // Event: { __event: string, payload: any }
        if (msg.__event) {
          const listeners = eventListeners.get(msg.__event);
          if (listeners) {
            listeners.forEach(cb => {
              try { cb(msg.payload); } catch (e) { console.error('Event listener error:', e); }
            });
          }
          return;
        }

        // Channel data: { __channelId: number, data: any, done?: boolean }
        if (msg.__channelId !== undefined) {
          const channel = channelCallbacks.get(msg.__channelId);
          if (channel) {
            if (msg.done) {
              channel.onDone?.();
              channelCallbacks.delete(msg.__channelId);
            } else {
              channel.onData?.(msg.data);
            }
          }
          return;
        }

        // Command invocation from page: { __command: string, args: any, callbackId: number }
        if (msg.__command) {
          const handler = commandHandlers.get(msg.__command);
          if (handler) {
            Promise.resolve(handler(msg.args))
              .then(result => {
                sendToPage({ __commandResult: msg.callbackId, result });
              })
              .catch(err => {
                sendToPage({ __commandResult: msg.callbackId, error: err.message });
              });
          } else {
            sendToPage({ __commandResult: msg.callbackId, error: `Unknown command: ${msg.__command}` });
          }
          return;
        }
      }

      // Legacy: plain message, emit to 'message' event
      const listeners = eventListeners.get('message');
      if (listeners) {
        listeners.forEach(cb => cb(rawMsg));
      }
    } catch (e) {
      // Not JSON, treat as plain message
      const listeners = eventListeners.get('message');
      if (listeners) {
        listeners.forEach(cb => cb(rawMsg));
      }
    }
  });
}

// Initialize message router when module loads
setupMessageRouter();

// ============================================================================
// Core API
// ============================================================================

/**
 * Open a URL in termweb (blocking)
 * @param {string} url - URL to open
 * @param {Object} [options] - Options
 * @param {boolean} [options.toolbar=true] - Show navigation toolbar
 * @param {boolean} [options.hotkeys=true] - Enable keyboard shortcuts
 * @param {boolean} [options.hints=true] - Enable Ctrl+H hint mode
 * @param {boolean} [options.mobile=false] - Use mobile viewport
 * @param {number} [options.scale=1.0] - Page zoom scale
 * @param {boolean} [options.noProfile=false] - Start with fresh profile
 * @returns {Promise<void>}
 */
function open(url, options = {}) {
  if (!native) {
    return Promise.reject(new Error('Native module not found. Build with: zig build'));
  }
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
 * @param {string} url - URL to open
 * @param {Object} [options] - Same options as open()
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
  if (!native) return false;
  return native.evalJS(script);
}

/**
 * Close the active viewer
 * @returns {boolean}
 */
function close() {
  if (!native) return false;
  return native.close();
}

/**
 * Check if a viewer is currently open
 * @returns {boolean}
 */
function isOpen() {
  if (!native) return false;
  return native.isOpen();
}

/**
 * Register a callback for when viewer closes
 * @param {Function} callback
 */
function onClose(callback) {
  if (!native) return;
  native.onClose(callback);
}

/**
 * Register callback for key binding events
 * @param {Function} callback - Called with (key, action)
 */
function onKeyBinding(callback) {
  if (!native) return;
  native.onKeyBinding(callback);
}

/**
 * Add a key binding dynamically
 * @param {string} key - Single letter a-z
 * @param {string} action - Action string
 * @returns {boolean}
 */
function addKeyBinding(key, action) {
  if (!native) return false;
  return native.addKeyBinding(key, action);
}

/**
 * Remove a key binding
 * @param {string} key
 * @returns {boolean}
 */
function removeKeyBinding(key) {
  if (!native) return false;
  return native.removeKeyBinding(key);
}

// ============================================================================
// Tauri-style Invoke API
// ============================================================================

/**
 * Invoke a command in the page and get a return value (like Tauri)
 *
 * Page must handle via:
 *   window.__termweb.onInvoke('commandName', async (args) => {
 *     return { result: 'value' };
 *   });
 *
 * @param {string} command - Command name
 * @param {Object} [args] - Arguments to pass
 * @param {number} [timeout=30000] - Timeout in ms
 * @returns {Promise<any>} - Result from the page
 */
function invoke(command, args = {}, timeout = 30000) {
  if (!native) {
    return Promise.reject(new Error('Native module not found'));
  }

  const id = ++invokeId;

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pendingInvokes.delete(id);
      reject(new Error(`Invoke '${command}' timed out after ${timeout}ms`));
    }, timeout);

    pendingInvokes.set(id, {
      resolve: (result) => {
        clearTimeout(timer);
        resolve(result);
      },
      reject: (err) => {
        clearTimeout(timer);
        reject(err);
      }
    });

    // Send invoke request to page
    const escaped = JSON.stringify({ __invoke: command, args, id })
      .replace(/\\/g, '\\\\').replace(/'/g, "\\'");

    const script = `(function(){
      if(window.__termweb && window.__termweb._handleInvoke){
        window.__termweb._handleInvoke('${escaped}');
      } else {
        console.log('__TERMWEB_IPC__:' + JSON.stringify({__invokeId:${id},error:'Page not ready for invoke'}));
      }
    })()`;

    if (!native.evalJS(script)) {
      clearTimeout(timer);
      pendingInvokes.delete(id);
      reject(new Error('Failed to send invoke'));
    }
  });
}

/**
 * Register a command handler that can be called from the page
 *
 * Page calls via:
 *   const result = await window.__termweb.invoke('myCommand', { arg: 'value' });
 *
 * @param {string} name - Command name
 * @param {Function} handler - Async function(args) that returns result
 */
function command(name, handler) {
  commandHandlers.set(name, handler);
}

// ============================================================================
// Event System (like Tauri)
// ============================================================================

/**
 * Emit an event to the page
 * Page listens via: window.__termweb.listen('event-name', callback)
 *
 * @param {string} event - Event name
 * @param {any} payload - Event data
 * @returns {boolean}
 */
function emit(event, payload) {
  return sendToPage({ __event: event, payload });
}

/**
 * Listen for events from the page
 * Page emits via: window.__termweb.emit('event-name', payload)
 *
 * @param {string} event - Event name
 * @param {Function} callback - Called with payload
 * @returns {Function} - Unsubscribe function
 */
function listen(event, callback) {
  if (!eventListeners.has(event)) {
    eventListeners.set(event, new Set());
  }
  eventListeners.get(event).add(callback);

  // Return unsubscribe function
  return () => {
    const listeners = eventListeners.get(event);
    if (listeners) {
      listeners.delete(callback);
      if (listeners.size === 0) {
        eventListeners.delete(event);
      }
    }
  };
}

/**
 * Listen for an event once
 * @param {string} event
 * @param {Function} callback
 * @returns {Function} - Unsubscribe function
 */
function once(event, callback) {
  const unsubscribe = listen(event, (payload) => {
    unsubscribe();
    callback(payload);
  });
  return unsubscribe;
}

// ============================================================================
// Streaming Channels (like Tauri)
// ============================================================================

/**
 * Create a channel for streaming data from the page
 *
 * Usage:
 *   const channel = termweb.channel();
 *   channel.onData((chunk) => console.log('Received:', chunk));
 *   channel.onDone(() => console.log('Stream complete'));
 *   termweb.invoke('streamFile', { path: '/tmp/big.txt', channelId: channel.id });
 *
 * Page sends data via:
 *   window.__termweb.sendChannel(channelId, data);
 *   window.__termweb.closeChannel(channelId);
 *
 * @returns {{ id: number, onData: Function, onDone: Function }}
 */
function channel() {
  const id = ++channelId;
  const callbacks = { onData: null, onDone: null };
  channelCallbacks.set(id, callbacks);

  return {
    id,
    onData(callback) { callbacks.onData = callback; return this; },
    onDone(callback) { callbacks.onDone = callback; return this; },
    close() { channelCallbacks.delete(id); }
  };
}

// ============================================================================
// Send to Page (low-level)
// ============================================================================

/**
 * Send a message to the page via SDK IPC
 * Page receives via: window.__termweb.onMessage(callback)
 * @param {Object|string} message
 * @returns {boolean}
 */
function sendToPage(message) {
  if (!native) return false;
  const json = typeof message === 'string' ? message : JSON.stringify(message);
  const escaped = json.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n').replace(/\r/g, '\\r');
  const script = `(function(){
    if(window.__termweb && window.__termweb._receive){
      window.__termweb._receive('${escaped}');
    }
  })()`;
  return native.evalJS(script);
}

// ============================================================================
// Window API
// ============================================================================

const window_ = {
  /**
   * Set window/viewport size
   * @param {number} width
   * @param {number} height
   * @returns {boolean}
   */
  setSize(width, height) {
    return evalJS(`window.resizeTo(${width}, ${height})`);
  },

  /**
   * Set page title
   * @param {string} title
   * @returns {boolean}
   */
  setTitle(title) {
    const escaped = title.replace(/'/g, "\\'");
    return evalJS(`document.title = '${escaped}'`);
  },

  /**
   * Navigate to URL
   * @param {string} url
   * @returns {boolean}
   */
  navigate(url) {
    const escaped = url.replace(/'/g, "\\'");
    return evalJS(`window.location.href = '${escaped}'`);
  },

  /**
   * Go back in history
   * @returns {boolean}
   */
  back() {
    return evalJS('window.history.back()');
  },

  /**
   * Go forward in history
   * @returns {boolean}
   */
  forward() {
    return evalJS('window.history.forward()');
  },

  /**
   * Reload page
   * @returns {boolean}
   */
  reload() {
    return evalJS('window.location.reload()');
  },

  /**
   * Scroll to position
   * @param {number} x
   * @param {number} y
   * @returns {boolean}
   */
  scrollTo(x, y) {
    return evalJS(`window.scrollTo(${x}, ${y})`);
  },

  /**
   * Get current URL (async via invoke)
   * @returns {Promise<string>}
   */
  async getUrl() {
    return invoke('__getUrl').catch(() => '');
  },

  /**
   * Get page title (async via invoke)
   * @returns {Promise<string>}
   */
  async getTitle() {
    return invoke('__getTitle').catch(() => '');
  }
};

// ============================================================================
// Filesystem API (wraps fs_handler)
// ============================================================================

const fs_ = {
  /**
   * Read a file
   * @param {string} filePath - Absolute path
   * @returns {Promise<{ content: string, size: number, type: string }>}
   */
  readFile(filePath) {
    return invoke('__fsReadFile', { path: filePath });
  },

  /**
   * Write a file
   * @param {string} filePath - Absolute path
   * @param {string} content - Base64 encoded content
   * @returns {Promise<boolean>}
   */
  writeFile(filePath, content) {
    return invoke('__fsWriteFile', { path: filePath, content });
  },

  /**
   * Read directory contents
   * @param {string} dirPath - Absolute path
   * @returns {Promise<Array<{ name: string, isDirectory: boolean }>>}
   */
  readDir(dirPath) {
    return invoke('__fsReadDir', { path: dirPath });
  },

  /**
   * Get file/directory stats
   * @param {string} filePath - Absolute path
   * @returns {Promise<{ isDirectory: boolean, size?: number }>}
   */
  stat(filePath) {
    return invoke('__fsStat', { path: filePath });
  },

  /**
   * Create a directory
   * @param {string} dirPath - Absolute path
   * @returns {Promise<boolean>}
   */
  mkdir(dirPath) {
    return invoke('__fsMkdir', { path: dirPath });
  },

  /**
   * Remove a file or directory
   * @param {string} filePath - Absolute path
   * @param {boolean} [recursive=false] - Remove recursively
   * @returns {Promise<boolean>}
   */
  remove(filePath, recursive = false) {
    return invoke('__fsRemove', { path: filePath, recursive });
  },

  /**
   * Check if path exists
   * @param {string} filePath - Absolute path
   * @returns {Promise<boolean>}
   */
  async exists(filePath) {
    try {
      await this.stat(filePath);
      return true;
    } catch {
      return false;
    }
  }
};

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Get termweb version
 * @returns {string}
 */
function version() {
  if (native) return native.version();
  return require('../package.json').version;
}

/**
 * Check if terminal supports Kitty graphics
 * @returns {boolean}
 */
function isSupported() {
  if (native) return native.isSupported();
  return false;
}

/**
 * Check if native module is available
 * @returns {boolean}
 */
function isAvailable() {
  return native !== null;
}

// ============================================================================
// Legacy API (deprecated, use listen('message', cb) instead)
// ============================================================================

/**
 * @deprecated Use listen('message', callback) instead
 */
function onMessage(callback) {
  listen('message', callback);
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
  // Core
  open,
  openAsync,
  evalJS,
  close,
  isOpen,
  onClose,
  sendToPage,

  // Tauri-style invoke
  invoke,
  command,

  // Event system
  emit,
  listen,
  once,

  // Streaming
  channel,

  // Window control
  window: window_,

  // Filesystem
  fs: fs_,

  // Key bindings
  onKeyBinding,
  addKeyBinding,
  removeKeyBinding,

  // Utility
  version,
  isSupported,
  isAvailable,

  // Legacy (deprecated)
  onMessage,
};
