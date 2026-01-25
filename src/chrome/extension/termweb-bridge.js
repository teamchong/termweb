// Termweb Bridge - Main World Script
// Overrides File System Access API and Clipboard APIs for termweb integration
// This script runs in the page context (main world) to intercept native APIs

(function() {
  'use strict';

  // Prevent double installation
  if (window.__termwebBridgeInstalled) return;
  window.__termwebBridgeInstalled = true;

  // ============================================================================
  // UTILITY FUNCTIONS
  // ============================================================================

  // Helper to send messages to content script (which forwards to console)
  function sendToTermweb(message) {
    console.log(message);
  }

  // ============================================================================
  // FILE SYSTEM ACCESS API POLYFILL
  // ============================================================================

  // Store native constructors for instanceof checks
  const NativeFileSystemDirectoryHandle = window.FileSystemDirectoryHandle;
  const NativeFileSystemFileHandle = window.FileSystemFileHandle;

  // Patch Symbol.hasInstance to make our polyfilled handles pass instanceof checks
  // This is required because VS Code checks `handle instanceof FileSystemDirectoryHandle`
  if (NativeFileSystemDirectoryHandle) {
    const originalHasInstance = NativeFileSystemDirectoryHandle[Symbol.hasInstance];
    Object.defineProperty(NativeFileSystemDirectoryHandle, Symbol.hasInstance, {
      value: function(obj) {
        if (obj && obj._path && obj.kind === 'directory') return true;
        return originalHasInstance ? originalHasInstance.call(this, obj) : false;
      }
    });
  }
  if (NativeFileSystemFileHandle) {
    const originalHasInstance = NativeFileSystemFileHandle[Symbol.hasInstance];
    Object.defineProperty(NativeFileSystemFileHandle, Symbol.hasInstance, {
      value: function(obj) {
        if (obj && obj._path && obj.kind === 'file') return true;
        return originalHasInstance ? originalHasInstance.call(this, obj) : false;
      }
    });
  }

  // Pending requests waiting for Zig responses
  const pendingRequests = new Map();
  let requestId = 0;

  // Send request to Zig and wait for response
  function sendFsRequest(type, path, data) {
    return new Promise((resolve, reject) => {
      const id = ++requestId;
      pendingRequests.set(id, { resolve, reject });
      // Format: __TERMWEB_FS__:id:type:path:data
      const msg = data !== undefined
        ? '__TERMWEB_FS__:' + id + ':' + type + ':' + path + ':' + data
        : '__TERMWEB_FS__:' + id + ':' + type + ':' + path;
      sendToTermweb(msg);
      // Timeout after 30s
      setTimeout(function() {
        if (pendingRequests.has(id)) {
          pendingRequests.delete(id);
          reject(new Error('Request timeout'));
        }
      }, 30000);
    });
  }

  // Called by Zig to resolve pending requests
  window.__termwebFSResponse = function(id, success, data) {
    const req = pendingRequests.get(id);
    if (req) {
      pendingRequests.delete(id);
      if (success) {
        req.resolve(data);
      } else {
        req.reject(new DOMException(data || 'Operation failed', 'NotAllowedError'));
      }
    }
  };

  // Create prototype that mimics FileSystemFileHandle
  const FileHandleProto = {
    [Symbol.toStringTag]: 'FileSystemFileHandle'
  };

  // Create a FileSystemFileHandle with non-enumerable methods (for IndexedDB compatibility)
  function createFileHandle(path, name) {
    const handle = Object.create(FileHandleProto);
    handle.kind = 'file';
    handle.name = name;
    handle._path = path;

    Object.defineProperties(handle, {
      isSameEntry: { value: function(other) {
        return Promise.resolve(this._path === other._path);
      }},
      queryPermission: { value: function() { return Promise.resolve('granted'); }},
      requestPermission: { value: function() { return Promise.resolve('granted'); }},
      getFile: { value: async function() {
        const result = await sendFsRequest('readfile', this._path);
        const binary = atob(result.content);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
          bytes[i] = binary.charCodeAt(i);
        }
        return new File([bytes], this.name, {
          type: result.type || 'application/octet-stream',
          lastModified: result.lastModified || Date.now()
        });
      }},
      createWritable: { value: async function(options) {
        let buffer = [];
        let position = 0;
        const filePath = this._path;
        const keepExisting = options?.keepExistingData;

        if (keepExisting) {
          try {
            const existing = await sendFsRequest('readfile', filePath);
            const binary = atob(existing.content);
            buffer = binary.split('').map(function(c) { return c.charCodeAt(0); });
          } catch (e) {}
        }

        return {
          async write(data) {
            if (typeof data === 'string') {
              data = new TextEncoder().encode(data);
            } else if (data instanceof Blob) {
              data = new Uint8Array(await data.arrayBuffer());
            } else if (data.type === 'write') {
              if (data.position !== undefined) position = data.position;
              data = typeof data.data === 'string'
                ? new TextEncoder().encode(data.data)
                : new Uint8Array(data.data);
            }
            if (data instanceof Uint8Array) {
              for (let i = 0; i < data.length; i++) {
                buffer[position + i] = data[i];
              }
              position += data.length;
            }
          },
          async seek(pos) { position = pos; },
          async truncate(size) { buffer.length = size; if (position > size) position = size; },
          async close() {
            const bytes = new Uint8Array(buffer);
            let binary = '';
            for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
            await sendFsRequest('writefile', filePath, btoa(binary));
          },
          async abort() { buffer = []; }
        };
      }}
    });
    return handle;
  }

  // Create prototype that mimics FileSystemDirectoryHandle
  const DirectoryHandleProto = {
    [Symbol.toStringTag]: 'FileSystemDirectoryHandle'
  };

  // Create a FileSystemDirectoryHandle with non-enumerable methods
  function createDirectoryHandle(path, name) {
    const handle = Object.create(DirectoryHandleProto);
    handle.kind = 'directory';
    handle.name = name;
    handle._path = path;

    Object.defineProperties(handle, {
      isSameEntry: { value: function(other) {
        return Promise.resolve(this._path === other._path);
      }},
      queryPermission: { value: function() { return Promise.resolve('granted'); }},
      requestPermission: { value: function() { return Promise.resolve('granted'); }},
      resolve: { value: async function(possibleDescendant) {
        if (!possibleDescendant._path.startsWith(this._path)) return null;
        const relative = possibleDescendant._path.slice(this._path.length);
        return relative.split('/').filter(function(p) { return p.length > 0; });
      }},
      getFileHandle: { value: async function(entryName, options) {
        const childPath = this._path + '/' + entryName;
        if (options?.create) await sendFsRequest('createfile', childPath);
        const stat = await sendFsRequest('stat', childPath);
        if (stat.isDirectory) throw new DOMException('Is a directory', 'TypeMismatchError');
        return createFileHandle(childPath, entryName);
      }},
      getDirectoryHandle: { value: async function(entryName, options) {
        const childPath = this._path + '/' + entryName;
        if (options?.create) await sendFsRequest('mkdir', childPath);
        const stat = await sendFsRequest('stat', childPath);
        if (!stat.isDirectory) throw new DOMException('Not a directory', 'TypeMismatchError');
        return createDirectoryHandle(childPath, entryName);
      }},
      removeEntry: { value: async function(entryName, options) {
        const childPath = this._path + '/' + entryName;
        await sendFsRequest('remove', childPath, options?.recursive ? '1' : '0');
      }},
      entries: { value: function() {
        const dirPath = this._path;
        let items = null;
        let index = 0;
        return {
          [Symbol.asyncIterator]: function() { return this; },
          next: async function() {
            if (items === null) {
              items = await sendFsRequest('readdir', dirPath);
            }
            if (index >= items.length) return { done: true, value: undefined };
            const item = items[index++];
            const childPath = dirPath + '/' + item.name;
            const h = item.isDirectory
              ? createDirectoryHandle(childPath, item.name)
              : createFileHandle(childPath, item.name);
            return { done: false, value: [item.name, h] };
          }
        };
      }},
      values: { value: function() {
        const entries = this.entries();
        return {
          [Symbol.asyncIterator]: function() { return this; },
          next: async function() {
            const result = await entries.next();
            return result.done ? result : { done: false, value: result.value[1] };
          }
        };
      }},
      keys: { value: function() {
        const entries = this.entries();
        return {
          [Symbol.asyncIterator]: function() { return this; },
          next: async function() {
            const result = await entries.next();
            return result.done ? result : { done: false, value: result.value[0] };
          }
        };
      }},
      [Symbol.asyncIterator]: { value: function() {
        return this.entries();
      }}
    });
    return handle;
  }

  // Picker state
  window.__termwebPendingPicker = null;

  // Called by Zig when user selects a folder/file
  window.__termwebPickerResult = function(success, path, name, isDirectory) {
    const pending = window.__termwebPendingPicker;
    if (!pending) return;
    window.__termwebPendingPicker = null;

    if (success) {
      const handle = isDirectory
        ? createDirectoryHandle(path, name)
        : createFileHandle(path, name);
      // Return format differs by picker type:
      // - showDirectoryPicker: single handle
      // - showSaveFilePicker: single handle
      // - showOpenFilePicker: array of handles
      if (pending.isDirectory || pending.isSave) {
        pending.resolve(handle);
      } else {
        // showOpenFilePicker always returns array (per Web File System Access API spec)
        pending.resolve([handle]);
      }
    } else {
      pending.reject(new DOMException('User cancelled', 'AbortError'));
    }
  };

  // Override File System Access API
  window.showDirectoryPicker = function(options) {
    return new Promise(function(resolve, reject) {
      window.__termwebPendingPicker = { resolve: resolve, reject: reject, isDirectory: true };
      sendToTermweb('__TERMWEB_PICKER__:directory:single');
    });
  };

  window.showOpenFilePicker = function(options) {
    return new Promise(function(resolve, reject) {
      window.__termwebPendingPicker = { resolve: resolve, reject: reject, isDirectory: false };
      sendToTermweb('__TERMWEB_PICKER__:file:' + (options?.multiple ? 'multiple' : 'single'));
    });
  };

  window.showSaveFilePicker = function(options) {
    return new Promise(function(resolve, reject) {
      // Save picker returns a single file handle, not an array
      window.__termwebPendingPicker = { resolve: resolve, reject: reject, isDirectory: false, isSave: true };
      sendToTermweb('__TERMWEB_PICKER__:save:' + (options?.suggestedName || 'file'));
    });
  };

  // ============================================================================
  // CLIPBOARD POLYFILL
  // ============================================================================

  window._termwebClipboardData = '';
  window._termwebClipboardVersion = 0;

  // Store original readText for direct access (bypasses our hook)
  window._termwebOrigReadText = navigator.clipboard && navigator.clipboard.readText
    ? navigator.clipboard.readText.bind(navigator.clipboard)
    : null;

  // Hook navigator.clipboard.writeText
  if (navigator.clipboard && navigator.clipboard.writeText) {
    const origWriteText = navigator.clipboard.writeText.bind(navigator.clipboard);
    navigator.clipboard.writeText = async function(text) {
      window._termwebClipboardData = text;
      sendToTermweb('__TERMWEB_CLIPBOARD__:' + text);
      return origWriteText(text).catch(function() {});
    };
  }

  // Hook navigator.clipboard.write() - Monaco might use this
  if (navigator.clipboard && navigator.clipboard.write) {
    const origWrite = navigator.clipboard.write.bind(navigator.clipboard);
    navigator.clipboard.write = async function(data) {
      try {
        for (const item of data) {
          if (item.types.includes('text/plain')) {
            const blob = await item.getType('text/plain');
            const text = await blob.text();
            window._termwebClipboardData = text;
            sendToTermweb('__TERMWEB_CLIPBOARD__:' + text);
          }
        }
      } catch(e) {}
      return origWrite(data).catch(function() {});
    };
  }

  // Helper to get clipboard data from this frame or parent frames
  function getClipboardData() {
    // Check local window
    if (window._termwebClipboardData) return window._termwebClipboardData;
    // Check parent frames (for iframes like Monaco)
    try {
      let w = window.parent;
      while (w && w !== window) {
        if (w._termwebClipboardData) return w._termwebClipboardData;
        if (w === w.parent) break;
        w = w.parent;
      }
    } catch(e) {} // Cross-origin frames will throw
    // Check top
    try {
      if (window.top && window.top._termwebClipboardData) return window.top._termwebClipboardData;
    } catch(e) {}
    return '';
  }

  // Hook navigator.clipboard.readText
  if (navigator.clipboard && navigator.clipboard.readText) {
    navigator.clipboard.readText = async function() {
      // If data already set (from Cmd+V path), return immediately
      const data = getClipboardData();
      if (data) {
        return data;
      }
      // Otherwise request from host (for menu paste)
      const ver = window._termwebClipboardVersion;
      sendToTermweb('__TERMWEB_CLIPBOARD_REQUEST__');
      for (let i = 0; i < 20; i++) {
        await new Promise(function(r) { setTimeout(r, 10); });
        if (window._termwebClipboardVersion > ver) break;
      }
      return getClipboardData();
    };
  }

  // Hook document.execCommand for copy/cut
  const origExecCommand = document.execCommand.bind(document);
  document.execCommand = function(cmd, showUI, value) {
    if (cmd === 'copy' || cmd === 'cut') {
      let text = '';
      const active = document.activeElement;
      // Try activeElement (Monaco uses hidden textarea)
      if (active && (active.tagName === 'TEXTAREA' || active.tagName === 'INPUT')) {
        const start = active.selectionStart;
        const end = active.selectionEnd;
        if (start !== end) {
          text = active.value.substring(start, end);
        } else {
          text = active.value;
        }
      }
      // Try contentEditable
      if (!text && active && active.isContentEditable) {
        const sel = window.getSelection();
        text = sel ? sel.toString() : '';
      }
      // Fallback - search for any textarea with content
      if (!text) {
        const textareas = document.querySelectorAll('textarea');
        for (const ta of textareas) {
          if (ta.value) {
            text = ta.value;
            break;
          }
        }
      }
      // Final fallback to selection
      if (!text) {
        const sel = window.getSelection();
        text = sel ? sel.toString() : '';
      }
      if (text) {
        window._termwebClipboardData = text;
        // Also set in top frame so main context can read it
        try { window.top._termwebClipboardData = text; } catch(e) {}
        sendToTermweb('__TERMWEB_CLIPBOARD__:' + text);
      }
    }
    return origExecCommand(cmd, showUI, value);
  };

  // Listen for copy/cut events - use bubbling phase (false) to run AFTER Monaco sets data
  document.addEventListener('copy', function(e) {
    let text = '';
    // Try clipboardData first (should be set by Monaco now)
    if (e.clipboardData) {
      text = e.clipboardData.getData('text/plain');
    }
    // Fallback to window.getSelection
    if (!text) {
      const sel = window.getSelection();
      text = sel ? sel.toString() : '';
    }
    if (text) {
      window._termwebClipboardData = text;
      // Also set in top frame so main context can read it
      try { window.top._termwebClipboardData = text; } catch(e) {}
      // Also write to system clipboard via original writeText
      if (window._termwebOrigReadText) {
        navigator.clipboard.writeText(text).catch(function() {});
      }
      sendToTermweb('__TERMWEB_CLIPBOARD__:' + text);
    }
  }, false); // false = bubbling phase, runs AFTER capture handlers

  document.addEventListener('cut', function(e) {
    let text = '';
    if (e.clipboardData) {
      text = e.clipboardData.getData('text/plain');
    }
    if (!text) {
      const sel = window.getSelection();
      text = sel ? sel.toString() : '';
    }
    if (text) {
      window._termwebClipboardData = text;
      // Also write to system clipboard
      if (window._termwebOrigReadText) {
        navigator.clipboard.writeText(text).catch(function() {});
      }
      sendToTermweb('__TERMWEB_CLIPBOARD__:' + text);
    }
  }, false); // false = bubbling phase

  // Listen for paste events - inject our clipboard data
  document.addEventListener('paste', function(e) {
    if (window._termwebClipboardData) {
      e.preventDefault();
      e.stopPropagation();
      const el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) {
        document.execCommand('insertText', false, window._termwebClipboardData);
      }
    }
  }, true);

  // Request clipboard from host on focusin (throttled)
  let lastFocusSync = 0;
  document.addEventListener('focusin', function(e) {
    const now = Date.now();
    if (now - lastFocusSync > 500) {
      lastFocusSync = now;
      sendToTermweb('__TERMWEB_CLIPBOARD_REQUEST__');
    }
  }, true);

  // ============================================================================
  // INITIALIZATION COMPLETE
  // ============================================================================

  // Signal that bridge is ready
  sendToTermweb('__TERMWEB_BRIDGE__:ready');
})();
