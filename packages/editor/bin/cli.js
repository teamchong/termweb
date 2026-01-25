#!/usr/bin/env node

const path = require('path');
const fs = require('fs');
const termweb = require('termweb');

const args = process.argv.slice(2);
const verbose = args.includes('--verbose') || args.includes('-v');

const filteredArgs = args.filter(a => a !== '--verbose' && a !== '-v');

if (filteredArgs[0] === '--help' || filteredArgs[0] === '-h') {
  console.log(`
@termweb/editor - Terminal Code Editor

Usage: termweb-editor [path] [options]

Arguments:
  path    File or directory to open (default: current directory)

Options:
  -v, --verbose   Debug output
  -h, --help      Show help
`);
  process.exit(0);
}

const targetPath = path.resolve(filteredArgs[0] || '.');
const isDirectory = fs.existsSync(targetPath) && fs.statSync(targetPath).isDirectory();
const htmlPath = path.join(__dirname, '..', 'dist', 'index.html');

// Build URL with params
const params = new URLSearchParams();
params.set('path', targetPath);
params.set('isDir', isDirectory ? '1' : '0');

// For files, pass initial content
if (!isDirectory && fs.existsSync(targetPath)) {
  const content = fs.readFileSync(targetPath, 'utf-8');
  params.set('content', Buffer.from(content).toString('base64'));
}

const url = `file://${htmlPath}?${params.toString()}`;

termweb.open(url, { toolbar: false, allowedHotkeys: ['quit'], verbose })
  .then(() => process.exit(0))
  .catch(err => {
    console.error('Error:', err.message);
    process.exit(1);
  });
