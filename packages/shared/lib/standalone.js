#!/usr/bin/env node
/**
 * Standalone mode detection and helpers for termweb packages.
 *
 * This module provides utilities for detecting terminal capabilities
 * and opening URLs with automatic mode selection.
 *
 * The termweb SDK handles the actual spawning - these utilities
 * just determine the correct --mode flag to pass.
 */

const { spawn } = require('child_process');
const path = require('path');

/**
 * Terminal capability detection result
 * @readonly
 * @enum {string}
 */
const TerminalCapability = {
  KITTY_COMPATIBLE: 'kitty_compatible',
  INCOMPATIBLE: 'incompatible',
  UNKNOWN: 'unknown'
};

/**
 * Display mode options
 * @readonly
 * @enum {string}
 */
const DisplayMode = {
  AUTO: 'auto',
  EMBEDDED: 'embedded',
  STANDALONE: 'standalone'
};

/**
 * Detect if the current terminal supports Kitty graphics protocol.
 *
 * @returns {string} TerminalCapability value
 */
function detectTerminalCapability() {
  const termProgram = process.env.TERM_PROGRAM || '';
  const term = process.env.TERM || '';

  // Known Kitty-compatible terminals
  const kittyCompatible = ['ghostty', 'wezterm', 'kitty'];

  // Check TERM_PROGRAM
  const termProgramLower = termProgram.toLowerCase();
  if (kittyCompatible.some(t => termProgramLower.includes(t))) {
    return TerminalCapability.KITTY_COMPATIBLE;
  }

  // Known incompatible terminals
  const incompatible = ['apple_terminal', 'iterm.app', 'vscode', 'hyper', 'terminus'];
  if (incompatible.some(t => termProgramLower.includes(t))) {
    return TerminalCapability.INCOMPATIBLE;
  }

  // Check TERM
  const termLower = term.toLowerCase();
  if (kittyCompatible.some(t => termLower.includes(t))) {
    return TerminalCapability.KITTY_COMPATIBLE;
  }

  return TerminalCapability.UNKNOWN;
}

/**
 * Check if running in a Kitty-compatible terminal
 *
 * @returns {boolean}
 */
function isKittyCompatible() {
  const capability = detectTerminalCapability();
  return capability === TerminalCapability.KITTY_COMPATIBLE ||
         capability === TerminalCapability.UNKNOWN; // Assume yes for SSH
}

/**
 * Resolve display mode based on requested mode and terminal capability
 *
 * @param {string} requestedMode - DisplayMode value
 * @returns {string} Resolved DisplayMode value
 */
function resolveDisplayMode(requestedMode = DisplayMode.AUTO) {
  if (requestedMode === DisplayMode.EMBEDDED || requestedMode === DisplayMode.STANDALONE) {
    return requestedMode;
  }

  const capability = detectTerminalCapability();
  switch (capability) {
    case TerminalCapability.KITTY_COMPATIBLE:
      return DisplayMode.EMBEDDED;
    case TerminalCapability.INCOMPATIBLE:
      return DisplayMode.STANDALONE;
    case TerminalCapability.UNKNOWN:
    default:
      return DisplayMode.EMBEDDED; // SSH compatibility
  }
}

/**
 * Open a URL with termweb, automatically detecting the best display mode.
 *
 * @param {string} url - URL to open
 * @param {Object} options - Options
 * @param {string} [options.mode='auto'] - Display mode: 'auto', 'embedded', 'standalone'
 * @param {boolean} [options.noToolbar=false] - Hide toolbar
 * @param {boolean} [options.verbose=false] - Enable verbose output
 * @param {string} [options.profile] - Chrome profile to use
 * @returns {Promise<void>}
 */
async function openWithTermweb(url, options = {}) {
  const termweb = require('termweb');

  const mode = resolveDisplayMode(options.mode || DisplayMode.AUTO);

  const termwebOptions = {
    noToolbar: options.noToolbar || false,
    mode: mode
  };

  if (options.profile) {
    termwebOptions.profile = options.profile;
  }

  return termweb.open(url, termwebOptions);
}

/**
 * Get termweb CLI arguments for the current mode
 *
 * @param {string} requestedMode - DisplayMode value
 * @returns {string[]} CLI arguments to pass to termweb
 */
function getModeArgs(requestedMode = DisplayMode.AUTO) {
  const mode = resolveDisplayMode(requestedMode);
  return ['--mode', mode];
}

module.exports = {
  TerminalCapability,
  DisplayMode,
  detectTerminalCapability,
  isKittyCompatible,
  resolveDisplayMode,
  openWithTermweb,
  getModeArgs
};
