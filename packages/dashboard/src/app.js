import { Chart, registerables } from 'chart.js';

Chart.register(...registerables);

// SDK IPC receiver - termweb.sendToPage() calls this
window.__termweb = {
  _callbacks: [],
  _receive: function(msgJson) {
    try {
      const msg = typeof msgJson === 'string' ? JSON.parse(msgJson) : msgJson;
      this._callbacks.forEach(cb => cb(msg));
    } catch (e) {
      // Invalid message
    }
  },
  onMessage: function(cb) {
    this._callbacks.push(cb);
  }
};

// State
let cpuChart, memChart, netChart;
let detailChart = null; // Chart for detail views
let currentView = 'main'; // 'main', 'processes', 'cpu', 'memory', 'network', 'disk'
let processList = [];
let selectedProcessIndex = 0;
let sortColumn = 'cpu'; // 'pid', 'name', 'cpu', 'mem', 'port'
let sortAsc = false;
let filterText = '';
let isFiltering = false;
let detailLoading = false; // Loading state for detail views
let lastDetailData = null; // Cache last data for detail views

// Smoothed values for stable sorting (prevents jumping)
const smoothedValues = new Map(); // pid -> { cpu, mem }
const SMOOTH_FACTOR = 0.3; // Lower = more stable, higher = more responsive

const SORT_COLUMNS = ['pid', 'name', 'cpu', 'mem', 'port'];

// Update smoothed values for a process
function updateSmoothedValues(process) {
  const pid = process.pid;
  const prev = smoothedValues.get(pid) || { cpu: process.cpu, mem: process.mem };

  // Exponential moving average
  const smoothed = {
    cpu: prev.cpu * (1 - SMOOTH_FACTOR) + process.cpu * SMOOTH_FACTOR,
    mem: prev.mem * (1 - SMOOTH_FACTOR) + process.mem * SMOOTH_FACTOR,
  };

  smoothedValues.set(pid, smoothed);
  return smoothed;
}

// Get smoothed value for sorting
function getSmoothedValue(process, field) {
  const smoothed = smoothedValues.get(process.pid);
  if (!smoothed) return process[field];
  return smoothed[field] || process[field];
}

// Clean up smoothed values for dead processes
function cleanupSmoothedValues(activePids) {
  const activeSet = new Set(activePids);
  for (const pid of smoothedValues.keys()) {
    if (!activeSet.has(pid)) {
      smoothedValues.delete(pid);
    }
  }
}

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

async function renderCurrentView() {
  document.getElementById('main-dashboard').style.display = currentView === 'main' ? 'block' : 'none';
  document.getElementById('process-fullscreen').style.display = currentView === 'processes' ? 'flex' : 'none';
  document.getElementById('detail-fullscreen').style.display = ['cpu', 'memory', 'network', 'disk'].includes(currentView) ? 'flex' : 'none';

  if (currentView === 'processes') {
    renderProcessView();
  } else if (['cpu', 'memory', 'network', 'disk'].includes(currentView)) {
    // Show spinner and fetch data async
    detailLoading = true;
    renderDetailView(currentView);
    const data = await requestMetrics('full');
    detailLoading = false;
    if (data && ['cpu', 'memory', 'network', 'disk'].includes(currentView)) {
      lastDetailData = data;
      updateDetailView(currentView, data);
    }
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

  // Sort using smoothed values for cpu/mem to prevent jumping
  list.sort((a, b) => {
    let cmp = 0;
    switch (sortColumn) {
      case 'pid': cmp = a.pid - b.pid; break;
      case 'name': cmp = a.name.localeCompare(b.name); break;
      case 'cpu':
        // Use smoothed CPU for stable sorting
        cmp = getSmoothedValue(a, 'cpu') - getSmoothedValue(b, 'cpu');
        break;
      case 'mem':
        // Use smoothed memory for stable sorting
        cmp = getSmoothedValue(a, 'mem') - getSmoothedValue(b, 'mem');
        break;
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

// Fast selection update - works with CSS-ordered rows
function updateSelectionFast(oldIndex, newIndex) {
  const tbody = document.querySelector('.process-table tbody');
  if (!tbody) return false;

  const filtered = getFilteredProcesses();
  if (newIndex < 0 || newIndex >= filtered.length) return false;

  // Find rows by PID (since visual order is via CSS)
  const oldPid = filtered[oldIndex]?.pid;
  const newPid = filtered[newIndex]?.pid;

  if (oldPid !== undefined) {
    const oldRow = tbody.querySelector(`tr[data-pid="${oldPid}"]`);
    if (oldRow) oldRow.classList.remove('selected');
  }
  if (newPid !== undefined) {
    const newRow = tbody.querySelector(`tr[data-pid="${newPid}"]`);
    if (newRow) {
      newRow.classList.add('selected');
      newRow.scrollIntoView({ block: 'nearest' });
      return true;
    }
  }
  return false;
}

// Build table rows HTML from filtered process list (with data-pid for CSS order)
function buildTableRows(filtered) {
  return filtered.map((p, i) => {
    const selected = i === selectedProcessIndex;
    const ports = p.ports?.join(', ') || '-';
    return `<tr data-pid="${p.pid}" style="order: ${i}" class="${selected ? 'selected' : ''}">
      <td>${p.pid}</td>
      <td>${p.name}</td>
      <td class="${getLoadClass(p.cpu)}">${p.cpu.toFixed(1)}%</td>
      <td>${p.mem.toFixed(1)}%</td>
      <td>${ports}</td>
      <td>${p.state}</td>
      <td>${p.user}</td>
    </tr>`;
  }).join('');
}

// Apply sort order via CSS (no DOM rebuild)
function applySortOrder() {
  const tbody = document.querySelector('.process-table tbody');
  if (!tbody) return false;

  const filtered = getFilteredProcesses();
  const rows = tbody.querySelectorAll('tr');

  // Build pid -> new order map
  const orderMap = new Map();
  filtered.forEach((p, i) => orderMap.set(p.pid, i));

  // Apply CSS order to each row
  rows.forEach(row => {
    const pid = parseInt(row.dataset.pid, 10);
    const order = orderMap.get(pid);
    if (order !== undefined) {
      row.style.order = order;
      row.style.display = '';
    } else {
      // Hide rows not in filtered list
      row.style.display = 'none';
    }
  });

  // Update selection
  rows.forEach(row => row.classList.remove('selected'));
  if (filtered[selectedProcessIndex]) {
    const selectedPid = filtered[selectedProcessIndex].pid;
    const selectedRow = tbody.querySelector(`tr[data-pid="${selectedPid}"]`);
    if (selectedRow) {
      selectedRow.classList.add('selected');
      selectedRow.scrollIntoView({ block: 'nearest' });
    }
  }

  return true;
}

// Build table header HTML
function buildTableHeader() {
  return SORT_COLUMNS.map(col => {
    const arrow = sortColumn === col ? (sortAsc ? '▲' : '▼') : '';
    return `<th class="${sortColumn === col ? 'sorted' : ''}">${col.toUpperCase()} ${arrow}</th>`;
  }).join('') + '<th>STATE</th><th>USER</th>';
}

// Update table in place (fast path - no container rebuild)
function updateTable() {
  const thead = document.querySelector('.process-table thead tr');
  const tbody = document.querySelector('.process-table tbody');
  if (!thead || !tbody) return false;

  const filtered = getFilteredProcesses();
  if (selectedProcessIndex >= filtered.length) {
    selectedProcessIndex = Math.max(0, filtered.length - 1);
  }

  thead.innerHTML = buildTableHeader();
  tbody.innerHTML = buildTableRows(filtered);
  return true;
}

// Render full screen process view (full rebuild)
function renderProcessView() {
  const filtered = getFilteredProcesses();
  const container = document.getElementById('process-fullscreen');

  if (selectedProcessIndex >= filtered.length) {
    selectedProcessIndex = Math.max(0, filtered.length - 1);
  }

  container.innerHTML = `
    <div class="process-header">
      <h2>Processes${filterText ? ` (filter: "${filterText}")` : ''}</h2>
      ${isFiltering ? `<input type="text" id="filter-input" value="${filterText}" placeholder="Filter by name or port..." autofocus>` : ''}
    </div>
    <div class="process-table-wrap">
      <table class="process-table">
        <thead><tr>${buildTableHeader()}</tr></thead>
        <tbody>${buildTableRows(filtered)}</tbody>
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

  // Show spinner while loading
  const spinner = detailLoading ? '<div class="spinner">Loading...</div>' : '';

  let content = '';
  if (type === 'cpu') {
    content = `
      <div class="detail-chart"><canvas id="detail-cpu-chart"></canvas></div>
      <div id="detail-cpu-info">${spinner}</div>
      <div id="detail-cpu-cores" class="core-grid"></div>
    `;
  } else if (type === 'memory') {
    content = `
      <div class="detail-chart"><canvas id="detail-mem-chart"></canvas></div>
      <div id="detail-mem-info">${spinner}</div>
    `;
  } else if (type === 'network') {
    content = `
      <div class="detail-chart"><canvas id="detail-net-chart"></canvas></div>
      <div id="detail-net-info">${spinner}</div>
    `;
  } else if (type === 'disk') {
    content = `<div id="detail-disk-info">${spinner}</div>`;
  }

  container.innerHTML = `
    <div class="detail-header">
      <h2>${titles[type]}</h2>
    </div>
    <div class="detail-content">${content}</div>
  `;
}

// Update detail view with data
function updateDetailView(type, data) {
  if (type === 'cpu' && data.cpu) {
    const info = document.getElementById('detail-cpu-info');
    const cores = document.getElementById('detail-cpu-cores');
    if (info) {
      info.innerHTML = `
        <div class="stat-row">
          <span class="stat-label">Model</span>
          <span class="stat-value">${data.cpu.brand || 'Unknown'}</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Cores</span>
          <span class="stat-value">${data.cpu.cores} (${data.cpu.physicalCores} physical)</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Speed</span>
          <span class="stat-value">${data.cpu.speed ? data.cpu.speed.toFixed(2) + ' GHz' : 'N/A'}</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Load</span>
          <span class="stat-value ${getLoadClass(data.cpu.load)}">${data.cpu.load.toFixed(1)}%</span>
        </div>
      `;
    }
    if (cores && data.cpu.loadPerCore) {
      cores.innerHTML = data.cpu.loadPerCore.map((load, i) => `
        <div class="core-item">
          <div class="label">Core ${i}</div>
          <div class="value ${getLoadClass(load)}">${load.toFixed(0)}%</div>
        </div>
      `).join('');
    }
  } else if (type === 'memory' && data.memory) {
    const info = document.getElementById('detail-mem-info');
    if (info) {
      const mem = data.memory;
      info.innerHTML = `
        <div class="stat-row">
          <span class="stat-label">Total</span>
          <span class="stat-value">${formatBytes(mem.total)}</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Used</span>
          <span class="stat-value">${formatBytes(mem.used)} (${((mem.used / mem.total) * 100).toFixed(1)}%)</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Free</span>
          <span class="stat-value">${formatBytes(mem.free)}</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Available</span>
          <span class="stat-value">${formatBytes(mem.available)}</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Active</span>
          <span class="stat-value">${formatBytes(mem.active || 0)}</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Buffers/Cached</span>
          <span class="stat-value">${formatBytes(mem.buffcache || 0)}</span>
        </div>
        <div class="stat-row" style="margin-top: 12px; border-top: 1px solid #3c3c3c; padding-top: 12px;">
          <span class="stat-label">Swap Total</span>
          <span class="stat-value">${formatBytes(mem.swapTotal)}</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Swap Used</span>
          <span class="stat-value">${formatBytes(mem.swapUsed)} (${mem.swapTotal > 0 ? ((mem.swapUsed / mem.swapTotal) * 100).toFixed(1) : 0}%)</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Swap Free</span>
          <span class="stat-value">${formatBytes(mem.swapFree || (mem.swapTotal - mem.swapUsed))}</span>
        </div>
      `;
    }
  } else if (type === 'network' && data.network) {
    const info = document.getElementById('detail-net-info');
    if (info) {
      info.innerHTML = data.network.map(n => `
        <div class="stat-row">
          <span class="stat-label">${n.iface}</span>
          <span class="stat-value">↓ ${formatBps(n.rx_sec || 0)} / ↑ ${formatBps(n.tx_sec || 0)}</span>
        </div>
      `).join('') || '<div class="stat-row"><span class="stat-label">No active interfaces</span></div>';
    }
  } else if (type === 'disk' && data.disk) {
    const info = document.getElementById('detail-disk-info');
    if (info) {
      info.innerHTML = data.disk.map(d => `
        <div class="stat-row">
          <span class="stat-label">${d.mount} (${d.fs})</span>
          <span class="stat-value ${getLoadClass(d.usePercent)}">${d.usePercent.toFixed(0)}% used</span>
        </div>
        <div class="progress-bar">
          <div class="progress-fill disk" style="width: ${d.usePercent}%"></div>
        </div>
        <div style="font-size: 11px; color: #888; margin-top: 4px; margin-bottom: 12px;">
          ${formatBytes(d.used)} used of ${formatBytes(d.size)} (${formatBytes(d.available)} free)
        </div>
      `).join('');
    }
  }
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

    // Update smoothed values for stable sorting
    const activePids = [];
    for (const process of processList) {
      updateSmoothedValues(process);
      activePids.push(process.pid);
    }
    cleanupSmoothedValues(activePids);

    if (currentView === 'processes') {
      renderProcessView();
    }
  }
}

// WebSocket connection for metrics
let ws = null;
let wsConnected = false;

function connectWebSocket() {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${protocol}//${location.host}`);

  ws.onopen = () => {
    wsConnected = true;
  };

  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      if (msg.type === 'full') {
        updateUI(msg.data, true);
      } else if (msg.type === 'update') {
        updateUI(msg.data, false);
      } else if (msg.type === 'kill') {
        ws.send(JSON.stringify({ type: 'refresh' }));
      }
      // Note: 'action' type now handled by SDK IPC via window.__termweb
    } catch (e) {
      // Ignore parse errors
    }
  };

  ws.onclose = () => {
    wsConnected = false;
    // Reconnect after 1 second
    setTimeout(connectWebSocket, 1000);
  };
}

function killProcess(pid) {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'kill', pid }));
  }
}

// Request fresh metrics from server (returns promise)
function requestMetrics(type = 'full') {
  return new Promise((resolve) => {
    if (!ws || !wsConnected) {
      resolve(null);
      return;
    }
    // One-time listener for response
    const handler = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'full') {
          ws.removeEventListener('message', handler);
          resolve(msg.data);
        }
      } catch (e) {}
    };
    ws.addEventListener('message', handler);
    ws.send(JSON.stringify({ type: 'refresh' }));
    // Timeout after 2 seconds
    setTimeout(() => {
      ws.removeEventListener('message', handler);
      resolve(null);
    }, 2000);
  });
}

// Keyboard handling - only for process view navigation (arrow keys, etc.)
// Main view keys (p, c, m, n, d, f) are handled by SDK via WebSocket
window.addEventListener('keydown', async (e) => {
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

    if (e.key === 'Escape') {
      hideDetailView();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      const oldIndex = selectedProcessIndex;
      selectedProcessIndex = Math.max(0, selectedProcessIndex - 1);
      if (!updateSelectionFast(oldIndex, selectedProcessIndex)) {
        renderProcessView();
      }
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      const oldIndex = selectedProcessIndex;
      const maxIndex = processList.length - 1; // Use cached list length
      selectedProcessIndex = Math.min(maxIndex, selectedProcessIndex + 1);
      if (!updateSelectionFast(oldIndex, selectedProcessIndex)) {
        renderProcessView();
      }
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault();
      const idx = SORT_COLUMNS.indexOf(sortColumn);
      sortColumn = SORT_COLUMNS[(idx - 1 + SORT_COLUMNS.length) % SORT_COLUMNS.length];
      selectedProcessIndex = 0;
      // Instant: update header + apply CSS order
      const thead = document.querySelector('.process-table thead tr');
      if (thead) thead.innerHTML = buildTableHeader();
      if (!applySortOrder()) renderProcessView();
      updateHints();
      // Background: fetch fresh data
      requestMetrics('full').then(data => { if (data) updateUI(data, true); });
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      const idx = SORT_COLUMNS.indexOf(sortColumn);
      sortColumn = SORT_COLUMNS[(idx + 1) % SORT_COLUMNS.length];
      selectedProcessIndex = 0;
      // Instant: update header + apply CSS order
      const thead = document.querySelector('.process-table thead tr');
      if (thead) thead.innerHTML = buildTableHeader();
      if (!applySortOrder()) renderProcessView();
      updateHints();
      // Background: fetch fresh data
      requestMetrics('full').then(data => { if (data) updateUI(data, true); });
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
document.addEventListener('DOMContentLoaded', () => {
  // Focus page to receive keyboard events
  document.body.tabIndex = -1;
  document.body.focus();
  window.focus();

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

  updateHints();

  // Register SDK IPC handler for key binding actions
  window.__termweb.onMessage((msg) => {
    if (msg.type === 'action') {
      if (msg.action === 'view:processes') {
        window.__termwebView('processes');
      } else if (msg.action === 'view:cpu') {
        window.__termwebView('cpu');
      } else if (msg.action === 'view:memory') {
        window.__termwebView('memory');
      } else if (msg.action === 'view:network') {
        window.__termwebView('network');
      } else if (msg.action === 'view:disk') {
        window.__termwebView('disk');
      } else if (msg.action === 'filter') {
        window.__termwebFilter();
      }
    }
  });

  // Connect to WebSocket - server pushes metrics
  connectWebSocket();
});
