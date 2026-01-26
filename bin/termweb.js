#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const platform = process.platform;
const arch = process.arch;

// Map Node.js platform/arch to our binary names
const platformMap = {
  darwin: 'macos',
  linux: 'linux',
};

const archMap = {
  x64: 'x86_64',
  arm64: 'aarch64',
};

const platformName = platformMap[platform];
const archName = archMap[arch];

if (!platformName || !archName) {
  console.error(`Unsupported platform: ${platform}-${arch}`);
  process.exit(1);
}

const binaryName = `termweb-${platformName}-${archName}`;
const binaryPath = path.join(__dirname, '..', 'native', binaryName);

if (!fs.existsSync(binaryPath)) {
  console.error(`Binary not found: ${binaryPath}`);
  console.error('Please reinstall: npm install termweb');
  process.exit(1);
}

// Make sure binary is executable
try {
  fs.chmodSync(binaryPath, 0o755);
} catch (e) {
  // Ignore chmod errors on Windows
}

// Spawn the binary with all arguments
const child = spawn(binaryPath, process.argv.slice(2), {
  stdio: 'inherit',
  env: process.env,
});

child.on('error', (err) => {
  console.error('Failed to start termweb:', err.message);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.exit(1);
  }
  process.exit(code ?? 0);
});
