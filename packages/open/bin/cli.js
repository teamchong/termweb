#!/usr/bin/env node

const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

// File type detection
const FILE_TYPES = {
  // PDF
  pdf: { extensions: ['.pdf'], handler: 'termweb-pdf' },

  // Markdown
  markdown: { extensions: ['.md', '.markdown', '.mdown', '.mkd'], handler: 'termweb-markdown' },

  // Jupyter Notebook
  notebook: { extensions: ['.ipynb'], handler: 'termweb-notebook' },

  // JSON
  json: { extensions: ['.json', '.jsonc', '.json5'], handler: 'termweb-json' },

  // Images (handled by built-in viewer)
  image: {
    extensions: ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.svg', '.tiff', '.tif'],
    handler: 'builtin:image'
  },

  // Video (spawn mpv or system player)
  video: {
    extensions: ['.mp4', '.webm', '.mkv', '.avi', '.mov', '.m4v', '.ogv', '.wmv'],
    handler: 'system:video'
  },

  // Audio (spawn system player)
  audio: {
    extensions: ['.mp3', '.wav', '.ogg', '.flac', '.m4a', '.aac', '.wma'],
    handler: 'system:audio'
  },

  // Code/Text (handled by termweb-editor)
  code: {
    extensions: [
      '.js', '.ts', '.jsx', '.tsx', '.mjs', '.cjs',
      '.py', '.rb', '.php', '.java', '.kt', '.scala', '.clj',
      '.go', '.rs', '.c', '.cpp', '.cc', '.h', '.hpp', '.hh',
      '.cs', '.fs', '.swift', '.m', '.mm',
      '.zig', '.nim', '.v', '.d', '.lua', '.pl', '.pm',
      '.sh', '.bash', '.zsh', '.fish', '.ps1',
      '.sql', '.graphql', '.gql',
      '.html', '.htm', '.css', '.scss', '.sass', '.less',
      '.xml', '.yaml', '.yml', '.toml', '.ini', '.cfg', '.conf',
      '.vue', '.svelte', '.astro',
      '.ex', '.exs', '.erl', '.hrl', '.hs', '.ml', '.mli',
      '.r', '.R', '.jl', '.dart', '.elm',
      '.txt', '.log', '.csv', '.tsv',
      '.env', '.gitignore', '.dockerignore', '.editorconfig',
      '.lock', '.sum'
    ],
    handler: 'termweb-editor'
  }
};

function getFileType(filePath) {
  const ext = path.extname(filePath).toLowerCase();

  for (const [type, config] of Object.entries(FILE_TYPES)) {
    if (config.extensions.includes(ext)) {
      return { type, ...config };
    }
  }

  // Check magic bytes for files without recognized extension
  return detectByMagic(filePath);
}

function detectByMagic(filePath) {
  try {
    const fd = fs.openSync(filePath, 'r');
    const buffer = Buffer.alloc(16);
    fs.readSync(fd, buffer, 0, 16, 0);
    fs.closeSync(fd);

    // PDF: %PDF
    if (buffer.toString('ascii', 0, 4) === '%PDF') {
      return { type: 'pdf', handler: 'termweb-pdf' };
    }

    // PNG: 89 50 4E 47
    if (buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4E && buffer[3] === 0x47) {
      return { type: 'image', handler: 'builtin:image' };
    }

    // JPEG: FF D8 FF
    if (buffer[0] === 0xFF && buffer[1] === 0xD8 && buffer[2] === 0xFF) {
      return { type: 'image', handler: 'builtin:image' };
    }

    // GIF: GIF8
    if (buffer.toString('ascii', 0, 4) === 'GIF8') {
      return { type: 'image', handler: 'builtin:image' };
    }

    // Check if it's likely text
    let printable = 0;
    for (let i = 0; i < buffer.length; i++) {
      const b = buffer[i];
      if ((b >= 0x20 && b <= 0x7E) || b === 0x0A || b === 0x0D || b === 0x09) {
        printable++;
      } else if (b === 0x00) {
        // Null byte = likely binary
        return { type: 'binary', handler: 'termweb-editor' };
      }
    }

    // If mostly printable, treat as text
    if (printable / buffer.length > 0.8) {
      return { type: 'text', handler: 'termweb-editor' };
    }

    return { type: 'binary', handler: 'termweb-editor' };
  } catch (e) {
    return { type: 'unknown', handler: 'termweb-editor' };
  }
}

function tryResolve(moduleName) {
  try {
    require.resolve(moduleName);
    return true;
  } catch {
    return false;
  }
}

function spawnHandler(handler, filePath, verbose) {
  return new Promise((resolve, reject) => {
    const args = [filePath];
    if (verbose) args.push('--verbose');

    const child = spawn(handler, args, {
      stdio: 'inherit',
      shell: process.platform === 'win32'
    });

    child.on('error', (err) => {
      reject(new Error(`Failed to spawn ${handler}: ${err.message}`));
    });

    child.on('close', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${handler} exited with code ${code}`));
      }
    });
  });
}

async function openImage(filePath, verbose) {
  const termweb = require('termweb');
  const htmlPath = path.join(__dirname, '..', 'dist', 'index.html');

  const params = new URLSearchParams();
  params.set('file', filePath);
  params.set('name', path.basename(filePath));
  params.set('type', 'image');

  const url = `file://${htmlPath}?${params.toString()}`;

  await termweb.open(url, { toolbar: false, allowedHotkeys: ['quit'], verbose });
}

async function openVideo(filePath, verbose) {
  // Try mpv first, then open with system player
  const players = ['mpv', 'vlc', 'ffplay'];

  for (const player of players) {
    try {
      await spawnHandler(player, filePath, verbose);
      return;
    } catch {
      continue;
    }
  }

  // Fall back to system open
  const openCmd = process.platform === 'darwin' ? 'open' : 'xdg-open';
  await spawnHandler(openCmd, filePath, verbose);
}

async function main() {
  const args = process.argv.slice(2);
  const verbose = args.includes('--verbose') || args.includes('-v');
  const filteredArgs = args.filter(a => a !== '--verbose' && a !== '-v');

  if (filteredArgs[0] === '--help' || filteredArgs[0] === '-h') {
    console.log(`
termweb-open - Universal file opener

Usage: termweb-open <file> [options]

Opens files with the appropriate viewer/editor:

  PDF (.pdf)           -> termweb-pdf
  Markdown (.md)       -> termweb-markdown
  Jupyter (.ipynb)     -> termweb-notebook
  JSON (.json)         -> termweb-json
  Images (.png, .jpg)  -> Built-in image viewer
  Video (.mp4, .mkv)   -> mpv/vlc/system player
  Code/Text            -> termweb-editor

Options:
  -v, --verbose   Debug output
  -h, --help      Show help

Examples:
  termweb-open document.pdf
  termweb-open README.md
  termweb-open data.json
  termweb-open photo.png
  termweb-open main.py
`);
    process.exit(0);
  }

  const filePath = filteredArgs[0];

  if (!filePath) {
    console.error('Error: Please specify a file to open');
    console.error('Usage: termweb-open <file>');
    process.exit(1);
  }

  const absPath = path.resolve(filePath);

  if (!fs.existsSync(absPath)) {
    console.error(`Error: File not found: ${absPath}`);
    process.exit(1);
  }

  const fileInfo = getFileType(absPath);

  if (verbose) {
    console.log(`[open] File: ${absPath}`);
    console.log(`[open] Type: ${fileInfo.type}`);
    console.log(`[open] Handler: ${fileInfo.handler}`);
  }

  try {
    if (fileInfo.handler === 'builtin:image') {
      await openImage(absPath, verbose);
    } else if (fileInfo.handler === 'system:video' || fileInfo.handler === 'system:audio') {
      await openVideo(absPath, verbose);
    } else {
      // Try to spawn the handler
      if (tryResolve(fileInfo.handler)) {
        await spawnHandler(fileInfo.handler, absPath, verbose);
      } else {
        // Handler not installed, fall back to termweb-editor
        if (verbose) {
          console.log(`[open] ${fileInfo.handler} not found, falling back to termweb-editor`);
        }

        if (tryResolve('termweb-editor')) {
          await spawnHandler('termweb-editor', absPath, verbose);
        } else {
          // Last resort: use termweb directly with file:// URL
          const termweb = require('termweb');
          await termweb.open(`file://${absPath}`, { toolbar: true, verbose });
        }
      }
    }

    process.exit(0);
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

main();
