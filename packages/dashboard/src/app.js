import { Chart, registerables } from 'chart.js';

Chart.register(...registerables);

// State
let cpuChart, memChart, netChart;
let currentView = 'main'; // 'main' or 'processes'
let processList = [];
let selectedProcessIndex = 0;
let sortColumn = 'cpu'; // 'pid', 'name', 'cpu', 'mem', 'port'
let sortAsc = false;
let filterText = '';
let isFiltering = false;

const SORT_COLUMNS = ['pid', 'name', 'cpu', 'mem', 'port'];

// Global key binding handlers called by termweb
window.__termwebView = function(view) {
  // c,m,n,d,p only work on main view
  if (currentView !== 'main') return;
  currentView = view;
  selectedProcessIndex = 0;
  isFiltering = false;
  renderCurrentView();
};

window.__termwebFilter = function() {
  // f only works on main or processes view
  if (currentView !== 'main' && currentView !== 'processes') return;
  if (currentView === 'main') {
    currentView = 'processes';
  }
  selectedProcessIndex = 0;
  isFiltering = true;
  renderCurrentView();
};

window.__termwebEsc = function() {
  // Esc only works on detail pages (not main)
  if (currentView === 'main') return;
  if (isFiltering) {
    isFiltering = false;
    renderCurrentView();
  } else {
    hideDetailView();
  }
};

function renderCurrentView() {
  document.getElementById('main-dashboard').style.display = currentView === 'main' ? 'block' : 'none';
  document.getElementById('process-fullscreen').style.display = currentView === 'processes' ? 'flex' : 'none';
  document.getElementById('detail-fullscreen').style.display = ['cpu', 'memory', 'network', 'disk'].includes(currentView) ? 'flex' : 'none';

  if (currentView === 'processes') {
    renderProcessView();
  } else if (['cpu', 'memory', 'network', 'disk'].includes(currentView)) {
    renderDetailView(currentView);
  }
  updateHints();
}

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

// Sort and filter processes
function getFilteredProcesses() {
  let list = [...processList];

  // Filter
  if (filterText) {
    const lower = filterText.toLowerCase();
    list = list.filter(p =>
      p.name.toLowerCase().includes(lower) ||
      p.pid.toString().includes(lower) ||
      (p.ports && p.ports.some(port => port.includes(lower)))
    );
  }

  // Sort
  list.sort((a, b) => {
    let cmp = 0;
    switch (sortColumn) {
      case 'pid': cmp = a.pid - b.pid; break;
      case 'name': cmp = a.name.localeCompare(b.name); break;
      case 'cpu': cmp = a.cpu - b.cpu; break;
      case 'mem': cmp = a.mem - b.mem; break;
      case 'port':
        const aPort = a.ports?.[0] || '';
        const bPort = b.ports?.[0] || '';
        cmp = aPort.localeCompare(bPort);
        break;
    }
    return sortAsc ? cmp : -cmp;
  });

  return list;
}

// Render full screen process view
function renderProcessView() {
  const filtered = getFilteredProcesses();
  const container = document.getElementById('process-fullscreen');

  // Ensure selection is valid
  if (selectedProcessIndex >= filtered.length) {
    selectedProcessIndex = Math.max(0, filtered.length - 1);
  }

  const headerRow = SORT_COLUMNS.map(col => {
    const arrow = sortColumn === col ? (sortAsc ? '▲' : '▼') : '';
    const label = col.toUpperCase();
    return `<th class="${sortColumn === col ? 'sorted' : ''}">${label} ${arrow}</th>`;
  }).join('') + '<th>STATE</th><th>USER</th>';

  const rows = filtered.map((p, i) => {
    const selected = i === selectedProcessIndex;
    const ports = p.ports?.join(', ') || '-';
    return `
      <tr class="${selected ? 'selected' : ''}">
        <td>${p.pid}</td>
        <td>${p.name}</td>
        <td class="${getLoadClass(p.cpu)}">${p.cpu.toFixed(1)}%</td>
        <td>${p.mem.toFixed(1)}%</td>
        <td>${ports}</td>
        <td>${p.state}</td>
        <td>${p.user}</td>
      </tr>
    `;
  }).join('');

  container.innerHTML = `
    <div class="process-header">
      <h2>Processes${filterText ? ` (filter: "${filterText}")` : ''}</h2>
      ${isFiltering ? `<input type="text" id="filter-input" value="${filterText}" placeholder="Filter by name or port..." autofocus>` : ''}
    </div>
    <div class="process-table-wrap">
      <table class="process-table">
        <thead><tr>${headerRow}</tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
  `;

  if (isFiltering) {
    const input = document.getElementById('filter-input');
    input.focus();
    input.selectionStart = input.selectionEnd = input.value.length;
  }

  container.style.display = 'flex';
  document.getElementById('main-dashboard').style.display = 'none';
  updateHints();
}

// Render detail view for cpu, memory, network, disk
function renderDetailView(type) {
  const container = document.getElementById('detail-fullscreen');
  const titles = { cpu: 'CPU Details', memory: 'Memory Details', network: 'Network Details', disk: 'Disk Details' };

  let content = '';
  if (type === 'cpu') {
    content = `
      <div class="detail-chart"><canvas id="detail-cpu-chart"></canvas></div>
      <div id="detail-cpu-info"></div>
      <div id="detail-cpu-cores" class="core-grid"></div>
    `;
  } else if (type === 'memory') {
    content = `
      <div class="detail-chart"><canvas id="detail-mem-chart"></canvas></div>
      <div id="detail-mem-info"></div>
    `;
  } else if (type === 'network') {
    content = `
      <div class="detail-chart"><canvas id="detail-net-chart"></canvas></div>
      <div id="detail-net-info"></div>
    `;
  } else if (type === 'disk') {
    content = '<div id="detail-disk-info"></div>';
  }

  container.innerHTML = `
    <div class="detail-header">
      <h2>${titles[type]}</h2>
    </div>
    <div class="detail-content">${content}</div>
  `;
}

// Hide any detail view and go back to main
function hideDetailView() {
  document.getElementById('process-fullscreen').style.display = 'none';
  document.getElementById('detail-fullscreen').style.display = 'none';
  document.getElementById('main-dashboard').style.display = 'block';
  currentView = 'main';
  isFiltering = false;
  updateHints();
}

// Update bottom hints based on current view
function updateHints() {
  const hints = document.getElementById('hints');
  if (currentView === 'main') {
    hints.innerHTML = '<span>c: CPU</span><span>m: Memory</span><span>n: Network</span><span>d: Disk</span><span>p: Processes</span><span>Ctrl+Q: Quit</span>';
  } else if (currentView === 'processes' && isFiltering) {
    hints.innerHTML = '<span>Type to filter</span><span>Enter: Apply</span><span>Esc: Cancel</span>';
  } else if (currentView === 'processes') {
    hints.innerHTML = `
      <span>←→: Sort (${sortColumn})</span>
      <span>↑↓: Select</span>
      <span>f: Filter</span>
      <span>Ctrl+K: Kill</span>
      <span>Esc: Back</span>
    `;
  } else {
    hints.innerHTML = '<span>Esc: Back</span>';
  }
}

function updateUI(data, isFull) {
  if (currentView === 'main') {
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

    // Processes (mini view)
    if (isFull && data.processes) {
      document.getElementById('process-tbody').innerHTML = data.processes.list.slice(0, 10).map(p => `
        <tr>
          <td>${p.pid}</td>
          <td>${p.name}</td>
          <td class="${getLoadClass(p.cpu)}">${p.cpu.toFixed(1)}%</td>
          <td>${p.mem.toFixed(1)}%</td>
          <td>${p.ports?.join(', ') || '-'}</td>
        </tr>
      `).join('');
    }

    // System info
    if (isFull && data.system && data.os) {
      document.getElementById('system-info').textContent =
        `${data.os.hostname} | ${data.os.distro} ${data.os.release} | Up: ${Math.floor(data.os.uptime / 3600)}h`;
    }
  }

  // Always update process list for full screen view
  if (isFull && data.processes) {
    processList = data.processes.list;
    if (currentView === 'processes') {
      renderProcessView();
    }
  }
}

// IPC for metrics
const pendingMetrics = new Map();
const pendingKills = new Map();
let ipcId = 0;

window.__termwebMetricsResponse = (id, data) => {
  const resolve = pendingMetrics.get(id);
  if (resolve) {
    pendingMetrics.delete(id);
    resolve(data);
  }
};

window.__termwebKillResponse = (id, success) => {
  const resolve = pendingKills.get(id);
  if (resolve) {
    pendingKills.delete(id);
    resolve(success);
  }
};

function requestMetrics(type) {
  return new Promise(resolve => {
    const id = ++ipcId;
    pendingMetrics.set(id, resolve);
    console.log(`__TERMWEB_IPC__:${id}:${type}`);
    setTimeout(() => {
      if (pendingMetrics.has(id)) {
        pendingMetrics.delete(id);
        resolve(null);
      }
    }, 5000);
  });
}

function killProcess(pid) {
  return new Promise(resolve => {
    const id = ++ipcId;
    pendingKills.set(id, resolve);
    console.log(`__TERMWEB_IPC__:${id}:kill:${pid}`);
    setTimeout(() => {
      if (pendingKills.has(id)) {
        pendingKills.delete(id);
        resolve(false);
      }
    }, 5000);
  });
}

// Keyboard handling - use window with capture to ensure we get all keys
window.addEventListener('keydown', async (e) => {
  // Log via IPC so it shows in terminal with --verbose
  console.log(`__TERMWEB_IPC__:0:keypress:${e.key}:${currentView}`);
  if (currentView === 'processes') {
    if (isFiltering) {
      if (e.key === 'Escape') {
        isFiltering = false;
        renderProcessView();
      } else if (e.key === 'Enter') {
        isFiltering = false;
        renderProcessView();
      }
      return;
    }

    const filtered = getFilteredProcesses();

    if (e.key === 'Escape') {
      hideDetailView();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      selectedProcessIndex = Math.max(0, selectedProcessIndex - 1);
      renderProcessView();
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      selectedProcessIndex = Math.min(filtered.length - 1, selectedProcessIndex + 1);
      renderProcessView();
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault();
      const idx = SORT_COLUMNS.indexOf(sortColumn);
      sortColumn = SORT_COLUMNS[(idx - 1 + SORT_COLUMNS.length) % SORT_COLUMNS.length];
      renderProcessView();
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      const idx = SORT_COLUMNS.indexOf(sortColumn);
      sortColumn = SORT_COLUMNS[(idx + 1) % SORT_COLUMNS.length];
      renderProcessView();
    } else if (e.key === '/' || e.key === 'f') {
      e.preventDefault();
      isFiltering = true;
      renderProcessView();
    } else if (e.key === 'k' && e.ctrlKey) {
      e.preventDefault();
      if (filtered[selectedProcessIndex]) {
        const pid = filtered[selectedProcessIndex].pid;
        await killProcess(pid);
        // Refresh immediately
        const data = await requestMetrics('full');
        if (data) updateUI(data, true);
      }
    }
  } else if (['cpu', 'memory', 'network', 'disk'].includes(currentView)) {
    // Detail view - Escape goes back
    if (e.key === 'Escape') {
      hideDetailView();
    }
  }
});

// Filter input handling
document.addEventListener('input', (e) => {
  if (e.target.id === 'filter-input') {
    filterText = e.target.value;
    selectedProcessIndex = 0;
  }
});

// Initialize on load
document.addEventListener('DOMContentLoaded', async () => {
  // Focus body to receive keyboard events
  document.body.focus();

  initCharts();

  // Make cards clickable
  document.getElementById('cpu-card').addEventListener('click', () => {
    window.__termwebView('cpu');
  });
  document.getElementById('memory-card').addEventListener('click', () => {
    window.__termwebView('memory');
  });
  document.getElementById('network-card').addEventListener('click', () => {
    window.__termwebView('network');
  });
  document.getElementById('disk-card').addEventListener('click', () => {
    window.__termwebView('disk');
  });
  document.getElementById('processes').addEventListener('click', () => {
    window.__termwebView('processes');
  });

  // Initial full metrics
  const initial = await requestMetrics('full');
  if (initial) {
    updateUI(initial, true);
  }

  updateHints();

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
