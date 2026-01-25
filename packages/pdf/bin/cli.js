#!/usr/bin/env node

const path = require('path');
const fs = require('fs');
const termweb = require('termweb');
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
@termweb/pdf - Terminal PDF Viewer

Usage: termweb-pdf <file.pdf> [options]

Arguments:
  file.pdf    PDF file to view

Options:
  --mode <mode>   Display mode: auto, embedded, standalone
  -v, --verbose   Debug output
  -h, --help      Show help
`);
  process.exit(0);
}

if (!filteredArgs[0]) {
  console.error('Error: PDF file path required');
  console.error('Usage: termweb-pdf <file.pdf>');
  process.exit(1);
}

const pdfPath = path.resolve(filteredArgs[0]);

if (!fs.existsSync(pdfPath)) {
  console.error(`Error: File not found: ${pdfPath}`);
  process.exit(1);
}

if (!pdfPath.toLowerCase().endsWith('.pdf')) {
  console.error('Error: File must be a PDF');
  process.exit(1);
}

const htmlPath = path.join(__dirname, '..', 'dist', 'index.html');

// Build URL with params - use file:// protocol for the PDF
const params = new URLSearchParams();
params.set('file', `file://${pdfPath}`);

const url = `file://${htmlPath}?${params.toString()}`;

// Resolve mode and open
const mode = resolveDisplayMode(requestedMode);

termweb.open(url, { toolbar: false, verbose, mode })
  .then(() => process.exit(0))
  .catch(err => {
    console.error('Error:', err.message);
    process.exit(1);
  });
