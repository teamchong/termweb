import { Chart, registerables } from 'chart.js';

Chart.register(...registerables);

// Initialize charts
let cpuChart, memChart, netChart;

function initCharts() {
  const chartOptions = {
    responsive: true,
    maintainAspectRatio: false,
    animation: { duration: 0 },
    plugins: { legend: { display: false } },
    scales: {
      x: { display: false },
      y: {
        display: true,
        min: 0,
        max: 100,
        grid: { color: 'rgba(60, 60, 60, 0.5)' },
        ticks: { color: '#888', font: { size: 10 } }
      }
    }
  };

  const createData = (label, color) => ({
    labels: Array(60).fill(''),
    datasets: [{
      label,
      data: Array(60).fill(0),
      borderColor: color,
      backgroundColor: color.replace(')', ', 0.15)').replace('rgb', 'rgba'),
      fill: true,
      tension: 0.3,
      pointRadius: 0,
      borderWidth: 2
    }]
  });

  cpuChart = new Chart(document.getElementById('cpu-chart'), {
    type: 'line',
    data: createData('CPU', 'rgb(86, 156, 214)'),
    options: chartOptions
  });

  memChart = new Chart(document.getElementById('mem-chart'), {
    type: 'line',
    data: createData('Memory', 'rgb(78, 201, 176)'),
    options: chartOptions
  });

  netChart = new Chart(document.getElementById('net-chart'), {
    type: 'line',
    data: {
      labels: Array(60).fill(''),
      datasets: [
        {
          label: 'Download',
          data: Array(60).fill(0),
          borderColor: 'rgb(106, 153, 85)',
          backgroundColor: 'rgba(106, 153, 85, 0.1)',
          fill: true,
          tension: 0.3,
          pointRadius: 0,
          borderWidth: 2
        },
        {
          label: 'Upload',
          data: Array(60).fill(0),
          borderColor: 'rgb(206, 145, 120)',
          backgroundColor: 'rgba(206, 145, 120, 0.1)',
          fill: true,
          tension: 0.3,
          pointRadius: 0,
          borderWidth: 2
        }
      ]
    },
    options: {
      ...chartOptions,
      scales: {
        ...chartOptions.scales,
        y: {
          ...chartOptions.scales.y,
          max: undefined,
          suggestedMax: 1000000
        }
      }
    }
  });
}

function pushChartData(chart, value) {
  const data = chart.data.datasets[0].data;
  data.push(value);
  data.shift();
  chart.update('none');
}

function formatBytes(bytes) {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

function formatBps(bytes) {
  return formatBytes(bytes) + '/s';
}

function getLoadClass(load) {
  if (load > 80) return 'high';
  if (load > 50) return 'medium';
  return 'low';
}

function updateUI(data, isFull) {
  // CPU
  pushChartData(cpuChart, data.cpu.load);
  document.getElementById('cpu-bar').style.width = data.cpu.load.toFixed(1) + '%';

  if (isFull && data.cpu.brand) {
    document.getElementById('cpu-info').innerHTML = `
      <div class="stat-row">
        <span class="stat-label">Model</span>
        <span class="stat-value">${data.cpu.brand}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">Cores</span>
        <span class="stat-value">${data.cpu.cores} (${data.cpu.physicalCores} physical)</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">Load</span>
        <span class="stat-value ${getLoadClass(data.cpu.load)}">${data.cpu.load.toFixed(1)}%</span>
      </div>
    `;
  }

  if (data.cpu.loadPerCore) {
    document.getElementById('cpu-cores').innerHTML = data.cpu.loadPerCore.map((load, i) => `
      <div class="core-item">
        <div class="label">Core ${i}</div>
        <div class="value ${getLoadClass(load)}">${load.toFixed(0)}%</div>
      </div>
    `).join('');
  }

  // Memory
  const memPercent = (data.memory.used / (isFull ? data.memory.total : (data.memory.used + data.memory.free))) * 100;
  pushChartData(memChart, memPercent);
  document.getElementById('mem-bar').style.width = memPercent.toFixed(1) + '%';

  if (isFull) {
    document.getElementById('mem-info').innerHTML = `
      <div class="stat-row">
        <span class="stat-label">Used</span>
        <span class="stat-value">${formatBytes(data.memory.used)} / ${formatBytes(data.memory.total)}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">Available</span>
        <span class="stat-value">${formatBytes(data.memory.available)}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">Swap</span>
        <span class="stat-value">${formatBytes(data.memory.swapUsed)} / ${formatBytes(data.memory.swapTotal)}</span>
      </div>
    `;
  }

  // Network
  const netRx = data.network.reduce((sum, n) => sum + (n.rx_sec || 0), 0);
  const netTx = data.network.reduce((sum, n) => sum + (n.tx_sec || 0), 0);

  netChart.data.datasets[0].data.push(netRx);
  netChart.data.datasets[0].data.shift();
  netChart.data.datasets[1].data.push(netTx);
  netChart.data.datasets[1].data.shift();
  netChart.update('none');

  document.getElementById('net-info').innerHTML = `
    <div class="stat-row">
      <span class="stat-label">Download</span>
      <span class="stat-value">${formatBps(netRx)}</span>
    </div>
    <div class="stat-row">
      <span class="stat-label">Upload</span>
      <span class="stat-value">${formatBps(netTx)}</span>
    </div>
  `;

  // Disk
  if (isFull && data.disk) {
    document.getElementById('disk-info').innerHTML = data.disk.map(d => `
      <div class="stat-row">
        <span class="stat-label">${d.mount}</span>
        <span class="stat-value ${getLoadClass(d.usePercent)}">${d.usePercent.toFixed(0)}% used</span>
      </div>
      <div class="progress-bar">
        <div class="progress-fill disk" style="width: ${d.usePercent}%"></div>
      </div>
      <div style="font-size: 11px; color: #888; margin-top: 4px; margin-bottom: 8px;">
        ${formatBytes(d.used)} used of ${formatBytes(d.size)} (${formatBytes(d.available)} free)
      </div>
    `).join('');
  }

  // Processes
  if (isFull && data.processes) {
    document.getElementById('process-tbody').innerHTML = data.processes.list.map(p => `
      <tr>
        <td>${p.pid}</td>
        <td>${p.name}</td>
        <td class="${getLoadClass(p.cpu)}">${p.cpu.toFixed(1)}%</td>
        <td>${p.mem.toFixed(1)}%</td>
        <td>${p.state}</td>
        <td>${p.user}</td>
      </tr>
    `).join('');
  }

  // System info
  if (isFull && data.system && data.os) {
    document.getElementById('system-info').textContent =
      `${data.os.hostname} | ${data.os.distro} ${data.os.release} | Up: ${Math.floor(data.os.uptime / 3600)}h`;
  }
}

// IPC for metrics using __TERMWEB_IPC__ protocol
const pendingMetrics = new Map();
let metricsId = 0;

window.__termwebMetricsResponse = (id, data) => {
  const resolve = pendingMetrics.get(id);
  if (resolve) {
    pendingMetrics.delete(id);
    resolve(data);
  }
};

function requestMetrics(type) {
  return new Promise(resolve => {
    const id = ++metricsId;
    pendingMetrics.set(id, resolve);
    // Send IPC message: __TERMWEB_IPC__:id:type
    console.log(`__TERMWEB_IPC__:${id}:${type}`);
    setTimeout(() => {
      if (pendingMetrics.has(id)) {
        pendingMetrics.delete(id);
        resolve(null);
      }
    }, 5000);
  });
}

// Initialize on load
document.addEventListener('DOMContentLoaded', async () => {
  initCharts();

  // Initial full metrics
  const initial = await requestMetrics('full');
  if (initial) {
    updateUI(initial, true);
  }

  // Poll for updates every second
  setInterval(async () => {
    const data = await requestMetrics('light');
    if (data) {
      updateUI(data, false);
    }
  }, 1000);

  // Full update every 30 seconds
  setInterval(async () => {
    const data = await requestMetrics('full');
    if (data) {
      updateUI(data, true);
    }
  }, 30000);
});
