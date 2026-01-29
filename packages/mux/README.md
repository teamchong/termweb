# termweb-mux

Terminal multiplexer with VT compression, OPFS persistence, and libghostty-vt rendering.

## Features

- **Multiplexing**: Multiple terminal sessions over single WebSocket
- **Compression**: VT sequences compressed with zlib (minimal bandwidth)
- **Persistence**: OPFS storage for scrollback history in browser
- **Modern Terminal**: Will use libghostty-vt for proper VT100 emulation

## Usage

### Server

```bash
npx termweb-mux
# or
npm install -g termweb-mux
termweb-mux
```

Or programmatically:

```javascript
const { createServer } = require('termweb-mux');

const server = createServer({ port: 7682, compression: true });
```

### Client (Browser)

```html
<script src="https://cdn.jsdelivr.net/npm/pako@2.1.0/dist/pako.min.js"></script>
<script src="dist/client.bundle.js"></script>
<script>
const client = new MuxClient('ws://localhost:7682');

client.onConnect = () => console.log('Connected');
client.onDisconnect = () => console.log('Disconnected');
client.onError = (err) => console.error(err);

await client.connect();

// Create a terminal session
const sessionId = await client.createSession({
  onData: (data) => {
    // Render VT sequences (use xterm.js or libghostty-vt)
    terminal.write(data);
  },
  onExit: (code) => {
    console.log('Session exited:', code);
  }
}, { cols: 120, rows: 40 });

// Send input
client.write(sessionId, 'ls -la\n');

// Resize terminal
client.resize(sessionId, 120, 40);

// List sessions
const sessions = await client.listSessions();

// Kill session
client.kill(sessionId);
</script>
```

## Protocol (JSON over WebSocket)

### Client -> Server

```javascript
// Create session
{ type: 'create', cols: 80, rows: 24, shell: '/bin/bash' }

// Send input
{ type: 'input', sessionId: 1, data: 'ls -la\n' }

// Resize
{ type: 'resize', sessionId: 1, cols: 120, rows: 40 }

// Kill session
{ type: 'kill', sessionId: 1 }

// List sessions
{ type: 'list' }

// Attach to existing session
{ type: 'attach', sessionId: 1 }

// Get scrollback
{ type: 'scrollback', sessionId: 1 }
```

### Server -> Client

```javascript
// Connected
{ type: 'connected', clientId: 'abc123' }

// Session created
{ type: 'created', sessionId: 1 }

// Terminal output (compressed)
{ type: 'data', sessionId: 1, data: '<base64 zlib>', compressed: true }

// Terminal output (uncompressed)
{ type: 'data', sessionId: 1, data: 'raw vt data' }

// Session exited
{ type: 'exit', sessionId: 1, code: 0 }

// Session list
{ type: 'sessions', sessions: [{ id: 1, cols: 80, rows: 24 }] }

// Error
{ type: 'error', error: 'message' }
```

## OPFS Persistence

The browser client automatically saves scrollback to OPFS (Origin Private File System):

```javascript
// Load persisted scrollback
const scrollback = await client.loadFromOPFS(sessionId);

// Clear persisted data
await client.clearOPFS(sessionId);
```

## Roadmap

- [ ] Integrate libghostty-vt WASM for proper VT emulation
- [ ] File transfer support via OPFS
- [ ] Session reconnection after disconnect
- [ ] Shared sessions (collaboration)
- [ ] Binary protocol option for lower overhead

## License

MIT
