import { marked } from 'marked';

// Configure marked for security
marked.setOptions({
  breaks: true,
  gfm: true
});

let notebook = { cells: [] };
let notebookPath = null;
let selectedCell = null;

// Termweb FS IPC
const pendingFS = new Map();
let fsId = 0;

window.__termwebFSResponse = (id, success, data) => {
  const resolve = pendingFS.get(id);
  if (resolve) { pendingFS.delete(id); resolve({ success, data }); }
};

function fsCall(op, path, data = '') {
  return new Promise(resolve => {
    const id = ++fsId;
    pendingFS.set(id, resolve);
    console.log(data ? `__TERMWEB_FS__:${id}:${op}:${path}:${data}` : `__TERMWEB_FS__:${id}:${op}:${path}`);
    setTimeout(() => { if (pendingFS.has(id)) { pendingFS.delete(id); resolve({ success: false, data: 'Timeout' }); } }, 5000);
  });
}

// Load notebook from URL params
function init() {
  const params = new URLSearchParams(location.search);
  const content = params.get('content');
  notebookPath = params.get('path');

  if (content) {
    try {
      notebook = JSON.parse(atob(content));
    } catch (e) {
      notebook = { cells: [], metadata: {}, nbformat: 4, nbformat_minor: 5 };
    }
  }

  if (notebookPath) {
    document.getElementById('filename').textContent = notebookPath.split('/').pop();
  }

  renderNotebook();
}

function renderNotebook() {
  const container = document.getElementById('notebook');
  container.innerHTML = '';

  if (!notebook.cells || notebook.cells.length === 0) {
    notebook.cells = [{
      cell_type: 'code',
      source: ['# Start writing code here\n'],
      outputs: [],
      execution_count: null
    }];
  }

  notebook.cells.forEach((cell, idx) => {
    const cellEl = createCellElement(cell, idx);
    container.appendChild(cellEl);
  });
}

function createCellElement(cell, idx) {
  const div = document.createElement('div');
  div.className = `cell ${cell.cell_type}`;
  div.dataset.cellId = `cell-${idx}`;

  const source = Array.isArray(cell.source) ? cell.source.join('') : cell.source || '';
  const outputs = cell.outputs || [];

  div.innerHTML = `
    <div class="cell-toolbar">
      <span class="type">${cell.cell_type === 'code' ? 'Code' : 'Markdown'}</span>
      ${cell.execution_count ? `<span class="execution-count">[${cell.execution_count}]</span>` : ''}
      <div class="actions">
        <button onclick="window.toggleEdit(${idx})">Edit</button>
        <button onclick="window.deleteCell(${idx})">Delete</button>
      </div>
    </div>
    <div class="cell-input">
      <textarea rows="${Math.max(3, source.split('\n').length)}" oninput="window.updateCell(${idx}, this.value)">${escapeHtml(source)}</textarea>
    </div>
    ${cell.cell_type === 'markdown' ? `<div class="cell-rendered">${marked.parse(source)}</div>` : ''}
    <div class="cell-output ${outputs[0]?.output_type === 'error' ? 'error' : 'stream'}">${formatOutput(outputs)}</div>
  `;

  div.onclick = (e) => {
    if (!e.target.matches('button, textarea')) {
      selectCell(div);
    }
  };

  return div;
}

function escapeHtml(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function formatOutput(outputs) {
  if (!outputs || outputs.length === 0) return '';
  return outputs.map(o => {
    if (o.text) return Array.isArray(o.text) ? o.text.join('') : o.text;
    if (o.data && o.data['text/plain']) return o.data['text/plain'].join('');
    return '';
  }).join('\n');
}

function selectCell(cellEl) {
  document.querySelectorAll('.cell.selected').forEach(c => c.classList.remove('selected'));
  cellEl.classList.add('selected');
  selectedCell = cellEl;
}

window.toggleEdit = function(idx) {
  const cellEl = document.querySelector(`[data-cell-id="cell-${idx}"]`);
  if (cellEl.classList.contains('markdown')) {
    cellEl.classList.toggle('editing');
    if (cellEl.classList.contains('editing')) {
      cellEl.querySelector('textarea').focus();
    } else {
      // Re-render markdown
      const source = notebook.cells[idx].source;
      const text = Array.isArray(source) ? source.join('') : source || '';
      cellEl.querySelector('.cell-rendered').innerHTML = marked.parse(text);
    }
  }
};

window.updateCell = function(idx, value) {
  notebook.cells[idx].source = value.split('\n').map((l, i, arr) => i < arr.length - 1 ? l + '\n' : l);
};

window.deleteCell = function(idx) {
  if (notebook.cells.length <= 1) return;
  notebook.cells.splice(idx, 1);
  renderNotebook();
};

function addCell(type) {
  notebook.cells.push({
    cell_type: type,
    source: type === 'code' ? [''] : ['# New markdown cell\n'],
    outputs: [],
    execution_count: null
  });
  renderNotebook();
}

async function saveNotebook() {
  if (!notebookPath) return;

  document.getElementById('status').textContent = 'Saving...';

  try {
    const content = JSON.stringify(notebook, null, 2);
    const encoded = btoa(unescape(encodeURIComponent(content)));
    const res = await fsCall('writefile', notebookPath, encoded);

    if (res.success) {
      document.getElementById('status').textContent = 'Saved';
      setTimeout(() => {
        document.getElementById('status').textContent = 'View/Edit Mode';
      }, 2000);
    } else {
      document.getElementById('status').textContent = 'Save failed: ' + res.data;
    }
  } catch (err) {
    document.getElementById('status').textContent = 'Save failed';
  }
}

// Initialize on load
document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('btn-add-code').onclick = () => addCell('code');
  document.getElementById('btn-add-md').onclick = () => addCell('markdown');
  document.getElementById('btn-save').onclick = saveNotebook;

  // Keyboard shortcuts
  document.addEventListener('keydown', (e) => {
    if (e.ctrlKey && e.key === 's') {
      e.preventDefault();
      saveNotebook();
    }
  });

  init();
});
