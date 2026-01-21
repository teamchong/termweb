(function() {
  console.log('__TERMWEB_POLYFILL_LOADED__');
  if (window.__termwebFSInstalled) return;
  window.__termwebFSInstalled = true;
  console.log('__TERMWEB_POLYFILL_INIT__');

  // Pending requests waiting for Zig responses
  const pendingRequests = new Map();
  let requestId = 0;

  // Send request to Zig and wait for response
  function sendRequest(type, path, data) {
    return new Promise((resolve, reject) => {
      const id = ++requestId;
      pendingRequests.set(id, { resolve, reject });
      // Format: __TERMWEB_FS__:id:type:path:data
      const msg = data !== undefined
        ? `__TERMWEB_FS__:${id}:${type}:${path}:${data}`
        : `__TERMWEB_FS__:${id}:${type}:${path}`;
      console.log(msg);
      // Timeout after 30s
      setTimeout(() => {
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
        const result = await sendRequest('readfile', this._path);
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
            const existing = await sendRequest('readfile', filePath);
            const binary = atob(existing.content);
            buffer = binary.split('').map(c => c.charCodeAt(0));
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
            await sendRequest('writefile', filePath, btoa(binary));
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

  // Create a FileSystemDirectoryHandle with non-enumerable methods (for IndexedDB compatibility)
  function createDirectoryHandle(path, name) {
    console.log('__TERMWEB_DEBUG__:createDirectoryHandle: ' + path + ' name=' + name);
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
        return relative.split('/').filter(p => p.length > 0);
      }},
      getFileHandle: { value: async function(entryName, options) {
        console.log('__TERMWEB_DEBUG__:getFileHandle called: ' + entryName + ' in ' + this._path);
        const childPath = this._path + '/' + entryName;
        if (options?.create) await sendRequest('createfile', childPath);
        const stat = await sendRequest('stat', childPath);
        if (stat.isDirectory) throw new DOMException('Is a directory', 'TypeMismatchError');
        return createFileHandle(childPath, entryName);
      }},
      getDirectoryHandle: { value: async function(entryName, options) {
        console.log('__TERMWEB_DEBUG__:getDirectoryHandle called: ' + entryName + ' in ' + this._path);
        const childPath = this._path + '/' + entryName;
        if (options?.create) await sendRequest('mkdir', childPath);
        const stat = await sendRequest('stat', childPath);
        if (!stat.isDirectory) throw new DOMException('Not a directory', 'TypeMismatchError');
        return createDirectoryHandle(childPath, entryName);
      }},
      removeEntry: { value: async function(entryName, options) {
        const childPath = this._path + '/' + entryName;
        await sendRequest('remove', childPath, options?.recursive ? '1' : '0');
      }},
      entries: { value: function() {
        const dirPath = this._path;
        console.log('__TERMWEB_DEBUG__:entries called for ' + dirPath);
        let items = null;
        let index = 0;
        return {
          [Symbol.asyncIterator]: function() { return this; },
          next: async function() {
            console.log('__TERMWEB_DEBUG__:entries.next called, index=' + index);
            if (items === null) {
              console.log('__TERMWEB_DEBUG__:entries.next fetching items for ' + dirPath);
              items = await sendRequest('readdir', dirPath);
              console.log('__TERMWEB_DEBUG__:entries.next got ' + items.length + ' items');
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
        console.log('__TERMWEB_DEBUG__:values called for ' + this._path);
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
        console.log('__TERMWEB_DEBUG__:keys called for ' + this._path);
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
        console.log('__TERMWEB_DEBUG__:[Symbol.asyncIterator] called for ' + this._path);
        return this.entries();
      }}
    });
    return handle;
  }

  // Picker state
  window.__termwebPendingPicker = null;

  // Called by Zig when user selects a folder/file
  window.__termwebPickerResult = function(success, path, name, isDirectory) {
    console.log('__TERMWEB_DEBUG__:pickerResult success=' + success + ' path=' + path + ' name=' + name + ' isDir=' + isDirectory);
    const pending = window.__termwebPendingPicker;
    if (!pending) {
      console.log('__TERMWEB_DEBUG__:pickerResult ERROR: no pending picker!');
      return;
    }
    window.__termwebPendingPicker = null;

    if (success) {
      const handle = isDirectory
        ? createDirectoryHandle(path, name)
        : createFileHandle(path, name);
      console.log('__TERMWEB_DEBUG__:pickerResult resolving with handle:', handle.kind, handle.name);
      pending.resolve(pending.multiple ? [handle] : handle);
    } else {
      pending.reject(new DOMException('User cancelled', 'AbortError'));
    }
  };

  // Override File System Access API
  window.showDirectoryPicker = function(options) {
    console.log('__TERMWEB_PICKER_CALLED__:directory');
    return new Promise((resolve, reject) => {
      window.__termwebPendingPicker = { resolve, reject, multiple: false };
      console.log('__TERMWEB_PICKER__:directory:single');
    });
  };

  window.showOpenFilePicker = function(options) {
    return new Promise((resolve, reject) => {
      window.__termwebPendingPicker = { resolve, reject, multiple: options?.multiple || false };
      console.log('__TERMWEB_PICKER__:file:' + (options?.multiple ? 'multiple' : 'single'));
    });
  };

  window.showSaveFilePicker = function(options) {
    return new Promise((resolve, reject) => {
      window.__termwebPendingPicker = { resolve, reject, multiple: false };
      console.log('__TERMWEB_PICKER__:save:' + (options?.suggestedName || 'file'));
    });
  };
})();
