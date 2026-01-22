#!/usr/bin/env node

const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const VERSION = require('../package.json').version;
const REPO = 'teamchong/termweb';

const platform = process.platform;
const arch = process.arch;

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
  console.error('termweb only supports macOS and Linux on x64 and arm64.');
  process.exit(1);
}

const binaryName = `termweb-${platformName}-${archName}`;
const binariesDir = path.join(__dirname, '..', 'binaries');
const binaryPath = path.join(binariesDir, binaryName);

// Create binaries directory
if (!fs.existsSync(binariesDir)) {
  fs.mkdirSync(binariesDir, { recursive: true });
}

// Check if binary already exists
if (fs.existsSync(binaryPath)) {
  console.log(`termweb binary already installed at ${binaryPath}`);
  process.exit(0);
}

// Download URL from GitHub releases
const downloadUrl = `https://github.com/${REPO}/releases/download/v${VERSION}/${binaryName}`;

console.log(`Downloading termweb for ${platformName}-${archName}...`);
console.log(`URL: ${downloadUrl}`);

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);

    const request = https.get(url, (response) => {
      // Handle redirects
      if (response.statusCode === 301 || response.statusCode === 302) {
        file.close();
        fs.unlinkSync(dest);
        return download(response.headers.location, dest).then(resolve).catch(reject);
      }

      if (response.statusCode !== 200) {
        file.close();
        fs.unlinkSync(dest);
        reject(new Error(`Failed to download: HTTP ${response.statusCode}`));
        return;
      }

      response.pipe(file);

      file.on('finish', () => {
        file.close();
        resolve();
      });
    });

    request.on('error', (err) => {
      file.close();
      fs.unlink(dest, () => {}); // Delete partial file
      reject(err);
    });

    file.on('error', (err) => {
      file.close();
      fs.unlink(dest, () => {});
      reject(err);
    });
  });
}

async function main() {
  try {
    await download(downloadUrl, binaryPath);

    // Make executable
    fs.chmodSync(binaryPath, 0o755);

    console.log(`Successfully installed termweb to ${binaryPath}`);
  } catch (err) {
    console.error(`Failed to download termweb: ${err.message}`);
    console.error('');
    console.error('You can manually build from source:');
    console.error('  git clone https://github.com/' + REPO);
    console.error('  cd termweb && zig build');
    process.exit(1);
  }
}

main();
