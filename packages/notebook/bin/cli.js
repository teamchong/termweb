#!/usr/bin/env node

const path = require('path');
const fs = require('fs');
const termweb = require('termweb');
const { startServer } = require('../lib/server');
const { resolveDisplayMode } = require('@termweb/shared');

const args = process.argv.slice(2);
const verbose = args.includes('--verbose') || args.includes('-v');

// Parse mode flag
let requestedMode = 'auto';
const modeIdx = args.indexOf('--mode');
if (modeIdx !== -1 && args[modeIdx + 1]) {
  requestedMode = args[modeIdx + 1];
}

const filteredArgs = args.filter((a, i) =>
  a !== '--verbose' && a !== '-v' &&
  a !== '--mode' && args[i - 1] !== '--mode'
);

if (filteredArgs[0] === '--help' || filteredArgs[0] === '-h') {
  console.log(`
@termweb/notebook - Terminal Jupyter Notebook

Usage: termweb-notebook [file.ipynb] [options]

Arguments:
  file.ipynb    Notebook file to open (optional)

Options:
  --mode <mode>   Display mode: auto, embedded, standalone
  -v, --verbose   Debug output
  -h, --help      Show help

Requirements:
  - Python 3
  - ipykernel (pip install ipykernel)
`);
  process.exit(0);
}

const notebookPath = filteredArgs[0] ? path.resolve(filteredArgs[0]) : null;

if (notebookPath && !notebookPath.endsWith('.ipynb')) {
  console.error('Error: File must be a Jupyter notebook (.ipynb)');
  process.exit(1);
}

async function main() {
  try {
    // Start the notebook server
    const { port } = await startServer(notebookPath, 0);

    const url = `http://127.0.0.1:${port}`;

    // Resolve mode and open
    const mode = resolveDisplayMode(requestedMode);

    await termweb.open(url, { toolbar: false, verbose, mode });
    process.exit(0);
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

main();
