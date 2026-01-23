#!/usr/bin/env node
/**
 * VS Code Web - Run vscode.dev as a terminal app
 *
 * Features:
 * - Opens vscode.dev in terminal with Kitty graphics
 * - Option to hide navigation bar for app-like experience
 *
 * Usage:
 *   node examples/vscode-app.js
 *   node examples/vscode-app.js --no-toolbar
 *
 * Or directly:
 *   termweb open https://vscode.dev --no-toolbar
 */

const { spawn } = require('../lib');

const args = process.argv.slice(2);
const noToolbar = args.includes('--no-toolbar') || args.includes('--hide-nav');

console.log('Starting VS Code Web...');
console.log('');
console.log('Options:');
console.log('  --no-toolbar:', noToolbar);
console.log('');
console.log('Keybindings:');
console.log('  Cmd/Ctrl+Q  - Quit termweb');
console.log('  Cmd/Ctrl+B  - Toggle sidebar (VS Code)');
console.log('  Cmd/Ctrl+P  - Quick open (VS Code)');
console.log('  Cmd/Ctrl+Shift+P - Command palette (VS Code)');
console.log('');

// Build termweb args
const termwebArgs = ['open', 'https://vscode.dev'];
if (noToolbar) {
  termwebArgs.push('--no-toolbar');
}

const proc = spawn(termwebArgs, {
  stdio: 'inherit',
});

proc.on('exit', (code) => {
  process.exit(code || 0);
});

proc.on('error', (err) => {
  console.error('Failed to start:', err.message);
  process.exit(1);
});
