/**
 * Binary utilities - spawn termweb process
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
 * Spawn termweb binary
 * @param {string[]} args - Command line arguments
 * @param {Object} options - spawn options
 */
function spawn(args = [], options = {}) {
  const binaryPath = getBinaryPath();

  // Ensure binary is executable
  try {
    fs.chmodSync(binaryPath, 0o755);
  } catch (e) {
    // Ignore chmod errors
  }

  return nodeSpawn(binaryPath, args, {
    stdio: 'inherit',
    ...options,
  });
}

module.exports = {
  getBinaryPath,
  spawn,
};
