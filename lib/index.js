/**
 * Termweb SDK - Web browser in your terminal
 *
 * Usage:
 *   const termweb = require('termweb');
 *   termweb.open('https://example.com');
 */

const { spawn: nodeSpawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const platformMap = {
  darwin: 'macos',
  linux: 'linux',
};

const archMap = {
  x64: 'x86_64',
  arm64: 'aarch64',
};

/**
 * Get path to termweb binary for current platform
 */
function getBinaryPath() {
  const platform = process.platform;
  const arch = process.arch;

  const platformName = platformMap[platform];
  const archName = archMap[arch];

  if (!platformName || !archName) {
    throw new Error(`Unsupported platform: ${platform}-${arch}`);
  }

  const binaryName = `termweb-${platformName}-${archName}`;
  const binaryPath = path.join(__dirname, '..', 'binaries', binaryName);

  if (!fs.existsSync(binaryPath)) {
    throw new Error(`Binary not found: ${binaryPath}. Run npm install to download.`);
  }

  return binaryPath;
}

/**
 * Open a URL in termweb
 * @param {string} url - URL to open
 * @param {Object} options - Options
 * @param {boolean} [options.mobile] - Use mobile viewport
 * @param {boolean} [options.toolbar] - Show toolbar (default: true)
 * @param {number} [options.scale] - Page scale factor
 * @returns {ChildProcess} - Spawned process
 */
function open(url, options = {}) {
  const binaryPath = getBinaryPath();

  // Ensure binary is executable
  try {
    fs.chmodSync(binaryPath, 0o755);
  } catch (e) {
    // Ignore chmod errors
  }

  const args = ['open', url];

  if (options.mobile) {
    args.push('--mobile');
  }

  if (options.toolbar === false) {
    args.push('--no-toolbar');
  }

  if (options.scale) {
    args.push('--scale', String(options.scale));
  }

  return nodeSpawn(binaryPath, args, {
    stdio: 'inherit',
  });
}

/**
 * Check if termweb is available on this platform
 */
function isAvailable() {
  try {
    getBinaryPath();
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * Get termweb version
 */
function version() {
  return require('../package.json').version;
}

module.exports = {
  open,
  isAvailable,
  version,
  getBinaryPath,
};
