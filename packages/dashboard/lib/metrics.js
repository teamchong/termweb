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

module.exports = {
  collectMetrics,
  collectLightMetrics,
  getMetricsCached,
  startBackgroundPolling,
  killProcess
};
