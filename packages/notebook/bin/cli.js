#!/usr/bin/env node

const path = require('path');
const fs = require('fs');
const termweb = require('termweb');
const { startServer } = require('../lib/server');

const args = process.argv.slice(2);
const verbose = args.includes('--verbose') || args.includes('-v');

const filteredArgs = args.filter(a => a !== '--verbose' && a !== '-v');

if (filteredArgs[0] === '--help' || filteredArgs[0] === '-h') {
  console.log(`
@termweb/notebook - Terminal Jupyter Notebook Viewer/Editor

Usage: termweb-notebook [file.ipynb] [options]

Arguments:
  file.ipynb    Notebook file to open (optional)

Options:
  -v, --verbose   Debug output
  -h, --help      Show help

Note: This is a view/edit mode only. Code execution is not supported.
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
    // Read notebook content if file exists
    let notebookContent = '{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}';
    if (notebookPath && fs.existsSync(notebookPath)) {
      notebookContent = fs.readFileSync(notebookPath, 'utf-8');
    }

    // Use file:// URL with notebook content as parameter
    const htmlPath = path.join(__dirname, '..', 'dist', 'index.html');
    const params = new URLSearchParams();
    params.set('content', Buffer.from(notebookContent).toString('base64'));
    if (notebookPath) {
      params.set('path', notebookPath);
    }

    const url = `file://${htmlPath}?${params.toString()}`;

    await termweb.open(url, { toolbar: false, verbose });
    process.exit(0);
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

main();
