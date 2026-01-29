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
let pendingKill = null; // { pid, name } when waiting for kill confirmation
let connectionsData = []; // Network connections by host
let currentDiskPath = '/'; // Current folder path for disk drill-down
let previousDiskPath = '/'; // Previous path to revert on error
let pendingDiskPath = null; // Path being loaded (before confirmation)
let folderData = []; // Folder sizes for current path
let selectedFolderIndex = 0; // Selected folder in disk treemap
let pendingDelete = null; // { path, size } pending delete confirmation

// Persistent stats history (collected continuously, survives view changes)
// 1 minute at 5s interval = 12 data points
const HISTORY_SIZE = 12;
const statsHistory = {
  cpu: { load: [], perCore: [] },
  memory: { percent: [], used: [] },
  network: { rx: [], tx: [] },
  disk: null, // Latest disk info only
  processes: null // Latest process list only
};

function pushHistory(arr, value) {
  arr.push(value);
  if (arr.length > HISTORY_SIZE) arr.shift();
}

const SORT_COLUMNS = ['pid', 'name', 'cpu', 'mem', 'port'];
const FULLSCREEN_ROW_HEIGHT = 20;

// Notify Node.js of view change (so it knows whether to forward key bindings)
function notifyViewChange(view) {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'viewChange', view }));
  }
}

// Notify Node.js of kill confirmation state
function notifyKillConfirm() {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'killConfirm' }));
  }
}

function notifyKillCancel() {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'killCancel' }));
  }
}

function notifyDeleteConfirm() {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'deleteConfirm' }));
  }
}

function notifyDeleteCancel() {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'deleteCancel' }));
  }
}

// View change handler (called from SDK IPC and click handlers)
function switchView(view) {
  if (currentView !== 'main') return;
  currentView = view;
  notifyViewChange(view);
  selectedProcessIndex = 0;
  isFiltering = false;
  renderCurrentView();
}

async function renderCurrentView() {
  document.getElementById('main-dashboard').style.display = currentView === 'main' ? 'block' : 'none';
  document.getElementById('process-fullscreen').style.display = currentView === 'processes' ? 'flex' : 'none';
  document.getElementById('detail-fullscreen').style.display = ['cpu', 'memory', 'network', 'disk'].includes(currentView) ? 'flex' : 'none';

  if (currentView === 'processes') {
    renderProcessView();
  } else if (['cpu', 'memory', 'network', 'disk'].includes(currentView)) {
    // Use cached data from main dashboard (already updated every 5s)
    detailLoading = !lastDetailData;
    renderDetailView(currentView);
    if (lastDetailData) {
      updateDetailView(currentView, lastDetailData);
    }
    // Request additional data for network and disk views
    if (currentView === 'network') {
      requestConnections();
    } else if (currentView === 'disk') {
      initDiskSelectedPath();
      folderData = [];
      // Request fresh metrics to ensure disk stats are available
      if (ws && wsConnected) {
        ws.send(JSON.stringify({ type: 'refresh' }));
      }
      requestFolderSizes(currentDiskPath);
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

  // Filter (case-insensitive, ignore spaces)
  if (filterText) {
    const normalized = filterText.toLowerCase().replace(/\s+/g, '');
    list = list.filter(p => {
      const nameNorm = p.name.toLowerCase().replace(/\s+/g, '');
      const pidStr = p.pid.toString();
      return nameNorm.includes(normalized) ||
        pidStr.includes(normalized) ||
        (p.ports && p.ports.some(port => port.includes(normalized)));
    });
  }

  // Sort using smoothed values for cpu/mem to prevent jumping
  list.sort((a, b) => {
    let cmp = 0;
    switch (sortColumn) {
      case 'pid': cmp = a.pid - b.pid; break;
      case 'name': cmp = a.name.localeCompare(b.name); break;
      case 'cpu':
        cmp = a.cpu - b.cpu;
        break;
      case 'mem':
        cmp = a.mem - b.mem;
        break;
      case 'port':
        // Parse first port as number for numeric sort
        const aPort = parseInt(a.ports?.[0], 10) || 0;
        const bPort = parseInt(b.ports?.[0], 10) || 0;
        cmp = aPort - bPort;
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

// Build table rows HTML with transform positioning
function buildTableRows(filtered) {
  return filtered.map((p, i) => {
    const selected = i === selectedProcessIndex;
    const ports = p.ports?.join(', ') || '-';
    const y = i * FULLSCREEN_ROW_HEIGHT;
    return `<tr data-pid="${p.pid}" style="transform: translateY(${y}px)" class="${selected ? 'selected' : ''}">
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

// Apply sort order with transform animation
function applySortOrder() {
  const tbody = document.querySelector('.process-table tbody');
  if (!tbody) return false;

  const filtered = getFilteredProcesses();
  const rows = tbody.querySelectorAll('tr');

  // Build pid -> new index map
  const indexMap = new Map();
  filtered.forEach((p, i) => indexMap.set(p.pid, i));

  // Apply transform position to each row
  rows.forEach(row => {
    const pid = parseInt(row.dataset.pid, 10);
    const idx = indexMap.get(pid);
    if (idx !== undefined) {
      row.style.transform = `translateY(${idx * FULLSCREEN_ROW_HEIGHT}px)`;
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

  // Update tbody height
  tbody.style.height = `${filtered.length * FULLSCREEN_ROW_HEIGHT}px`;

  return true;
}

// Build table header HTML
function buildTableHeader() {
  return SORT_COLUMNS.map(col => {
    const arrow = sortColumn === col ? (sortAsc ? '▲' : '▼') : '';
    return `<th class="${sortColumn === col ? 'sorted' : ''}">${col.toUpperCase()} ${arrow}</th>`;
  }).join('') + '<th>STATE</th><th>USER</th>';
}

// Update table in place with transform animation
function updateTable() {
  const thead = document.querySelector('.process-table thead tr');
  const tbody = document.querySelector('.process-table tbody');
  if (!thead || !tbody) return false;

  const filtered = getFilteredProcesses();
  if (selectedProcessIndex >= filtered.length) {
    selectedProcessIndex = Math.max(0, filtered.length - 1);
  }

  // Update header
  thead.innerHTML = buildTableHeader();

  // Get existing rows by PID
  const existingRows = new Map();
  tbody.querySelectorAll('tr').forEach(row => {
    existingRows.set(parseInt(row.dataset.pid, 10), row);
  });

  // Track which PIDs are in filtered list
  const filteredPids = new Set(filtered.map(p => p.pid));
  const allPids = new Set(processList.map(p => p.pid));

  // Update or create rows
  filtered.forEach((p, i) => {
    let row = existingRows.get(p.pid);
    const isNew = !row;

    if (isNew) {
      // Create new row with flash effect
      row = document.createElement('tr');
      row.dataset.pid = p.pid;
      row.style.transition = 'none';
      row.classList.add('row-new');
      for (let j = 0; j < 7; j++) {
        row.appendChild(document.createElement('td'));
      }
      tbody.appendChild(row);
      // Remove flash class after animation
      setTimeout(() => row.classList.remove('row-new'), 600);
    }

    // Update cell innerText
    const cells = row.querySelectorAll('td');
    cells[0].textContent = p.pid;
    cells[1].textContent = p.name;
    cells[2].textContent = p.cpu.toFixed(1) + '%';
    cells[2].className = getLoadClass(p.cpu);
    cells[3].textContent = p.mem.toFixed(1) + '%';
    cells[4].textContent = p.ports?.join(', ') || '-';
    cells[5].textContent = p.state || '';
    cells[6].textContent = p.user || '';

    // Position with transform
    const newY = i * FULLSCREEN_ROW_HEIGHT;
    if (isNew) {
      // New row: set position directly without animation
      row.style.transform = `translateY(${newY}px)`;
      // Enable transition after initial position set
      requestAnimationFrame(() => {
        row.style.transition = 'transform 0.4s ease-out';
      });
    } else {
      // Existing row: animate to new position
      row.style.transform = `translateY(${newY}px)`;
    }

    row.style.display = '';
    row.classList.toggle('selected', i === selectedProcessIndex);
  });

  // Remove or hide rows
  existingRows.forEach((row, pid) => {
    if (!allPids.has(pid)) {
      row.remove();
    } else if (!filteredPids.has(pid)) {
      row.style.display = 'none';
    }
  });

  // Set tbody height
  tbody.style.height = `${filtered.length * FULLSCREEN_ROW_HEIGHT}px`;

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
    <div class="process-header" tabindex="-1">
      <h2>Processes</h2>
      <input type="text" id="filter-input" value="${filterText}" placeholder="Search by name, pid, or port..." tabindex="0" autofocus>
    </div>
    <div class="process-table-wrap" tabindex="-1">
      <table class="process-table" tabindex="-1">
        <thead><tr>${buildTableHeader()}</tr></thead>
        <tbody style="height: ${filtered.length * FULLSCREEN_ROW_HEIGHT}px">${buildTableRows(filtered)}</tbody>
      </table>
    </div>
  `;

  container.style.display = 'flex';
  document.getElementById('main-dashboard').style.display = 'none';

  // Focus input immediately after render
  const input = document.getElementById('filter-input');
  input.focus();

  input.addEventListener('input', (e) => {
    filterText = e.target.value;
    selectedProcessIndex = 0;
    applySortOrder();
  });

  updateHints();
}

// Render detail view for cpu, memory, network, disk
function renderDetailView(type) {
  const container = document.getElementById('detail-fullscreen');
  const titles = { cpu: 'CPU Details', memory: 'Memory Details', network: 'Network Details', disk: 'Disk Details' };

  // Destroy previous detail chart
  if (detailChart) {
    detailChart.destroy();
    detailChart = null;
  }

  let content = '';
  if (detailLoading) {
    // Show spinner when no data yet
    content = '<div class="spinner">Loading...</div>';
  } else if (type === 'cpu') {
    content = `
      <div id="detail-cpu-info"></div>
      <div id="detail-cpu-cores" class="core-grid"></div>
      <div id="detail-cpu-dist" class="distribution-chart"></div>
    `;
  } else if (type === 'memory') {
    content = `
      <div id="detail-mem-info"></div>
      <div id="detail-mem-dist" class="distribution-chart"></div>
    `;
  } else if (type === 'network') {
    content = `
      <div class="detail-chart"><canvas id="detail-chart-canvas"></canvas></div>
      <div id="detail-net-connections" class="distribution-chart" style="flex:1;min-height:200px;"></div>
    `;
  } else if (type === 'disk') {
    content = `
      <div id="detail-disk-path" class="disk-path" tabindex="-1"></div>
      <div id="detail-disk-treemap" class="distribution-chart" style="flex:1;" tabindex="-1"></div>
      <div style="margin-top:8px;" tabindex="-1">
        <input type="text" id="disk-selected-path" value="" tabindex="0" autofocus style="width:100%;background:#2d2d2d;border:1px solid #444;color:#fff;padding:6px 10px;border-radius:4px;font-family:monospace;font-size:12px;">
      </div>
    `;
  }

  container.innerHTML = `
    <div class="detail-header">
      <h2>${titles[type]}</h2>
    </div>
    <div class="detail-content">${content}</div>
  `;

  // Create chart only for network (line chart)
  const canvas = document.getElementById('detail-chart-canvas');
  if (canvas && type === 'network') {
    // Pre-fill with history data (pad with zeros if not enough history)
    const historyRx = [...statsHistory.network.rx];
    const historyTx = [...statsHistory.network.tx];
    while (historyRx.length < HISTORY_SIZE) historyRx.unshift(0);
    while (historyTx.length < HISTORY_SIZE) historyTx.unshift(0);

    detailChart = new Chart(canvas, {
      type: 'line',
      data: {
        labels: Array(HISTORY_SIZE).fill(''),
        datasets: [
          {
            label: 'Download',
            data: historyRx,
            borderColor: 'rgb(106, 153, 85)',
            backgroundColor: 'rgba(106, 153, 85, 0.1)',
            fill: true,
            tension: 0.3,
            pointRadius: 0,
            borderWidth: 2
          },
          {
            label: 'Upload',
            data: historyTx,
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
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 0 },
        plugins: { legend: { display: true } },
        scales: {
          x: { display: false },
          y: {
            display: true,
            min: 0,
            grid: { color: 'rgba(60, 60, 60, 0.5)' },
            ticks: { color: '#888', font: { size: 10 } }
          }
        }
      }
    });
  }
}

// Color palette for treemap
const TREEMAP_COLORS = [
  '#569cd6', '#4ec9b0', '#dcdcaa', '#ce9178', '#c586c0',
  '#6a9955', '#d7ba7d', '#9cdcfe', '#f14c4c', '#b5cea8'
];

// Squarified treemap layout algorithm
function squarify(items, x, y, w, h, result = []) {
  if (items.length === 0) return result;
  if (items.length === 1) {
    result.push({ ...items[0], x, y, w, h });
    return result;
  }

  const total = items.reduce((sum, it) => sum + it.value, 0);
  if (total === 0) return result;

  // Determine layout direction (horizontal or vertical split)
  const vertical = h > w;
  const side = vertical ? h : w;

  // Find best split using squarify algorithm
  let row = [];
  let rowSum = 0;
  let remaining = [...items];

  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const testRow = [...row, item];
    const testSum = rowSum + item.value;

    // Calculate aspect ratios
    const rowArea = (testSum / total) * w * h;
    const rowSide = vertical ? (rowArea / w) : (rowArea / h);
    const worstRatio = Math.max(...testRow.map(it => {
      const itemArea = (it.value / testSum) * rowArea;
      const itemSide = vertical ? (itemArea / rowSide) : (itemArea / rowSide);
      const otherSide = rowSide;
      return Math.max(itemSide / otherSide, otherSide / itemSide);
    }));

    // Check if adding this item improves or worsens the layout
    if (row.length > 0) {
      const prevRowArea = (rowSum / total) * w * h;
      const prevRowSide = vertical ? (prevRowArea / w) : (prevRowArea / h);
      const prevWorstRatio = Math.max(...row.map(it => {
        const itemArea = (it.value / rowSum) * prevRowArea;
        const itemSide = vertical ? (itemArea / prevRowSide) : (itemArea / prevRowSide);
        const otherSide = prevRowSide;
        return Math.max(itemSide / otherSide, otherSide / itemSide);
      }));

      if (worstRatio > prevWorstRatio && row.length > 0) {
        // Layout current row and recurse with remaining
        const rowArea = (rowSum / total) * w * h;
        const rowSize = vertical ? (rowArea / w) : (rowArea / h);

        let offset = 0;
        for (const rowItem of row) {
          const itemSize = (rowItem.value / rowSum) * (vertical ? w : h);
          if (vertical) {
            result.push({ ...rowItem, x: x + offset, y, w: itemSize, h: rowSize });
          } else {
            result.push({ ...rowItem, x, y: y + offset, w: rowSize, h: itemSize });
          }
          offset += itemSize;
        }

        // Recurse with remaining items
        if (vertical) {
          return squarify(remaining.slice(row.length), x, y + rowSize, w, h - rowSize, result);
        } else {
          return squarify(remaining.slice(row.length), x + rowSize, y, w - rowSize, h, result);
        }
      }
    }

    row.push(item);
    rowSum += item.value;
  }

  // Layout final row
  const rowArea = (rowSum / total) * w * h;
  const rowSize = vertical ? (rowArea / w) : (rowArea / h);
  let offset = 0;
  for (const rowItem of row) {
    const itemSize = (rowItem.value / rowSum) * (vertical ? w : h);
    if (vertical) {
      result.push({ ...rowItem, x: x + offset, y, w: itemSize, h: rowSize });
    } else {
      result.push({ ...rowItem, x, y: y + offset, w: rowSize, h: itemSize });
    }
    offset += itemSize;
  }

  return result;
}

// Render treemap for top consumers
// systemUsedPct: actual system usage percentage (shown in label only, not in treemap)
function renderTreemap(containerId, processes, valueKey, label, systemUsedPct = null) {
  const container = document.getElementById(containerId);
  if (!container || !processes || processes.length === 0) return;

  // Get all processes with significant usage, sorted by value
  const sorted = [...processes]
    .filter(p => p[valueKey] > 0.1)
    .sort((a, b) => b[valueKey] - a[valueKey]);

  const processTotal = sorted.reduce((sum, p) => sum + p[valueKey], 0);
  if (processTotal === 0) {
    container.innerHTML = '<div style="color: #888; padding: 16px;">No significant usage</div>';
    return;
  }

  // Show processes relative to each other (no System/Free cells)
  // This is how htop/btop display - processes only, system usage in header
  const items = sorted.map((p, i) => ({
    name: p.name,
    pid: p.pid,
    value: p[valueKey],
    pct: p[valueKey],
    mem: p.mem,
    cpu: p.cpu,
    color: TREEMAP_COLORS[i % TREEMAP_COLORS.length]
  }));

  // Calculate layout (use percentage-based coordinates)
  const layout = squarify(items, 0, 0, 100, 100);

  // Build treemap HTML - show system usage in label
  const usedLabel = systemUsedPct !== null
    ? `${systemUsedPct.toFixed(1)}% system used, ${processTotal.toFixed(1)}% by visible processes`
    : `${processTotal.toFixed(1)}% by processes`;
  let html = `<div class="treemap-label">${label} (${usedLabel})</div><div class="treemap-2d">`;
  for (const item of layout) {
    const showLabel = item.w > 8 && item.h > 12;
    const showValue = item.w > 5 && item.h > 8;
    const tip = `${item.name} (PID: ${item.pid}) | CPU: ${item.cpu.toFixed(1)}% | MEM: ${item.mem.toFixed(1)}%`;
    html += `
      <div class="treemap-cell" style="left:${item.x}%;top:${item.y}%;width:${item.w}%;height:${item.h}%;background:${item.color};" data-tip="${tip}">
        ${showLabel ? `<span class="treemap-name">${item.name}</span>` : ''}
        ${showValue ? `<span class="treemap-value">${item.pct.toFixed(1)}%</span>` : ''}
      </div>
    `;
  }
  html += '</div>';
  container.innerHTML = html;
}


// Request connections from server
function requestConnections() {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'connections' }));
  }
}

// Request folder sizes from server
function requestFolderSizes(path) {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'folderSizes', path }));
  }
}

// Render connections treemap
function renderConnectionsTreemap(containerId) {
  const container = document.getElementById(containerId);
  if (!container || connectionsData.length === 0) {
    if (container) container.innerHTML = '<div style="color:#888;padding:16px;">No active connections</div>';
    return;
  }

  const totalBytes = connectionsData.reduce((sum, c) => sum + (c.bytes || 0), 0);
  const items = connectionsData.map((c, i) => ({
    ip: c.host,
    hostname: c.hostname || c.host,
    name: (c.hostname && c.hostname !== c.host) ? c.hostname : c.host,
    value: c.bytes || 1, // Use bytes for sizing
    bytes: c.bytes || 0,
    count: c.count,
    ports: c.ports,
    processes: c.processes,
    color: TREEMAP_COLORS[i % TREEMAP_COLORS.length]
  }));

  const layout = squarify(items, 0, 0, 100, 100);

  let html = `<div class="treemap-label">Network Traffic (${formatBytes(totalBytes)} total)</div><div class="treemap-2d">`;
  for (const item of layout) {
    const showLabel = item.w > 10 && item.h > 15;
    const showValue = item.w > 6 && item.h > 10;
    const hostInfo = item.hostname !== item.ip ? `${item.hostname} (${item.ip})` : item.ip;
    const tip = `${hostInfo} | ${formatBytes(item.bytes)} | ${item.count} conn | Ports: ${item.ports.join(',')} | ${item.processes.join(',')}`;
    html += `
      <div class="treemap-cell" style="left:${item.x}%;top:${item.y}%;width:${item.w}%;height:${item.h}%;background:${item.color};" data-tip="${tip}">
        ${showLabel ? `<span class="treemap-name">${item.name}</span>` : ''}
        ${showValue ? `<span class="treemap-value">${formatBytes(item.bytes)}</span>` : ''}
      </div>
    `;
  }
  html += '</div>';
  container.innerHTML = html;
}

// Get disk capacity for current path
function getDiskCapacity() {
  if (!statsHistory.disk || statsHistory.disk.length === 0) return null;
  // Find the disk that best matches currentDiskPath (longest matching mount point)
  let bestMatch = null;
  let bestLen = 0;
  for (const d of statsHistory.disk) {
    if (currentDiskPath.startsWith(d.mount) && d.mount.length > bestLen) {
      bestMatch = d;
      bestLen = d.mount.length;
    }
  }
  return bestMatch;
}

// Render folder treemap with drill-down
function renderFolderTreemap(containerId) {
  const container = document.getElementById(containerId);
  if (!container) return;

  if (folderData.length === 0) {
    container.innerHTML = '<div class="spinner">Scanning...</div>';
    return;
  }

  // Clamp selection
  if (selectedFolderIndex >= folderData.length) {
    selectedFolderIndex = Math.max(0, folderData.length - 1);
  }

  const confirmedFolders = folderData.filter(f => f.confirmed);
  const unconfirmedFolders = folderData.filter(f => !f.confirmed);
  const confirmedTotal = confirmedFolders.reduce((sum, f) => sum + f.size, 0);
  const disk = getDiskCapacity();
  const diskTotal = disk ? disk.size : (confirmedTotal + unconfirmedFolders.length * 1000000000); // Fallback estimate

  // Calculate remaining space for unconfirmed folders to share equally
  const remainingSpace = Math.max(0, diskTotal - confirmedTotal);
  const unconfirmedShare = unconfirmedFolders.length > 0 ? remainingSpace / unconfirmedFolders.length : 0;

  // Build items list - confirmed use actual size, unconfirmed share remaining space equally
  const items = folderData.map((f, i) => ({
    name: f.name,
    path: f.path,
    value: f.confirmed ? f.size : unconfirmedShare, // Unconfirmed share remaining space
    size: f.size, // Keep actual/estimated size for display
    confirmed: f.confirmed,
    index: i,
    isOther: false,
    color: TREEMAP_COLORS[i % TREEMAP_COLORS.length]
  }));

  // Add "Other / Free" only when all folders are confirmed (at root level)
  const folderTotal = folderData.reduce((sum, f) => sum + f.size, 0);
  if (disk && currentDiskPath === '/' && unconfirmedFolders.length === 0) {
    const otherSize = Math.max(0, diskTotal - folderTotal);
    if (otherSize > 0) {
      items.push({
        name: 'Other / Free',
        path: '',
        value: otherSize,
        size: otherSize,
        confirmed: true,
        index: -1,
        isOther: true,
        color: '#3c3c3c' // Dark gray for free space
      });
    }
  }

  const layout = squarify(items, 0, 0, 100, 100);

  const scanningText = unconfirmedFolders.length > 0 ? ` (scanning ${confirmedFolders.length}/${folderData.length})` : '';
  const diskInfo = disk ? ` of ${formatBytes(diskTotal)}` : '';
  let html = `<div class="treemap-label">Folder Sizes (${formatBytes(confirmedTotal)}${diskInfo})${scanningText}</div><div class="treemap-2d">`;
  for (const item of layout) {
    const showLabel = item.w > 8 && item.h > 12;
    const showValue = item.w > 5 && item.h > 8;
    const pct = diskTotal > 0 ? (item.size / diskTotal * 100).toFixed(1) : 0;

    if (item.isOther) {
      // "Other / Free" cell - not clickable, different styling
      const tip = `Free space: ${formatBytes(item.size)} (${pct}% of disk)`;
      html += `
        <div class="treemap-cell" style="left:${item.x}%;top:${item.y}%;width:${item.w}%;height:${item.h}%;background-color:${item.color};opacity:0.5;cursor:default;" data-tip="${tip}">
          ${showLabel ? `<span class="treemap-name" style="color:#888;">${item.name}</span>` : ''}
          ${showValue ? `<span class="treemap-value" style="color:#666;">${formatBytes(item.size)}</span>` : ''}
        </div>
      `;
    } else {
      const status = item.confirmed ? '' : ' (scanning...)';
      const tip = `${item.path} | ${item.confirmed ? formatBytes(item.size) : 'scanning...'}${status}${item.confirmed ? ` (${pct}% of disk)` : ''}`;
      const isSelected = item.index === selectedFolderIndex;
      // Unconfirmed items have striped pattern overlay
      const opacity = item.confirmed ? 1 : 0.6;
      const pattern = item.confirmed ? '' : 'background-image: repeating-linear-gradient(45deg, transparent, transparent 5px, rgba(0,0,0,0.1) 5px, rgba(0,0,0,0.1) 10px);';
      const selectedStyle = isSelected ? 'outline: 3px solid #fff; outline-offset: -3px; z-index: 10;' : '';
      html += `
        <div class="treemap-cell folder-cell${isSelected ? ' selected' : ''}" style="left:${item.x}%;top:${item.y}%;width:${item.w}%;height:${item.h}%;background-color:${item.color};opacity:${opacity};${pattern}${selectedStyle}" data-tip="${tip}" data-path="${item.path}" data-index="${item.index}">
          ${showLabel ? `<span class="treemap-name">${item.name}</span>` : ''}
          ${showValue ? `<span class="treemap-value">${item.confirmed ? formatBytes(item.size) : '...'}</span>` : ''}
        </div>
      `;
    }
  }
  html += '</div>';
  container.innerHTML = html;

  // Add click handlers for drill-down
  container.querySelectorAll('.folder-cell').forEach(cell => {
    cell.addEventListener('click', () => {
      const path = cell.dataset.path;
      if (path) {
        drillIntoFolder(path);
      }
    });
  });

  // Update selected path textbox
  updateSelectedPath();
}

// Drill into a folder
function drillIntoFolder(path) {
  currentDiskPath = path;
  folderData = [];
  selectedFolderIndex = 0;
  updateDiskPath();
  renderFolderTreemap('detail-disk-treemap');
  requestFolderSizes(path);
}

// Update folder selection visually
function updateFolderSelection() {
  const cells = document.querySelectorAll('.folder-cell');
  cells.forEach(cell => {
    const idx = parseInt(cell.dataset.index, 10);
    const isSelected = idx === selectedFolderIndex;
    cell.classList.toggle('selected', isSelected);
    cell.style.outline = isSelected ? '3px solid #fff' : '';
    cell.style.outlineOffset = isSelected ? '-3px' : '';
    cell.style.zIndex = isSelected ? '10' : '';
  });
  updateSelectedPath();
}

// Update disk path breadcrumb
function updateDiskPath() {
  const pathEl = document.getElementById('detail-disk-path');
  if (!pathEl) return;

  const parts = currentDiskPath.split('/').filter(p => p);
  let html = '<span class="path-item" data-path="/">/</span> ';
  let accumulated = '';
  for (const part of parts) {
    accumulated += '/' + part;
    html += `<span class="path-item" data-path="${accumulated}">${part}/</span> `;
  }
  pathEl.innerHTML = html.trim();

  pathEl.querySelectorAll('.path-item').forEach(item => {
    item.addEventListener('click', () => {
      const path = item.dataset.path;
      if (path && path !== currentDiskPath) {
        currentDiskPath = path;
        folderData = [];
        updateDiskPath();
        renderFolderTreemap('detail-disk-treemap');
        requestFolderSizes(path);
      }
    });
  });
}

// Update selected folder path in textbox
function updateSelectedPath() {
  const input = document.getElementById('disk-selected-path');
  if (!input) return;
  const folder = folderData[selectedFolderIndex];
  input.value = folder ? folder.path : currentDiskPath;
}

// Initialize selected path input with Enter handler
function initDiskSelectedPath() {
  const input = document.getElementById('disk-selected-path');
  if (!input) return;

  input.focus();

  // Prevent clicks outside input from stealing focus
  const container = document.getElementById('detail-fullscreen');
  if (container) {
    container.addEventListener('mousedown', (e) => {
      if (e.target !== input) e.preventDefault();
    });
  }

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      let path = input.value.trim();
      if (!path) return;

      // Allow ~ paths, otherwise ensure starts with /
      if (!path.startsWith('/') && !path.startsWith('~')) {
        path = '/' + path;
      }

      // Remove trailing slash
      if (path.length > 1 && path.endsWith('/')) {
        path = path.slice(0, -1);
      }

      if (path !== currentDiskPath) {
        // Store current as previous for reverting on error
        previousDiskPath = currentDiskPath;
        pendingDiskPath = path;
        folderData = [];
        selectedFolderIndex = 0;
        // Don't update breadcrumb yet - wait for server response
        renderFolderTreemap('detail-disk-treemap');
        requestFolderSizes(path);
      }
    }
  });
}

// Navigate up one directory level
function navigateUp() {
  if (currentDiskPath === '/') return;
  const parts = currentDiskPath.split('/').filter(p => p);
  parts.pop();
  currentDiskPath = parts.length === 0 ? '/' : '/' + parts.join('/');
  folderData = [];
  selectedFolderIndex = 0;
  updateDiskPath();
  renderFolderTreemap('detail-disk-treemap');
  requestFolderSizes(currentDiskPath);
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
        <div class="progress-bar" style="margin-top: 8px;">
          <div class="progress-fill cpu" style="width: ${data.cpu.load.toFixed(1)}%"></div>
        </div>
      `;
    }
    if (cores && data.cpu.loadPerCore) {
      cores.innerHTML = data.cpu.loadPerCore.map((load, i) => `
        <div class="core-item">
          <div class="label">${i + 1}</div>
          <div class="value ${getLoadClass(load)}">${load.toFixed(0)}%</div>
        </div>
      `).join('');
    }
    // Treemap of top CPU consumers
    if (data.processes?.list) {
      renderTreemap('detail-cpu-dist', data.processes.list, 'cpu', 'CPU', data.cpu.load);
    }
  } else if (type === 'memory' && data.memory) {
    const mem = data.memory;
    const memPercent = (mem.used / mem.total) * 100;
    const info = document.getElementById('detail-mem-info');
    if (info) {
      info.innerHTML = `
        <div class="stat-row">
          <span class="stat-label">Total</span>
          <span class="stat-value">${formatBytes(mem.total)}</span>
        </div>
        <div class="stat-row">
          <span class="stat-label">Used</span>
          <span class="stat-value">${formatBytes(mem.used)} (${memPercent.toFixed(1)}%)</span>
        </div>
        <div class="progress-bar" style="margin-top: 4px; margin-bottom: 8px;">
          <div class="progress-fill mem" style="width: ${memPercent.toFixed(1)}%"></div>
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
    // Treemap of top memory consumers
    if (data.processes?.list) {
      renderTreemap('detail-mem-dist', data.processes.list, 'mem', 'Memory', memPercent);
    }
  } else if (type === 'network' && data.network) {
    const netRx = data.network.reduce((sum, n) => sum + (n.rx_sec || 0), 0);
    const netTx = data.network.reduce((sum, n) => sum + (n.tx_sec || 0), 0);
    // Update chart
    if (detailChart) {
      detailChart.data.datasets[0].data.push(netRx);
      detailChart.data.datasets[0].data.shift();
      detailChart.data.datasets[1].data.push(netTx);
      detailChart.data.datasets[1].data.shift();
      detailChart.update('none');
    }
    // Render connections treemap
    renderConnectionsTreemap('detail-net-connections');
  } else if (type === 'disk') {
    // Disk view uses folder treemap, not stats
    updateDiskPath();
    renderFolderTreemap('detail-disk-treemap');
  }
}

// Hide any detail view and go back to main
function hideDetailView() {
  // Destroy detail chart
  if (detailChart) {
    detailChart.destroy();
    detailChart = null;
  }
  document.getElementById('process-fullscreen').style.display = 'none';
  document.getElementById('detail-fullscreen').style.display = 'none';
  document.getElementById('main-dashboard').style.display = 'block';
  currentView = 'main';
  notifyViewChange('main');
  isFiltering = false;
  pendingKill = null;
  updateHints();
}

// Update bottom hints based on current view
function updateHints() {
  const hints = document.getElementById('hints');
  if (currentView === 'main') {
    hints.innerHTML = '<span>c: CPU</span><span>m: Memory</span><span>n: Network</span><span>d: Disk</span><span>p: Processes</span><span>Ctrl+Q: Quit</span>';
  } else if (currentView === 'processes') {
    if (pendingKill) {
      const ports = pendingKill.ports?.join(',') || '-';
      hints.innerHTML = `<span style="color: #f14c4c;">Kill "${pendingKill.name}" PID:${pendingKill.pid} CPU:${pendingKill.cpu.toFixed(1)}% MEM:${pendingKill.mem.toFixed(1)}% PORT:${ports} ? Y: Confirm, N: Cancel</span>`;
    } else {
      hints.innerHTML = `
        <span>Tab/Shift+Tab: Sort (${sortColumn})</span>
        <span>↑↓: Select</span>
        <span>Ctrl+K: Kill</span>
        <span>Esc: Back</span>
      `;
    }
  } else if (currentView === 'disk') {
    if (pendingDelete) {
      hints.innerHTML = `<span style="color: #f14c4c;">Delete "${pendingDelete.path}" (${formatBytes(pendingDelete.size)}) ? Y: Confirm, N: Cancel</span>`;
    } else {
      hints.innerHTML = '<span>Tab/Shift+Tab: Select</span><span>Enter: Go to path</span><span>Ctrl+Enter: Drill in</span><span>Ctrl+⌫: Up</span><span>Ctrl+D: Delete</span><span>Esc: Back</span>';
    }
  } else {
    hints.innerHTML = '<span>Esc: Back</span>';
  }
}

function updateUI(data, isFull) {
  // Always persist to history (regardless of current view)
  if (data.cpu) {
    pushHistory(statsHistory.cpu.load, data.cpu.load);
    if (data.cpu.loadPerCore) {
      pushHistory(statsHistory.cpu.perCore, [...data.cpu.loadPerCore]);
    }
  }
  if (data.memory) {
    // Always use total for accurate percentage (used + free != total due to cached/buffers)
    const memTotal = data.memory.total || (data.memory.used + data.memory.free);
    const memPercent = (data.memory.used / memTotal) * 100;
    pushHistory(statsHistory.memory.percent, memPercent);
    pushHistory(statsHistory.memory.used, data.memory.used);
  }
  if (data.network) {
    const netRx = data.network.reduce((sum, n) => sum + (n.rx_sec || 0), 0);
    const netTx = data.network.reduce((sum, n) => sum + (n.tx_sec || 0), 0);
    pushHistory(statsHistory.network.rx, netRx);
    pushHistory(statsHistory.network.tx, netTx);
  }
  if (isFull && data.disk) {
    statsHistory.disk = data.disk;
  }
  if (isFull && data.processes) {
    statsHistory.processes = data.processes;
  }

  // Update UI for current view
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
          <div class="label">${i + 1}</div>
          <div class="value ${getLoadClass(load)}">${load.toFixed(0)}%</div>
        </div>
      `).join('');
    }

    // Memory - always use total for accurate percentage
    const memPercent = (data.memory.used / (data.memory.total || (data.memory.used + data.memory.free))) * 100;
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

    // Processes (mini view) - use same sort as fullscreen
    if (isFull && data.processes) {
      const tbody = document.getElementById('process-tbody');
      // Update mini table header to show current sort
      const miniThead = document.querySelector('#process-table thead tr');
      if (miniThead) {
        const cols = ['pid', 'name', 'cpu', 'mem', 'port'];
        const labels = ['PID', 'Name', 'CPU %', 'MEM %', 'PORT'];
        miniThead.innerHTML = cols.map((col, i) => {
          const arrow = sortColumn === col ? (sortAsc ? '▲' : '▼') : '';
          return `<th class="${sortColumn === col ? 'sorted' : ''}">${labels[i]} ${arrow}</th>`;
        }).join('');
      }
      // Sort using same column/order as fullscreen view
      const sorted = [...data.processes.list].sort((a, b) => {
        let cmp = 0;
        switch (sortColumn) {
          case 'pid': cmp = a.pid - b.pid; break;
          case 'name': cmp = a.name.localeCompare(b.name); break;
          case 'cpu': cmp = a.cpu - b.cpu; break;
          case 'mem': cmp = a.mem - b.mem; break;
          case 'port':
            const aPort = parseInt(a.ports?.[0], 10) || 0;
            const bPort = parseInt(b.ports?.[0], 10) || 0;
            cmp = aPort - bPort;
            break;
        }
        return sortAsc ? cmp : -cmp;
      });
      const procs = sorted.slice(0, 10);
      const rowHeight = 24;

      // Get existing rows by PID
      const existingRows = new Map();
      tbody.querySelectorAll('tr').forEach(row => {
        if (row.dataset.pid) {
          existingRows.set(parseInt(row.dataset.pid, 10), row);
        }
      });

      const procsSet = new Set(procs.map(p => p.pid));

      // Update or create rows, position with transform
      procs.forEach((p, i) => {
        let row = existingRows.get(p.pid);
        if (!row) {
          row = document.createElement('tr');
          row.dataset.pid = p.pid;
          row.classList.add('row-new');
          for (let j = 0; j < 5; j++) {
            row.appendChild(document.createElement('td'));
          }
          tbody.appendChild(row);
          setTimeout(() => row.classList.remove('row-new'), 600);
        }

        // Update cells
        const cells = row.querySelectorAll('td');
        cells[0].textContent = p.pid;
        cells[1].textContent = p.name;
        cells[2].textContent = p.cpu.toFixed(1) + '%';
        cells[2].className = getLoadClass(p.cpu);
        cells[3].textContent = p.mem.toFixed(1) + '%';
        cells[4].textContent = p.ports?.join(', ') || '-';

        // Position with transform (animates via CSS transition)
        row.style.transform = `translateY(${i * rowHeight}px)`;
      });

      // Remove old rows not in top 10
      existingRows.forEach((row, pid) => {
        if (!procsSet.has(pid)) {
          row.remove();
        }
      });

      // Set tbody height for proper spacing
      tbody.style.height = `${procs.length * rowHeight}px`;
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
      // Update table in place without re-rendering container (preserves search input)
      if (!updateTable()) {
        renderProcessView();
      }
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
        lastDetailData = msg.data; // Cache for detail views
        updateUI(msg.data, true);
        // Update detail view if active
        if (['cpu', 'memory', 'network'].includes(currentView)) {
          updateDetailView(currentView, msg.data);
        }
        // Periodically refresh connections when on network view
        if (currentView === 'network') {
          requestConnections();
        }
      } else if (msg.type === 'update') {
        updateUI(msg.data, false);
      } else if (msg.type === 'kill') {
        ws.send(JSON.stringify({ type: 'refresh' }));
      } else if (msg.type === 'delete') {
        if (msg.success && msg.path) {
          // Remove deleted folder from cache and update display
          folderData = folderData.filter(f => f.path !== msg.path);
          if (selectedFolderIndex >= folderData.length) {
            selectedFolderIndex = Math.max(0, folderData.length - 1);
          }
          if (currentView === 'disk') {
            renderFolderTreemap('detail-disk-treemap');
            updateSelectedPath();
          }
        }
      } else if (msg.type === 'connections') {
        connectionsData = msg.data || [];
        if (currentView === 'network') {
          renderConnectionsTreemap('detail-net-connections');
        }
      } else if (msg.type === 'folderSizes') {
        const data = msg.data || [];

        // Check if this is a response for a pending navigation
        if (pendingDiskPath) {
          // Check if response matches pending path (resolved or not)
          const isForPending = msg.path === pendingDiskPath ||
            (pendingDiskPath.startsWith('~') && msg.path && !msg.path.startsWith('~'));

          if (isForPending) {
            if (data.length === 0) {
              // Path not found - revert to previous
              currentDiskPath = previousDiskPath;
              pendingDiskPath = null;
              // Restore previous view
              requestFolderSizes(currentDiskPath);
              return;
            }
            // Success - update to resolved path
            currentDiskPath = msg.path;
            pendingDiskPath = null;
            updateDiskPath();
          } else {
            // Response for different path - ignore
            return;
          }
        } else {
          // Normal update (not from textbox navigation)
          if (msg.path && msg.path !== currentDiskPath) {
            return; // Ignore stale responses
          }
        }

        folderData = data;
        if (currentView === 'disk') {
          renderFolderTreemap('detail-disk-treemap');
        }
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

function deleteFolder(path) {
  if (ws && wsConnected) {
    ws.send(JSON.stringify({ type: 'delete', path }));
  }
}

function showToast(message) {
  // Create or reuse toast element
  let toast = document.getElementById('toast');
  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'toast';
    toast.style.cssText = 'position:fixed;bottom:60px;left:50%;transform:translateX(-50%);background:#333;color:#fff;padding:8px 16px;border-radius:4px;z-index:9999;opacity:0;transition:opacity 0.3s;';
    document.body.appendChild(toast);
  }
  toast.textContent = message;
  toast.style.opacity = '1';
  setTimeout(() => { toast.style.opacity = '0'; }, 2000);
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

// Single keyboard handler with state-based logic (capture phase to intercept before input)
// NOTE: y/n for kill confirmation are handled via SDK key bindings, not here
window.addEventListener('keydown', (e) => {
  const key = e.key;

  // State 1: Kill confirmation mode - block browser keys except y/n (handled by SDK)
  if (pendingKill) {
    // Only allow Escape to cancel (as fallback)
    if (key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      pendingKill = null;
      notifyKillCancel();
      updateHints();
    } else {
      // Block all other keys during kill confirm
      e.preventDefault();
      e.stopPropagation();
    }
    return;
  }

  // State 2: Process view
  if (currentView === 'processes') {
    // Tab: change sort
    if (key === 'Tab') {
      e.preventDefault();
      e.stopPropagation();
      const idx = SORT_COLUMNS.indexOf(sortColumn);
      sortColumn = e.shiftKey
        ? SORT_COLUMNS[(idx - 1 + SORT_COLUMNS.length) % SORT_COLUMNS.length]
        : SORT_COLUMNS[(idx + 1) % SORT_COLUMNS.length];
      selectedProcessIndex = 0;
      const thead = document.querySelector('.process-table thead tr');
      if (thead) thead.innerHTML = buildTableHeader();
      applySortOrder();
      updateHints();
      requestMetrics('full').then(data => { if (data) updateUI(data, true); });
      return;
    }
    // Ctrl+K: start kill (only if process selected)
    if (key === 'k' && e.ctrlKey) {
      const proc = getFilteredProcesses()[selectedProcessIndex];
      if (!proc) return; // Ignore if no process
      e.preventDefault();
      e.stopPropagation();
      pendingKill = {
        pid: proc.pid,
        name: proc.name,
        cpu: proc.cpu,
        mem: proc.mem,
        ports: proc.ports
      };
      notifyKillConfirm(); // Tell SDK to bind y/n keys
      updateHints();
      return;
    }
    // Arrow keys: select
    if (key === 'ArrowUp') {
      e.preventDefault();
      e.stopPropagation();
      const oldIndex = selectedProcessIndex;
      selectedProcessIndex = Math.max(0, selectedProcessIndex - 1);
      updateSelectionFast(oldIndex, selectedProcessIndex);
      return;
    }
    if (key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      const oldIndex = selectedProcessIndex;
      selectedProcessIndex = Math.min(processList.length - 1, selectedProcessIndex + 1);
      updateSelectionFast(oldIndex, selectedProcessIndex);
      return;
    }
    // Escape: back to main
    if (key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      hideDetailView();
      return;
    }
    return;
  }

  // State 3: Detail views (cpu, memory, network, disk)
  if (['cpu', 'memory', 'network', 'disk'].includes(currentView)) {
    // Disk view keyboard navigation (textbox always focused)
    if (currentView === 'disk') {
      // Escape: back to main
      if (key === 'Escape') {
        e.preventDefault();
        hideDetailView();
        return;
      }
      // Tab/Shift+Tab: select folder
      if (key === 'Tab') {
        e.preventDefault();
        if (folderData.length > 0) {
          if (e.shiftKey) {
            selectedFolderIndex = Math.max(0, selectedFolderIndex - 1);
          } else {
            selectedFolderIndex = Math.min(folderData.length - 1, selectedFolderIndex + 1);
          }
          updateFolderSelection();
        }
        return;
      }
      // Ctrl+A or Cmd+A: Select all text in textbox
      if (key === 'a' && (e.ctrlKey || e.metaKey)) {
        const input = document.getElementById('disk-selected-path');
        if (input) {
          e.preventDefault();
          e.stopPropagation();
          input.select();
        }
        return;
      }
      // Ctrl+Enter: Drill into selected folder
      if (key === 'Enter' && e.ctrlKey) {
        e.preventDefault();
        const folder = folderData[selectedFolderIndex];
        if (folder) {
          drillIntoFolder(folder.path);
        }
        return;
      }
      // Ctrl+Backspace: Go up one level
      if (key === 'Backspace' && e.ctrlKey) {
        e.preventDefault();
        navigateUp();
        return;
      }
      // Ctrl+D: Delete selected folder (with confirmation)
      if (key === 'd' && e.ctrlKey) {
        e.preventDefault();
        const folder = folderData[selectedFolderIndex];
        if (folder) {
          pendingDelete = { path: folder.path, size: folder.size };
          notifyDeleteConfirm();
          updateHints();
        }
        return;
      }
      // Let Enter and other keys pass through to textbox
      return;
    }

    // Other detail views (cpu, memory, network)
    if (key === 'Escape') {
      hideDetailView();
      return;
    }
  }
}, true); // Capture phase - runs before input element receives event

// Tooltip for treemap cells
function initTooltip() {
  const tooltip = document.getElementById('tooltip');
  document.addEventListener('mouseover', (e) => {
    const cell = e.target.closest('[data-tip]');
    if (cell) {
      tooltip.textContent = cell.dataset.tip;
      tooltip.style.display = 'block';
    }
  });
  document.addEventListener('mouseout', (e) => {
    const cell = e.target.closest('[data-tip]');
    if (cell) {
      tooltip.style.display = 'none';
    }
  });
  document.addEventListener('mousemove', (e) => {
    if (tooltip.style.display === 'block') {
      const rect = tooltip.getBoundingClientRect();
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      // Position tooltip, flip if needed
      let x = e.clientX + 10;
      let y = e.clientY + 10;
      if (x + rect.width > vw) {
        x = e.clientX - rect.width - 10;
      }
      if (y + rect.height > vh) {
        y = e.clientY - rect.height - 10;
      }
      tooltip.style.left = x + 'px';
      tooltip.style.top = y + 'px';
    }
  });
}

// Initialize on load
document.addEventListener('DOMContentLoaded', () => {
  // Focus page to receive keyboard events
  document.body.tabIndex = -1;
  document.body.focus();
  window.focus();

  initTooltip();
  initCharts();

  // Make cards clickable
  document.getElementById('cpu-card').addEventListener('click', () => switchView('cpu'));
  document.getElementById('memory-card').addEventListener('click', () => switchView('memory'));
  document.getElementById('network-card').addEventListener('click', () => switchView('network'));
  document.getElementById('disk-card').addEventListener('click', () => switchView('disk'));
  document.getElementById('processes').addEventListener('click', () => switchView('processes'));

  // Click header to go back to main view
  document.getElementById('header').addEventListener('click', () => {
    if (currentView !== 'main') {
      hideDetailView();
    }
  });
  document.getElementById('header').style.cursor = 'pointer';

  updateHints();

  // Register SDK IPC handler for key binding actions (c,m,n,d,p,y,n handled via SDK)
  window.__termweb.onMessage((msg) => {
    if (msg.type === 'action') {
      const action = msg.action;
      // View switching (only works on main view)
      if (action === 'view:processes') {
        switchView('processes');
      } else if (action === 'view:cpu') {
        switchView('cpu');
      } else if (action === 'view:memory') {
        switchView('memory');
      } else if (action === 'view:network') {
        switchView('network');
      } else if (action === 'view:disk') {
        switchView('disk');
      }
      // Kill confirmation via SDK (y/n keys)
      else if (action === 'kill:confirm' && pendingKill) {
        const pid = pendingKill.pid;
        pendingKill = null;
        notifyKillCancel();
        updateHints();
        killProcess(pid);
        requestMetrics('full').then(data => { if (data) updateUI(data, true); });
      } else if (action === 'kill:cancel' && pendingKill) {
        pendingKill = null;
        notifyKillCancel();
        updateHints();
      }
      // Delete confirmation via SDK (y/n keys)
      else if (action === 'delete:confirm' && pendingDelete) {
        const pathToDelete = pendingDelete.path;
        pendingDelete = null;
        notifyDeleteCancel();
        updateHints();
        deleteFolder(pathToDelete);
      } else if (action === 'delete:cancel' && pendingDelete) {
        pendingDelete = null;
        notifyDeleteCancel();
        updateHints();
      }
    }
  });

  // Connect to WebSocket - server pushes metrics
  connectWebSocket();
});
