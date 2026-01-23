#!/usr/bin/env node
/**
 * VS Code Web - Run vscode.dev in terminal
 *
 * Usage:
 *   node examples/vscode-app.js
 *   node examples/vscode-app.js --no-toolbar
 */

const termweb = require('../lib');

const args = process.argv.slice(2);
const noToolbar = args.includes('--no-toolbar') || args.includes('--hide-nav');

console.log('Starting VS Code Web...');
console.log('');
console.log('Keybindings:');
console.log('  Cmd/Ctrl+Q  - Quit');
console.log('  Cmd/Ctrl+B  - Toggle sidebar');
console.log('  Cmd/Ctrl+P  - Quick open');
console.log('');

termweb.open('https://vscode.dev', { toolbar: !noToolbar });
