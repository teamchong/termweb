/**
 * System metrics collector using systeminformation
 */
const si = require('systeminformation');
const { exec } = require('child_process');
const { Worker, isMainThread, parentPort } = require('worker_threads');
const path = require('path');

// Cache for port info (expensive to fetch)
let portCache = new Map();
let portCacheTime = 0;
const PORT_CACHE_TTL = 5000; // 5 seconds

// Cache for heavy metrics (collected in background)
let metricsCache = null;
let metricsCacheTime = 0;
let metricsRefreshing = false;
const METRICS_CACHE_TTL = 500; // 500ms - return cached data quickly

/**
 * Get port info for processes (cached, async)
 */
async function getPortInfo() {
  const now = Date.now();
  if (now - portCacheTime < PORT_CACHE_TTL && portCache.size > 0) {
    return portCache;
  }

  return new Promise((resolve) => {
    exec('lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null || true', {
      encoding: 'utf-8',
      timeout: 2000
    }, (err, output) => {
      if (err) {
        resolve(portCache); // Return old cache on error
        return;
      }

      portCache = new Map();
      const lines = output.split('\n').slice(1); // Skip header
      for (const line of lines) {
        const parts = line.split(/\s+/);
        if (parts.length >= 9) {
          const pid = parseInt(parts[1], 10);
          const portMatch = parts[8]?.match(/:(\d+)$/);
          if (pid && portMatch) {
            const port = portMatch[1];
            if (portCache.has(pid)) {
              portCache.get(pid).push(port);
            } else {
              portCache.set(pid, [port]);
            }
          }
        }
      }
      portCacheTime = now;
      resolve(portCache);
    });
  });
}

/**
 * Collect all system metrics
 * @returns {Promise<Object>} System metrics
 */
async function collectMetrics() {
  const [
    cpu,
    cpuLoad,
    mem,
    disk,
    networkStats,
    processes,
    temp,
    system,
    osInfo
  ] = await Promise.all([
    si.cpu(),
    si.currentLoad(),
    si.mem(),
    si.fsSize(),
    si.networkStats(),
    si.processes(),
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
      load: cpuLoad.currentLoad,
      loadPerCore: cpuLoad.cpus.map(c => c.load)
    },
    memory: {
      total: mem.total,
      used: mem.used,
      free: mem.free,
      active: mem.active,
      available: mem.available,
      swapTotal: mem.swaptotal,
      swapUsed: mem.swapused
    },
    disk: disk
      // Filter out macOS system volumes and invalid entries
      .filter(d => {
        // Skip if size is invalid
        if (!d.size || isNaN(d.size) || d.size <= 0) return false;
        // Skip macOS system volumes
        if (d.mount.startsWith('/System/Volumes/')) return false;
        // Skip snapshot/private volumes
        if (d.mount.includes('/private/var/folders/')) return false;
        // Skip tiny volumes (< 1GB)
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
      })),
    network: networkStats.map(n => ({
      iface: n.iface,
      rx_bytes: n.rx_bytes,
      tx_bytes: n.tx_bytes,
      rx_sec: n.rx_sec,
      tx_sec: n.tx_sec
    })),
    processes: await (async () => {
      const ports = await getPortInfo();
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
    })(),
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

/**
 * Collect lightweight metrics for frequent updates
 * @returns {Promise<Object>} Lightweight metrics
 */
async function collectLightMetrics() {
  const [cpuLoad, mem, networkStats] = await Promise.all([
    si.currentLoad(),
    si.mem(),
    si.networkStats()
  ]);

  return {
    timestamp: Date.now(),
    cpu: {
      load: cpuLoad.currentLoad,
      loadPerCore: cpuLoad.cpus.map(c => c.load)
    },
    memory: {
      used: mem.used,
      free: mem.free,
      active: mem.active
    },
    network: networkStats.map(n => ({
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
 * Get per-process network bytes using nettop (macOS)
 */
async function getProcessBytes() {
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

  // Get per-process bytes first
  const procBytes = await getProcessBytes();

  return new Promise((resolve) => {
    // Use lsof to get TCP connections with PID
    exec('lsof -i -n -P 2>/dev/null | grep -E "TCP|UDP" || true', {
      encoding: 'utf-8',
      timeout: 3000,
      maxBuffer: 1024 * 1024
    }, async (err, output) => {
      if (err) {
        resolve(connectionsCache);
        return;
      }

      const hostMap = new Map();
      const pidConnections = new Map(); // pid -> array of { host, port }
      const lines = output.split('\n');

      // First pass: collect all connections
      for (const line of lines) {
        // Parse lsof output: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        const parts = line.trim().split(/\s+/);
        if (parts.length < 9) continue;

        const process = parts[0];
        const pid = parseInt(parts[1], 10);
        const name = parts[parts.length - 1]; // Last column is NAME (connection info)

        // Parse connection: local->remote or *:port (LISTEN)
        const match = name.match(/->([^:]+):(\d+)/);
        if (match) {
          const remoteHost = match[1];
          const remotePort = match[2];

          // Skip localhost
          if (remoteHost === '127.0.0.1' || remoteHost === '::1' || remoteHost === 'localhost') continue;

          // Track per-host
          const key = remoteHost;
          if (!hostMap.has(key)) {
            hostMap.set(key, { host: remoteHost, bytes: 0, count: 0, ports: new Set(), processes: new Set() });
          }
          const entry = hostMap.get(key);
          entry.count++;
          entry.ports.add(remotePort);
          entry.processes.add(process);

          // Track per-pid connections
          if (!pidConnections.has(pid)) {
            pidConnections.set(pid, []);
          }
          pidConnections.get(pid).push(remoteHost);
        }
      }

      // Second pass: distribute process bytes proportionally among hosts
      for (const [pid, hosts] of pidConnections) {
        const pb = procBytes.get(pid);
        if (!pb || pb.total === 0) continue;

        // Count connections per host for this pid
        const hostCounts = new Map();
        for (const host of hosts) {
          hostCounts.set(host, (hostCounts.get(host) || 0) + 1);
        }

        // Distribute bytes proportionally
        const totalConns = hosts.length;
        for (const [host, count] of hostCounts) {
          const share = Math.floor((pb.total * count) / totalConns);
          const entry = hostMap.get(host);
          if (entry) {
            entry.bytes += share;
          }
        }
      }

      // Add current sample to history (with bytes)
      const currentSample = new Map();
      hostMap.forEach((v, k) => currentSample.set(k, { bytes: v.bytes, count: v.count }));
      connectionHistory.push({ time: now, hosts: currentSample });

      // Remove old samples (older than 1 minute)
      while (connectionHistory.length > 0 && now - connectionHistory[0].time > CONNECTION_HISTORY_TTL) {
        connectionHistory.shift();
      }

      // Aggregate bytes over last 1 minute (use max seen, not sum, since bytes are cumulative)
      const bytesMap = new Map();
      for (const sample of connectionHistory) {
        sample.hosts.forEach((data, ip) => {
          const current = bytesMap.get(ip) || 0;
          bytesMap.set(ip, Math.max(current, data.bytes));
        });
      }

      // Merge with current hostMap data
      const results = Array.from(hostMap.values())
        .map(h => ({
          host: h.host,
          bytes: bytesMap.get(h.host) || h.bytes,
          count: h.count,
          ports: Array.from(h.ports).slice(0, 5),
          processes: Array.from(h.processes).slice(0, 5)
        }))
        .sort((a, b) => b.bytes - a.bytes)
        .slice(0, 20);

      // Resolve hostnames in parallel (cached)
      await Promise.all(results.map(async (r) => {
        r.hostname = await reverseDns(r.host);
      }));

      connectionsCache = results;
      connectionsCacheTime = now;
      resolve(connectionsCache);
    });
  });
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

      // Step 2: Scan actual sizes in background (batch of 5 at a time)
      const batchSize = 5;
      for (let i = 0; i < items.length; i += batchSize) {
        const batch = items.slice(i, i + batchSize);
        const paths = batch.map(item => `"${item.path.replace(/"/g, '\\"')}"`).join(' ');

        try {
          const result = await new Promise((res) => {
            exec(`du -sk ${paths} 2>/dev/null || true`, {
              encoding: 'utf-8',
              timeout: 15000
            }, (err, out) => res(err ? '' : out));
          });

          // Parse results and update items
          const sizeLines = result.trim().split('\n');
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

          // Update cache and notify
          const sortedItems = [...items].sort((a, b) => b.size - a.size);
          folderSizeCache.set(dir, { items: sortedItems, scanning: i + batchSize < items.length, lastUpdate: Date.now() });

          if (onUpdate) {
            onUpdate(dir, sortedItems);
          }
        } catch (e) {
          // Continue with next batch
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
  getConnections,
  getFolderSizes
};
