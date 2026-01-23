#!/usr/bin/env node
/**
 * Hello World - Basic termweb example
 *
 * Usage: node examples/hello-world.js
 */

const termweb = require('../lib');

console.log('Opening example.com...');
console.log('Press Cmd/Ctrl+Q to quit');
console.log('');

termweb.open('https://example.com');
