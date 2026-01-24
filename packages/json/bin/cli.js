#!/usr/bin/env node

const path = require('path');
const fs = require('fs');
const termweb = require('termweb');

const args = process.argv.slice(2);
const verbose = args.includes('--verbose') || args.includes('-v');
const filteredArgs = args.filter(a => a !== '--verbose' && a !== '-v');

if (filteredArgs.length === 0 || filteredArgs[0] === '--help' || filteredArgs[0] === '-h') {
  console.log(`
@termweb/json - Terminal JSON Editor

Usage: termweb-json <file>

Arguments:
  file    Path to JSON file to edit

Options:
  -h, --help     Show this help message
  -v, --verbose  Debug output

Examples:
  termweb-json ./package.json
  termweb-json ~/config/settings.json
`);
  process.exit(0);
}

const filePath = path.resolve(filteredArgs[0]);

// Check if file exists, create if not
if (!fs.existsSync(filePath)) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(filePath, '{\n  \n}\n');
}

const content = fs.readFileSync(filePath, 'utf-8');
const htmlPath = path.join(__dirname, '..', 'dist', 'index.html');

// Build URL with params
const params = new URLSearchParams();
params.set('path', filePath);
params.set('content', Buffer.from(content).toString('base64'));

const url = `file://${htmlPath}?${params.toString()}`;

termweb.open(url, { toolbar: false, verbose })
  .then(() => process.exit(0))
  .catch(err => {
    console.error('Error:', err.message);
    process.exit(1);
  });
