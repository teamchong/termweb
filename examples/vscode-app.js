#!/usr/bin/env node
/**
 * VS Code Web - Run vscode.dev in terminal (no toolbar)
 */

const termweb = require('../lib');

termweb.open('https://vscode.dev', { toolbar: false });
