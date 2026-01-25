#!/usr/bin/env node

const path = require('path');
const fs = require('fs');
const termweb = require('termweb');

const args = process.argv.slice(2);
const verbose = args.includes('--verbose') || args.includes('-v');

const filteredArgs = args.filter(a => a !== '--verbose' && a !== '-v');

if (filteredArgs[0] === '--help' || filteredArgs[0] === '-h') {
  console.log(`
@termweb/pdf - Terminal PDF Viewer

Usage: termweb-pdf <file.pdf> [options]

Arguments:
  file.pdf    PDF file to open

Options:
  -v, --verbose   Debug output
  -h, --help      Show help

Note: Opens PDF with download option. For full rendering, use system PDF viewer.
`);
  process.exit(0);
}

const pdfPath = filteredArgs[0] ? path.resolve(filteredArgs[0]) : null;

if (!pdfPath) {
  console.error('Error: Please specify a PDF file');
  process.exit(1);
}

if (!pdfPath.toLowerCase().endsWith('.pdf')) {
  console.error('Error: File must be a PDF');
  process.exit(1);
}

if (!fs.existsSync(pdfPath)) {
  console.error('Error: File not found:', pdfPath);
  process.exit(1);
}

const htmlPath = path.join(__dirname, '..', 'dist', 'index.html');
const params = new URLSearchParams();
params.set('file', pdfPath);
params.set('name', path.basename(pdfPath));
params.set('size', fs.statSync(pdfPath).size.toString());

const url = `file://${htmlPath}?${params.toString()}`;

termweb.open(url, { toolbar: false, allowedHotkeys: ['quit'], verbose })
  .then(() => process.exit(0))
  .catch(err => {
    console.error('Error:', err.message);
    process.exit(1);
  });
