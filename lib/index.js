/**
 * Termweb SDK - Build terminal apps with web technologies
 *
 * Like Electron, but for terminals with Kitty graphics support.
 *
 * Usage levels:
 * 1. High-level (Electron-like):
 *    const { app, BrowserWindow } = require('termweb');
 *
 * 2. Mid-level (component access):
 *    const { CDP, KittyGraphics, Terminal } = require('termweb');
 *
 * 3. Low-level (direct binary):
 *    const { spawn } = require('termweb');
 */

const app = require('./app');
const BrowserWindow = require('./browser-window');
const { ipcMain } = require('./ipc');
const CDP = require('./cdp');
const KittyGraphics = require('./kitty');
const Terminal = require('./terminal');
const { spawn, getBinaryPath } = require('./binary');

module.exports = {
  // High-level Electron-like API
  app,
  BrowserWindow,
  ipcMain,

  // Mid-level component access
  CDP,
  KittyGraphics,
  Terminal,

  // Low-level
  spawn,
  getBinaryPath,
};
