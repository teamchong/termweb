/**
 * System metrics collector using systeminformation + native Zig addon
 * Native addon provides fastest path (direct OS API calls via Zig)
 * Falls back to systeminformation when native is unavailable
 */
const si = require('systeminformation');
const { exec } = require('child_process');

// Load native metrics from prebuilt binaries (platform-specific)
let nativeMetrics = null;
try {
  const os = require('os');
  const path = require('path');
  const platform = process.platform; // darwin, linux
  const arch = process.arch; // arm64, x64
  const binaryName = `metrics-${platform}-${arch}.node`;

  // Try prebuilt binary first (from npm package)
  const prebuiltPath = path.join(__dirname, '..', 'native', 'prebuilt', binaryName);
  try {
    nativeMetrics = require(prebuiltPath);
  } catch (e) {
    // Try local dev build (zig-out)
    const devPath = path.join(__dirname, '..', 'native', 'zig-out', 'lib', 'metrics.node');
    nativeMetrics = require(devPath);
  }
} catch (e) {
  // Native metrics not available, will use systeminformation fallback
}

// Cache for port info (expensive to fetch on macOS)
let portCache = new Map();
let portCacheTime = 0;
const PORT_CACHE_TTL = process.platform === 'linux' ? 5000 : 30000; // Linux: 5s, macOS: 30s (lsof is slow)

// Cache for heavy metrics (collected in background)
let metricsCache = null;
let metricsCacheTime = 0;
let metricsRefreshing = false;
const METRICS_CACHE_TTL = 500; // 500ms - return cached data quickly

/**
 * Get port info for processes (cached, non-blocking on macOS)
 * Linux: uses ss (fast, ~10ms)
 * macOS: uses lsof which is very slow (5-20s), so we fetch in background
 */
async function getPortInfo() {
  const now = Date.now();

  // Return cache if fresh
  if (now - portCacheTime < PORT_CACHE_TTL && portCache.size > 0) {
    return portCache;
  }

  const isLinux = process.platform === 'linux';

  // On macOS, return stale cache and refresh in background (non-blocking)
  // lsof is too slow (5-20 seconds) to block on every call
  if (!isLinux) {
    // Start background refresh if not already running
    if (!portRefreshing) {
      portRefreshing = true;
      exec('lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null || true', {
        encoding: 'utf-8',
        timeout: 30000
      }, (err, output) => {
        portRefreshing = false;
        if (!err && output) {
          const newCache = new Map();
          const lines = output.split('\n').slice(1);
          for (const line of lines) {
            const parts = line.split(/\s+/);
            if (parts.length >= 9) {
              const pid = parseInt(parts[1], 10);
              const portMatch = parts[8]?.match(/:(\d+)$/);
              if (pid && portMatch) {
                const port = portMatch[1];
                if (newCache.has(pid)) {
                  newCache.get(pid).push(port);
                } else {
                  newCache.set(pid, [port]);
                }
              }
            }
          }
          if (newCache.size > 0) {
            portCache = newCache;
            portCacheTime = Date.now();
          }
        }
      });
    }
    return portCache; // Return immediately (may be stale or empty)
  }

  // Linux: ss is fast enough to wait for
  return new Promise((resolve) => {
    exec('ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null', {
      encoding: 'utf-8',
      timeout: 2000
    }, (err, output) => {
      if (err || !output) {
        resolve(portCache);
        return;
      }

      const newCache = new Map();
      const lines = output.split('\n').slice(1);
      for (const line of lines) {
        const portMatch = line.match(/:(\d+)\s/);
        const pidMatch = line.match(/pid=(\d+)/);
        if (portMatch && pidMatch) {
          const port = portMatch[1];
          const pid = parseInt(pidMatch[1], 10);
          if (newCache.has(pid)) {
            newCache.get(pid).push(port);
          } else {
            newCache.set(pid, [port]);
          }
        }
      }

      if (newCache.size > 0) {
        portCache = newCache;
        portCacheTime = Date.now();
      }
      resolve(portCache);
    });
  });
}

let portRefreshing = false;

/**
 * Get fast disk stats using native addon or fallback to systeminformation
 */
async function getFastDisk() {
  if (nativeMetrics) {
    try {
      const disks = nativeMetrics.getDiskStats();
      return disks.map(d => ({
        fs: d.fs,
        mount: d.mount,
        type: 'disk',
        size: d.total,
        used: d.used,
        available: d.available,
        usePercent: d.total > 0 ? (d.used / d.total) * 100 : 0
      }));
    } catch (e) {
      // Fall through
    }
  }
  const disk = await si.fsSize();
  return disk
    .filter(d => {
      if (!d.size || isNaN(d.size) || d.size <= 0) return false;
      if (d.mount.startsWith('/System/Volumes/')) return false;
      if (d.mount.includes('/private/var/folders/')) return false;
      if (d.size < 1024 * 1024 * 1024) return false;
      return true;
    })
    .map(d => ({
      fs: d.fs,
      mount: d.mount,
      type: d.type,
      size: d.size,
      used: d.used,
      available: d.available,
      usePercent: d.use
    }));
}

/**
 * Get fast network stats using native addon or fallback to systeminformation
 */
let prevNetStats = null;
let prevNetTime = 0;

async function getFastNetwork() {
  if (nativeMetrics) {
    try {
      const nets = nativeMetrics.getNetStats();
      const now = Date.now();
      const elapsed = prevNetTime > 0 ? (now - prevNetTime) / 1000 : 1;

      const result = nets.map(n => {
        const prev = prevNetStats?.find(p => p.iface === n.iface);
        const rx_sec = prev ? Math.max(0, (n.rxBytes - prev.rxBytes) / elapsed) : 0;
        const tx_sec = prev ? Math.max(0, (n.txBytes - prev.txBytes) / elapsed) : 0;
        return {
          iface: n.iface,
          rx_bytes: n.rxBytes,
          tx_bytes: n.txBytes,
          rx_sec: Math.round(rx_sec),
          tx_sec: Math.round(tx_sec)
        };
      });

      prevNetStats = nets;
      prevNetTime = now;
      return result;
    } catch (e) {
      // Fall through
    }
  }
  const networkStats = await si.networkStats();
  return networkStats.map(n => ({
    iface: n.iface,
    rx_bytes: n.rx_bytes,
    tx_bytes: n.tx_bytes,
    rx_sec: n.rx_sec,
    tx_sec: n.tx_sec
  }));
}

/**
 * Get process stats using systeminformation
 * Native addon has permission issues on macOS, so we use si.processes() which handles this correctly
 */
async function getFastProcesses() {
  const ports = await getPortInfo();

  const processes = await si.processes();
  return {
    all: processes.all,
    running: processes.running,
    blocked: processes.blocked,
    sleeping: processes.sleeping,
    list: processes.list
      .sort((a, b) => b.cpu - a.cpu)
      .slice(0, 50)
      .map(p => ({
        pid: p.pid,
        name: p.name,
        cpu: p.cpu,
        mem: p.mem,
        state: p.state,
        user: p.user,
        ports: ports.get(p.pid) || []
      }))
  };
}

/**
 * Collect all system metrics
 * Uses native Zig addon when available for maximum performance
 * @returns {Promise<Object>} System metrics
 */
async function collectMetrics() {
  const [
    cpu,
    cpuLoad,
    mem,
    disk,
    network,
    processes,
    temp,
    system,
    osInfo
  ] = await Promise.all([
    si.cpu(),
    getFastCpuLoad(),
    getFastMemory(),
    getFastDisk(),
    getFastNetwork(),
    getFastProcesses(),
    si.cpuTemperature().catch(() => ({ main: null, cores: [] })),
    si.system(),
    si.osInfo()
  ]);

  return {
    timestamp: Date.now(),
    cpu: {
      manufacturer: cpu.manufacturer,
      brand: cpu.brand,
      cores: cpu.cores,
      physicalCores: cpu.physicalCores,
      speed: cpu.speed,
      load: cpuLoad.load,
      loadPerCore: cpuLoad.loadPerCore
    },
    memory: {
      total: mem.total,
      used: mem.used,
      free: mem.free,
      active: mem.active,
      available: mem.available,
      swapTotal: mem.swapTotal || 0,
      swapUsed: mem.swapUsed || 0
    },
    disk,
    network,
    processes,
    temperature: {
      main: temp.main,
      cores: temp.cores
    },
    system: {
      manufacturer: system.manufacturer,
      model: system.model
    },
    os: {
      platform: osInfo.platform,
      distro: osInfo.distro,
      release: osInfo.release,
      hostname: osInfo.hostname,
      uptime: si.time().uptime
    }
  };
}

// Fast CPU load reading - stores previous values for delta calculation
let prevCpuTimes = null;
let prevCoresTimes = null;

/**
 * Fast CPU load using native termweb SDK or /proc/stat fallback
 */
async function getFastCpuLoad() {
  // Use native termweb SDK if available (fastest - direct Mach/proc calls)
  if (nativeMetrics) {
    try {
      const stats = nativeMetrics.getCpuStats();
      const cores = nativeMetrics.getCoreStats();

      // Calculate load from delta (need previous sample)
      const total = stats.user + stats.nice + stats.system + stats.idle + stats.iowait;
      const busy = stats.user + stats.nice + stats.system;

      let load = 0;
      if (prevCpuTimes) {
        const deltaTotal = total - prevCpuTimes.total;
        const deltaBusy = busy - prevCpuTimes.busy;
        load = deltaTotal > 0 ? (deltaBusy / deltaTotal) * 100 : 0;
      }
      prevCpuTimes = { total, busy };

      // Per-core loads
      const loadPerCore = cores.map((c, i) => {
        const coreTotal = c.user + c.nice + c.system + c.idle + c.iowait;
        const coreBusy = c.user + c.nice + c.system;
        let coreLoad = 0;
        if (prevCoresTimes && prevCoresTimes[i]) {
          const prev = prevCoresTimes[i];
          const deltaTotal = coreTotal - prev.total;
          const deltaBusy = coreBusy - prev.busy;
          coreLoad = deltaTotal > 0 ? (deltaBusy / deltaTotal) * 100 : 0;
        }
        return { total: coreTotal, busy: coreBusy, load: coreLoad };
      });
      prevCoresTimes = loadPerCore.map(c => ({ total: c.total, busy: c.busy }));

      return { load, loadPerCore: loadPerCore.map(c => c.load) };
    } catch (e) {
      // Fall through to other methods
    }
  }

  // Linux fallback: read /proc/stat directly
  if (process.platform === 'linux') {
    const fs = require('fs');
    try {
      const stat = fs.readFileSync('/proc/stat', 'utf8');
      const lines = stat.split('\n');
      const cpus = [];
      let totalLoad = 0;

      for (const line of lines) {
        if (line.startsWith('cpu')) {
          const parts = line.split(/\s+/);
          const name = parts[0];
          const times = parts.slice(1, 8).map(Number);
          const [user, nice, system, idle, iowait, irq, softirq] = times;
          const total = user + nice + system + idle + iowait + irq + softirq;
          const busy = user + nice + system + irq + softirq;

          if (prevCpuTimes && prevCpuTimes[name]) {
            const prev = prevCpuTimes[name];
            const deltaTotal = total - prev.total;
            const deltaBusy = busy - prev.busy;
            const load = deltaTotal > 0 ? (deltaBusy / deltaTotal) * 100 : 0;

            if (name === 'cpu') {
              totalLoad = load;
            } else {
              cpus.push(load);
            }
          }

          if (!prevCpuTimes) prevCpuTimes = {};
          prevCpuTimes[name] = { total, busy };
        }
      }

      if (cpus.length > 0) {
        return { load: totalLoad, loadPerCore: cpus };
      }
    } catch (e) {}
  }

  // Fallback to systeminformation
  const cpuLoad = await si.currentLoad();
  return { load: cpuLoad.currentLoad, loadPerCore: cpuLoad.cpus.map(c => c.load) };
}

/**
 * Fast memory reading using native termweb SDK or /proc/meminfo fallback
 */
async function getFastMemory() {
  // Use native termweb SDK if available (fastest - direct Mach/proc calls)
  if (nativeMetrics) {
    try {
      const stats = nativeMetrics.getMemStats();
      return {
        total: stats.total,
        free: stats.free,
        used: stats.used,
        active: stats.used, // Use 'used' as approximation for 'active'
        available: stats.available,
        swapTotal: stats.swapTotal,
        swapUsed: stats.swapUsed
      };
    } catch (e) {
      // Fall through to other methods
    }
  }

  // Linux fallback: read /proc/meminfo directly
  if (process.platform === 'linux') {
    const fs = require('fs');
    try {
      const meminfo = fs.readFileSync('/proc/meminfo', 'utf8');
      const values = {};
      for (const line of meminfo.split('\n')) {
        const match = line.match(/^(\w+):\s+(\d+)/);
        if (match) {
          values[match[1]] = parseInt(match[2], 10) * 1024; // Convert KB to bytes
        }
      }
      return {
        total: values.MemTotal || 0,
        free: values.MemFree || 0,
        used: (values.MemTotal || 0) - (values.MemAvailable || values.MemFree || 0),
        active: values.Active || 0,
        available: values.MemAvailable || values.MemFree || 0
      };
    } catch (e) {}
  }

  // Fallback to systeminformation
  const mem = await si.mem();
  return { total: mem.total, free: mem.free, used: mem.used, active: mem.active, available: mem.available };
}

/**
 * Collect lightweight metrics for frequent updates
 * Uses native addon when available for maximum performance
 * @returns {Promise<Object>} Lightweight metrics
 */
async function collectLightMetrics() {
  const [cpu, mem, network] = await Promise.all([
    getFastCpuLoad(),
    getFastMemory(),
    getFastNetwork()
  ]);

  return {
    timestamp: Date.now(),
    cpu: {
      load: cpu.load,
      loadPerCore: cpu.loadPerCore
    },
    memory: {
      used: mem.used,
      free: mem.free,
      active: mem.active
    },
    network: network.map(n => ({
      iface: n.iface,
      rx_sec: n.rx_sec,
      tx_sec: n.tx_sec
    }))
  };
}

/**
 * Get metrics with caching - returns cached data immediately, refreshes in background
 * This prevents UI lag by never blocking on slow si.processes() calls
 * @returns {Promise<Object>} Cached or fresh metrics
 */
async function getMetricsCached() {
  const now = Date.now();

  // If we have recent cache, return it immediately
  if (metricsCache && (now - metricsCacheTime) < METRICS_CACHE_TTL) {
    return metricsCache;
  }

  // If cache is stale but we're already refreshing, return stale cache
  if (metricsCache && metricsRefreshing) {
    return metricsCache;
  }

  // If no cache at all, we must wait for first fetch
  if (!metricsCache) {
    metricsCache = await collectMetrics();
    metricsCacheTime = Date.now();
    return metricsCache;
  }

  // Cache is stale - trigger background refresh and return stale data
  metricsRefreshing = true;
  collectMetrics().then(data => {
    metricsCache = data;
    metricsCacheTime = Date.now();
    metricsRefreshing = false;
  }).catch(() => {
    metricsRefreshing = false;
  });

  return metricsCache;
}

/**
 * Start background metrics polling
 * Pre-fetches metrics so they're always cached and ready
 * @param {number} interval - Polling interval in ms (default 2000)
 */
function startBackgroundPolling(interval = 2000) {
  // Initial fetch
  collectMetrics().then(data => {
    metricsCache = data;
    metricsCacheTime = Date.now();
  }).catch(() => {});

  // Poll in background
  setInterval(async () => {
    if (!metricsRefreshing) {
      metricsRefreshing = true;
      try {
        metricsCache = await collectMetrics();
        metricsCacheTime = Date.now();
      } catch (e) {
        // Ignore errors, keep old cache
      }
      metricsRefreshing = false;
    }
  }, interval);
}

/**
 * Kill a process by PID
 * @param {number} pid - Process ID to kill
 * @returns {boolean} - true if successful
 */
function killProcess(pid) {
  try {
    process.kill(pid, 'SIGKILL');
    return true;
  } catch (e) {
    return false;
  }
}

function deleteFolder(folderPath) {
  try {
    const fs = require('fs');
    fs.rmSync(folderPath, { recursive: true, force: true });
    return true;
  } catch (e) {
    return false;
  }
}

// Cache for connections
let connectionsCache = [];
let connectionsCacheTime = 0;
const CONNECTIONS_CACHE_TTL = 2000;

// History for 1-minute aggregation: { time, hosts: Map<ip, { bytes, count }> }
const connectionHistory = [];
const CONNECTION_HISTORY_TTL = 60000; // 1 minute

// Cache for per-process bytes from nettop
let processBytes = new Map(); // pid -> { rx, tx }
let processBytesTime = 0;

// Cache for DNS reverse lookups (IP -> hostname)
const dnsCache = new Map();
const DNS_CACHE_TTL = 300000; // 5 minutes

/**
 * Get per-process network bytes using nettop (macOS only)
 * On Linux, returns empty map (falls back to proportional distribution)
 */
async function getProcessBytes() {
  // nettop is macOS only
  if (process.platform !== 'darwin') {
    return new Map();
  }

  const now = Date.now();
  if (now - processBytesTime < 2000 && processBytes.size > 0) {
    return processBytes;
  }

  return new Promise((resolve) => {
    // nettop CSV format: time,process.pid,interface,state,bytes_in,bytes_out,...
    exec('nettop -P -L 1 -n -x 2>/dev/null || true', {
      encoding: 'utf-8',
      timeout: 3000,
      maxBuffer: 1024 * 1024
    }, (err, output) => {
      if (err || !output) {
        resolve(processBytes);
        return;
      }

      const newMap = new Map();
      const lines = output.split('\n');
      for (const line of lines) {
        // Skip header line
        if (line.startsWith('time,')) continue;

        const parts = line.split(',');
        if (parts.length >= 6) {
          const procPid = parts[1]; // e.g., "Google Chrome H.947"
          const pidMatch = procPid.match(/\.(\d+)$/);
          if (pidMatch) {
            const pid = parseInt(pidMatch[1], 10);
            const rx = parseInt(parts[4], 10) || 0; // bytes_in is column 4
            const tx = parseInt(parts[5], 10) || 0; // bytes_out is column 5
            // Accumulate if process has multiple entries
            const existing = newMap.get(pid) || { rx: 0, tx: 0, total: 0 };
            existing.rx += rx;
            existing.tx += tx;
            existing.total = existing.rx + existing.tx;
            newMap.set(pid, existing);
          }
        }
      }

      if (newMap.size > 0) {
        processBytes = newMap;
        processBytesTime = now;
      }
      resolve(processBytes);
    });
  });
}

/**
 * Reverse DNS lookup with caching
 * @param {string} ip - IP address
 * @returns {Promise<string>} - Hostname or original IP if lookup fails
 */
async function reverseDns(ip) {
  // Check cache
  const cached = dnsCache.get(ip);
  if (cached && Date.now() - cached.time < DNS_CACHE_TTL) {
    return cached.hostname;
  }

  return new Promise((resolve) => {
    // Use host command for reverse lookup (faster than nslookup)
    exec(`host -W 1 ${ip} 2>/dev/null || true`, {
      encoding: 'utf-8',
      timeout: 1500
    }, (err, output) => {
      let hostname = ip; // Default to IP
      if (!err && output) {
        // Parse: "1.2.3.4.in-addr.arpa domain name pointer hostname.example.com."
        const match = output.match(/pointer\s+(.+?)\.?\s*$/m);
        if (match) {
          hostname = match[1].replace(/\.$/, ''); // Remove trailing dot
        }
      }
      dnsCache.set(ip, { hostname, time: Date.now() });
      resolve(hostname);
    });
  });
}

/**
 * Get active network connections grouped by remote host
 * Shows actual bytes transferred (from nettop) aggregated over 1 minute
 * @returns {Promise<Array>} - Array of { host, hostname, bytes, count, ports, processes }
 */
async function getConnections() {
  const now = Date.now();
  if (now - connectionsCacheTime < CONNECTIONS_CACHE_TTL && connectionsCache.length > 0) {
    return connectionsCache;
  }

  // Use netstat (fast, works on Linux and macOS) instead of lsof (slow)
  const isLinux = process.platform === 'linux';
  const netstatCmd = isLinux
    ? 'ss -tn state established 2>/dev/null || netstat -tn 2>/dev/null | grep ESTABLISHED'
    : 'netstat -an 2>/dev/null | grep ESTABLISHED';

  const [procBytes, netstatOutput] = await Promise.all([
    getProcessBytes(),
    new Promise((res) => {
      exec(netstatCmd, {
        encoding: 'utf-8',
        timeout: 2000,
        maxBuffer: 512 * 1024
      }, (err, output) => res(err ? '' : output));
    })
  ]);

  if (!netstatOutput) {
    return connectionsCache;
  }

  const hostMap = new Map();
  const lines = netstatOutput.split('\n');

  // Parse netstat output for established connections
  for (const line of lines) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 4) continue;

    let remoteAddr;
    if (isLinux) {
      // Linux ss: State Recv-Q Send-Q Local:Port Peer:Port
      // Linux netstat: Proto Recv-Q Send-Q Local Addr Foreign Addr State
      remoteAddr = parts[4] || parts[3];
    } else {
      // macOS netstat: Proto Recv-Q Send-Q Local Addr Foreign Addr (state)
      // tcp4  0  0  192.168.2.46.53397  160.79.104.10.443  ESTABLISHED
      remoteAddr = parts[4];
    }

    if (!remoteAddr) continue;

    // Parse remote address - handle both IP.port and IP:port formats
    let remoteHost, remotePort;

    // IPv6 with brackets: [::1]:443
    const ipv6Match = remoteAddr.match(/^\[([^\]]+)\][.:](\d+)$/);
    if (ipv6Match) {
      remoteHost = ipv6Match[1];
      remotePort = ipv6Match[2];
    } else {
      // macOS uses IP.port, Linux uses IP:port
      const lastDot = remoteAddr.lastIndexOf('.');
      const lastColon = remoteAddr.lastIndexOf(':');
      const sep = lastColon > lastDot ? lastColon : lastDot;
      if (sep > 0) {
        remoteHost = remoteAddr.substring(0, sep);
        remotePort = remoteAddr.substring(sep + 1);
      }
    }

    if (remoteHost && remotePort) {
      // Skip localhost and link-local
      if (remoteHost === '127.0.0.1' || remoteHost === '::1' || remoteHost === 'localhost') continue;
      if (remoteHost.startsWith('fe80:') || remoteHost.startsWith('::ffff:127.')) continue;

      const key = remoteHost;
      if (!hostMap.has(key)) {
        hostMap.set(key, { host: remoteHost, bytes: 0, count: 0, ports: new Set(), processes: new Set() });
      }
      const entry = hostMap.get(key);
      entry.count++;
      entry.ports.add(remotePort);
    }
  }

  // Note: netstat doesn't give us PID, so we can't map bytes to hosts accurately
  // Just distribute total bytes proportionally by connection count
  const totalBytes = Array.from(procBytes.values()).reduce((sum, p) => sum + p.total, 0);
  const totalConns = Array.from(hostMap.values()).reduce((sum, h) => sum + h.count, 0);
  if (totalConns > 0 && totalBytes > 0) {
    for (const entry of hostMap.values()) {
      entry.bytes = Math.floor((totalBytes * entry.count) / totalConns);
    }
  }

  // Add current sample to history
  const currentSample = new Map();
  hostMap.forEach((v, k) => currentSample.set(k, { bytes: v.bytes, count: v.count }));
  connectionHistory.push({ time: now, hosts: currentSample });

  // Remove old samples (older than 1 minute)
  while (connectionHistory.length > 0 && now - connectionHistory[0].time > CONNECTION_HISTORY_TTL) {
    connectionHistory.shift();
  }

  // Aggregate bytes over last 1 minute
  const bytesMap = new Map();
  for (const sample of connectionHistory) {
    sample.hosts.forEach((data, ip) => {
      const current = bytesMap.get(ip) || 0;
      bytesMap.set(ip, Math.max(current, data.bytes));
    });
  }

  // Build results - use cached hostname or IP
  const results = Array.from(hostMap.values())
    .map(h => ({
      host: h.host,
      hostname: dnsCache.get(h.host)?.hostname || h.host,
      bytes: bytesMap.get(h.host) || h.bytes,
      count: h.count,
      ports: Array.from(h.ports).slice(0, 5),
      processes: Array.from(h.processes).slice(0, 5)
    }))
    .sort((a, b) => b.bytes - a.bytes)
    .slice(0, 20);

  // Start DNS lookups in background (non-blocking)
  for (const r of results) {
    if (!dnsCache.has(r.host)) {
      reverseDns(r.host);
    }
  }

  connectionsCache = results;
  connectionsCacheTime = now;
  return connectionsCache;
}

// Cache for folder sizes (progressive scanning)
const folderSizeCache = new Map(); // path -> { items, scanning, lastUpdate }

/**
 * Get folder sizes for a directory (progressive scanning)
 * Returns immediately with estimates, then scans in background
 * @param {string} dir - Directory path
 * @param {function} onUpdate - Callback when data updates (for WebSocket push)
 * @returns {Promise<Array>} - Array of { name, path, size, confirmed }
 */
async function getFolderSizes(dir, onUpdate) {
  const safeDir = dir.replace(/"/g, '\\"');

  // Check cache first
  const cached = folderSizeCache.get(dir);
  if (cached && Date.now() - cached.lastUpdate < 30000) {
    return cached.items;
  }

  return new Promise((resolve) => {
    // Step 1: Quick list of folders + total used space
    exec(`ls -1 "${safeDir}" 2>/dev/null && df -k "${safeDir}" 2>/dev/null | tail -1`, {
      encoding: 'utf-8',
      timeout: 2000
    }, async (err, output) => {
      if (err) {
        resolve([]);
        return;
      }

      const lines = output.trim().split('\n');

      // Parse df output (last line): Filesystem 1K-blocks Used Available Use% Mounted
      const dfLine = lines[lines.length - 1];
      const dfParts = dfLine.split(/\s+/);
      const totalUsedKB = parseInt(dfParts[2], 10) || 0;

      // Get folder names (all lines except df output)
      const folderNames = lines.slice(0, -1).filter(n => n && !n.includes(' '));

      if (folderNames.length === 0) {
        resolve([]);
        return;
      }

      // Create initial items with estimated sizes
      const avgSize = Math.floor((totalUsedKB * 1024) / folderNames.length);
      const items = folderNames.slice(0, 30).map(name => ({
        name,
        path: dir === '/' ? `/${name}` : `${dir}/${name}`,
        size: avgSize,
        confirmed: false
      }));

      // Return estimates immediately
      folderSizeCache.set(dir, { items: [...items], scanning: true, lastUpdate: Date.now() });
      resolve(items);

      // Step 2: Scan actual sizes in parallel (multiple batches concurrently)
      const batchSize = 5;
      const maxParallel = 4; // Run up to 4 du commands in parallel
      const batches = [];
      for (let i = 0; i < items.length; i += batchSize) {
        batches.push(items.slice(i, i + batchSize));
      }

      // Process batches in parallel groups
      for (let g = 0; g < batches.length; g += maxParallel) {
        const parallelBatches = batches.slice(g, g + maxParallel);

        await Promise.all(parallelBatches.map(batch => {
          const paths = batch.map(item => `"${item.path.replace(/"/g, '\\"')}"`).join(' ');
          return new Promise((res) => {
            exec(`du -sk ${paths} 2>/dev/null || true`, {
              encoding: 'utf-8',
              timeout: 15000
            }, (err, out) => {
              if (!err && out) {
                const sizeLines = out.trim().split('\n');
                for (const line of sizeLines) {
                  const match = line.match(/^(\d+)\s+(.+)$/);
                  if (match) {
                    const sizeKB = parseInt(match[1], 10);
                    const path = match[2];
                    const item = items.find(it => it.path === path);
                    if (item) {
                      item.size = sizeKB * 1024;
                      item.confirmed = true;
                    }
                  }
                }
              }
              res();
            });
          });
        }));

        // Update cache and notify after each parallel group
        const sortedItems = [...items].sort((a, b) => b.size - a.size);
        folderSizeCache.set(dir, { items: sortedItems, scanning: g + maxParallel < batches.length, lastUpdate: Date.now() });

        if (onUpdate) {
          onUpdate(dir, sortedItems);
        }
      }

      // Final sort and cache update
      const sortedItems = [...items].sort((a, b) => b.size - a.size);
      folderSizeCache.set(dir, { items: sortedItems, scanning: false, lastUpdate: Date.now() });

      if (onUpdate) {
        onUpdate(dir, sortedItems);
      }
    });
  });
}

module.exports = {
  collectMetrics,
  collectLightMetrics,
  getMetricsCached,
  startBackgroundPolling,
  killProcess,
  deleteFolder,
  getConnections,
  getFolderSizes
};
