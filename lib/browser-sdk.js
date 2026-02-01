/**
 * Termweb Browser SDK
 * This script is injected into pages to enable communication with the Node.js backend.
 *
 * Usage in page:
 *   // Listen for events from backend
 *   window.__termweb.listen('my-event', (payload) => console.log(payload));
 *
 *   // Emit events to backend
 *   window.__termweb.emit('user-action', { clicked: true });
 *
 *   // Invoke backend commands (registered via termweb.command())
 *   const result = await window.__termweb.invoke('readConfig', { key: 'theme' });
 *
 *   // Handle invokes from backend (registered via termweb.invoke())
 *   window.__termweb.onInvoke('getData', async (args) => {
 *     return { data: 'some data' };
 *   });
 */

(function() {
  'use strict';

  // Avoid re-initialization
  if (window.__termweb && window.__termweb._initialized) return;

  // Internal state
  const eventListeners = new Map();
  const invokeHandlers = new Map();
  const pendingInvokes = new Map();
  let invokeId = 0;

  // IPC send helper - sends via console.log with prefix
  function sendIPC(message) {
    const json = typeof message === 'string' ? message : JSON.stringify(message);
    console.log('__TERMWEB_IPC__:' + json);
  }

  // Public API
  window.__termweb = {
    _initialized: true,
    _callbacks: [],

    // ========================================================================
    // Message receiving (from Node.js backend)
    // ========================================================================

    /**
     * Internal: receive message from backend
     * @private
     */
    _receive(msgJson) {
      try {
        const msg = typeof msgJson === 'string' ? JSON.parse(msgJson) : msgJson;

        // Event from backend: { __event: string, payload: any }
        if (msg.__event) {
          const listeners = eventListeners.get(msg.__event);
          if (listeners) {
            listeners.forEach(cb => {
              try { cb(msg.payload); } catch (e) { console.error('Event listener error:', e); }
            });
          }
          return;
        }

        // Command result from backend: { __commandResult: number, result?: any, error?: string }
        if (msg.__commandResult !== undefined) {
          const pending = pendingInvokes.get(msg.__commandResult);
          if (pending) {
            pendingInvokes.delete(msg.__commandResult);
            if (msg.error) {
              pending.reject(new Error(msg.error));
            } else {
              pending.resolve(msg.result);
            }
          }
          return;
        }

        // Channel data from backend: { __channelId: number, data: any, done?: boolean }
        if (msg.__channelId !== undefined) {
          const listeners = eventListeners.get(`__channel_${msg.__channelId}`);
          if (listeners) {
            listeners.forEach(cb => {
              try { cb(msg.data, msg.done); } catch (e) { console.error('Channel error:', e); }
            });
          }
          return;
        }

        // Legacy: call registered callbacks
        this._callbacks.forEach(cb => {
          try { cb(msg); } catch (e) { console.error('Callback error:', e); }
        });
      } catch (e) {
        // Not JSON, call callbacks with raw string
        this._callbacks.forEach(cb => {
          try { cb(msgJson); } catch (e) { console.error('Callback error:', e); }
        });
      }
    },

    /**
     * Internal: handle invoke from backend
     * @private
     */
    _handleInvoke(msgJson) {
      try {
        const msg = typeof msgJson === 'string' ? JSON.parse(msgJson) : msgJson;
        const handler = invokeHandlers.get(msg.__invoke);

        if (!handler) {
          sendIPC({ __invokeId: msg.id, error: `Unknown command: ${msg.__invoke}` });
          return;
        }

        Promise.resolve(handler(msg.args))
          .then(result => {
            sendIPC({ __invokeId: msg.id, result });
          })
          .catch(err => {
            sendIPC({ __invokeId: msg.id, error: err.message || String(err) });
          });
      } catch (e) {
        console.error('Invoke handling error:', e);
      }
    },

    // ========================================================================
    // Event System
    // ========================================================================

    /**
     * Emit an event to the backend
     * Backend listens via: termweb.listen('event-name', callback)
     *
     * @param {string} event - Event name
     * @param {any} payload - Event data
     */
    emit(event, payload) {
      sendIPC({ __event: event, payload });
    },

    /**
     * Listen for events from the backend
     * Backend emits via: termweb.emit('event-name', payload)
     *
     * @param {string} event - Event name
     * @param {Function} callback - Called with payload
     * @returns {Function} - Unsubscribe function
     */
    listen(event, callback) {
      if (!eventListeners.has(event)) {
        eventListeners.set(event, new Set());
      }
      eventListeners.get(event).add(callback);

      return () => {
        const listeners = eventListeners.get(event);
        if (listeners) {
          listeners.delete(callback);
          if (listeners.size === 0) {
            eventListeners.delete(event);
          }
        }
      };
    },

    /**
     * Listen for an event once
     * @param {string} event
     * @param {Function} callback
     * @returns {Function}
     */
    once(event, callback) {
      const unsubscribe = this.listen(event, (payload) => {
        unsubscribe();
        callback(payload);
      });
      return unsubscribe;
    },

    // ========================================================================
    // Invoke System (call backend commands)
    // ========================================================================

    /**
     * Invoke a command registered in the backend
     * Backend registers via: termweb.command('name', handler)
     *
     * @param {string} command - Command name
     * @param {Object} [args] - Arguments
     * @param {number} [timeout=30000] - Timeout in ms
     * @returns {Promise<any>}
     */
    invoke(command, args = {}, timeout = 30000) {
      const id = ++invokeId;

      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pendingInvokes.delete(id);
          reject(new Error(`Invoke '${command}' timed out after ${timeout}ms`));
        }, timeout);

        pendingInvokes.set(id, {
          resolve: (result) => { clearTimeout(timer); resolve(result); },
          reject: (err) => { clearTimeout(timer); reject(err); }
        });

        sendIPC({ __command: command, args, callbackId: id });
      });
    },

    /**
     * Register a handler for invokes from the backend
     * Backend calls via: termweb.invoke('name', args)
     *
     * @param {string} command - Command name
     * @param {Function} handler - Async function(args) that returns result
     */
    onInvoke(command, handler) {
      invokeHandlers.set(command, handler);
    },

    // ========================================================================
    // Channels (streaming data to backend)
    // ========================================================================

    /**
     * Send data to a channel
     * @param {number} channelId - Channel ID from backend
     * @param {any} data - Data chunk
     */
    sendChannel(channelId, data) {
      sendIPC({ __channelId: channelId, data });
    },

    /**
     * Close a channel (signal completion)
     * @param {number} channelId - Channel ID from backend
     */
    closeChannel(channelId) {
      sendIPC({ __channelId: channelId, done: true });
    },

    // ========================================================================
    // Legacy API
    // ========================================================================

    /**
     * Register a callback for raw messages (legacy)
     * @deprecated Use listen() instead
     */
    onMessage(callback) {
      this._callbacks.push(callback);
    }
  };

  // ========================================================================
  // Built-in handlers for window/fs APIs
  // ========================================================================

  // Window info handlers
  window.__termweb.onInvoke('__getUrl', () => window.location.href);
  window.__termweb.onInvoke('__getTitle', () => document.title);

  // FS handlers (delegated to backend via page -> backend invoke)
  // These are placeholders - actual FS operations happen in the backend
  window.__termweb.onInvoke('__fsReadFile', (args) => {
    // This would be called if page tries to read file - delegate to backend
    return window.__termweb.invoke('__fsReadFile', args);
  });

})();
