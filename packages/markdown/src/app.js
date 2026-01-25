import { marked } from 'marked';

// Configure marked
marked.setOptions({
  breaks: true,
  gfm: true
});

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

let filePath = null;
let originalContent = '';
let currentView = 'split';

function updateStatus() {
  const editor = document.getElementById('editor');
  const s = document.getElementById('status');
  const isModified = editor.value !== originalContent;
  s.textContent = isModified ? 'Modified' : 'Saved';
  s.className = 'status ' + (isModified ? 'modified' : 'saved');
}

function updatePreview() {
  const editor = document.getElementById('editor');
  const preview = document.getElementById('preview');
  preview.innerHTML = marked.parse(editor.value);
}

function setView(view) {
  currentView = view;
  document.getElementById('btn-edit').classList.toggle('active', view === 'edit');
  document.getElementById('btn-preview').classList.toggle('active', view === 'preview');
  document.getElementById('btn-split').classList.toggle('active', view === 'split');

  const editorPane = document.getElementById('editor-pane');
  const previewPane = document.getElementById('preview-pane');

  if (view === 'edit') {
    editorPane.style.flex = '1';
    editorPane.style.display = 'flex';
    previewPane.style.display = 'none';
  } else if (view === 'preview') {
    editorPane.style.display = 'none';
    previewPane.style.flex = '1';
    previewPane.style.display = 'block';
    updatePreview();
  } else {
    editorPane.style.flex = '1';
    editorPane.style.display = 'flex';
    previewPane.style.flex = '1';
    previewPane.style.display = 'block';
    updatePreview();
  }
}

async function saveFile() {
  const editor = document.getElementById('editor');
  if (!filePath) return;
  const encoded = btoa(unescape(encodeURIComponent(editor.value)));
  const res = await fsCall('writefile', filePath, encoded);
  if (res.success) { originalContent = editor.value; updateStatus(); }
}

// Initialize on load
document.addEventListener('DOMContentLoaded', () => {
  const params = new URLSearchParams(location.search);
  filePath = params.get('path');
  const initContent = params.get('content');

  if (filePath) document.getElementById('filename').textContent = filePath.split('/').pop();

  const editor = document.getElementById('editor');

  if (initContent) {
    originalContent = atob(initContent);
    editor.value = originalContent;
    updatePreview();
  }

  document.getElementById('btn-edit').onclick = () => setView('edit');
  document.getElementById('btn-preview').onclick = () => setView('preview');
  document.getElementById('btn-split').onclick = () => setView('split');
  document.getElementById('btn-save').onclick = saveFile;

  editor.addEventListener('input', () => { updateStatus(); if (currentView !== 'edit') updatePreview(); });
  document.addEventListener('keydown', e => { if (e.ctrlKey && e.key === 's') { e.preventDefault(); saveFile(); } });

  setView('split');
});
