/**
 * Jupyter Kernel management
 * Spawns ipykernel and manages communication via Jupyter protocol
 */
const { spawn } = require('child_process');
const WebSocket = require('ws');
const { v4: uuidv4 } = require('uuid');
const path = require('path');
const fs = require('fs');
const os = require('os');

/**
 * Find Python executable
 */
function findPython() {
  const candidates = ['python3', 'python'];
  for (const cmd of candidates) {
    try {
      const result = require('child_process').execSync(`which ${cmd}`, { encoding: 'utf-8' });
      if (result.trim()) return result.trim();
    } catch (e) {}
  }
  return null;
}

/**
 * Check if ipykernel is installed
 */
function checkIpykernel(python) {
  try {
    require('child_process').execSync(`${python} -c "import ipykernel"`, { stdio: 'ignore' });
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * Spawn a Jupyter kernel
 * @returns {Promise<{process: ChildProcess, connectionFile: string, shellPort: number}>}
 */
async function spawnKernel() {
  const python = findPython();
  if (!python) {
    throw new Error('Python not found. Please install Python 3.');
  }

  if (!checkIpykernel(python)) {
    throw new Error('ipykernel not installed. Run: pip install ipykernel');
  }

  // Create connection file
  const connectionFile = path.join(os.tmpdir(), `kernel-${uuidv4()}.json`);
  const shellPort = 50000 + Math.floor(Math.random() * 10000);
  const iopubPort = shellPort + 1;
  const stdinPort = shellPort + 2;
  const hbPort = shellPort + 3;
  const controlPort = shellPort + 4;

  const connectionInfo = {
    shell_port: shellPort,
    iopub_port: iopubPort,
    stdin_port: stdinPort,
    hb_port: hbPort,
    control_port: controlPort,
    ip: '127.0.0.1',
    key: uuidv4().replace(/-/g, ''),
    transport: 'tcp',
    signature_scheme: 'hmac-sha256',
    kernel_name: 'python3'
  };

  fs.writeFileSync(connectionFile, JSON.stringify(connectionInfo, null, 2));

  // Spawn kernel
  const kernelProcess = spawn(python, [
    '-m', 'ipykernel_launcher',
    '-f', connectionFile
  ], {
    stdio: ['ignore', 'pipe', 'pipe']
  });

  // Wait for kernel to start
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Kernel startup timeout')), 10000);

    kernelProcess.stderr.on('data', (data) => {
      const msg = data.toString();
      if (msg.includes('Starting') || msg.includes('kernel')) {
        clearTimeout(timeout);
        setTimeout(resolve, 500); // Give kernel time to fully start
      }
    });

    kernelProcess.on('error', (err) => {
      clearTimeout(timeout);
      reject(err);
    });

    kernelProcess.on('exit', (code) => {
      if (code !== 0) {
        clearTimeout(timeout);
        reject(new Error(`Kernel exited with code ${code}`));
      }
    });
  });

  return {
    process: kernelProcess,
    connectionFile,
    connectionInfo
  };
}

/**
 * Execute code in kernel (simplified version - uses subprocess)
 */
async function executeCode(python, code) {
  return new Promise((resolve, reject) => {
    const proc = spawn(python, ['-c', code], {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';

    proc.stdout.on('data', (data) => { stdout += data; });
    proc.stderr.on('data', (data) => { stderr += data; });

    proc.on('close', (code) => {
      resolve({
        output: stdout,
        error: stderr,
        exitCode: code
      });
    });

    proc.on('error', reject);
  });
}

module.exports = {
  findPython,
  checkIpykernel,
  spawnKernel,
  executeCode
};
