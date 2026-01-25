/**
 * System metrics collector using systeminformation
 */
const si = require('systeminformation');

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
    processes: {
      all: processes.all,
      running: processes.running,
      blocked: processes.blocked,
      sleeping: processes.sleeping,
      list: processes.list
        .sort((a, b) => b.cpu - a.cpu)
        .slice(0, 20)
        .map(p => ({
          pid: p.pid,
          name: p.name,
          cpu: p.cpu,
          mem: p.mem,
          state: p.state,
          user: p.user
        }))
    },
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

module.exports = {
  collectMetrics,
  collectLightMetrics
};
