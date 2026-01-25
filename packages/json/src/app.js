import { JSONEditor, Mode } from 'vanilla-jsoneditor';

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
let jsonEditor = null;

function updateStatus(modified) {
  const s = document.getElementById('status');
  s.textContent = modified ? 'Modified' : 'Saved';
  s.className = 'status ' + (modified ? 'modified' : 'saved');
}

function showError(msg) {
  const bar = document.getElementById('error-bar');
  bar.textContent = msg;
  bar.classList.add('visible');
}

function hideError() {
  document.getElementById('error-bar').classList.remove('visible');
}

async function saveFile() {
  if (!filePath || !jsonEditor) return;

  try {
    const content = jsonEditor.get();
    const jsonStr = JSON.stringify(content.json, null, 2);
    const encoded = btoa(unescape(encodeURIComponent(jsonStr)));
    const res = await fsCall('writefile', filePath, encoded);
    if (res.success) {
      originalContent = jsonStr;
      updateStatus(false);
      hideError();
    } else {
      showError('Save failed: ' + res.data);
    }
  } catch (e) {
    showError('Cannot save: ' + e.message);
  }
}

// Initialize on load
document.addEventListener('DOMContentLoaded', () => {
  const params = new URLSearchParams(location.search);
  filePath = params.get('path');
  const initContent = params.get('content');

  if (filePath) document.getElementById('filename').textContent = filePath.split('/').pop();

  originalContent = initContent ? atob(initContent) : '{}';

  let initialJson;
  try {
    initialJson = JSON.parse(originalContent);
  } catch (e) {
    initialJson = {};
    showError('Invalid JSON: ' + e.message);
  }

  jsonEditor = new JSONEditor({
    target: document.getElementById('editor-container'),
    props: {
      content: { json: initialJson },
      mode: Mode.tree,
      mainMenuBar: true,
      navigationBar: true,
      statusBar: true,
      onChange: (updatedContent, previousContent, { contentErrors, patchResult }) => {
        if (contentErrors) {
          showError('JSON Error: ' + contentErrors.parseError?.message);
        } else {
          hideError();
        }
        try {
          const currentStr = JSON.stringify(updatedContent.json, null, 2);
          updateStatus(currentStr !== originalContent);
        } catch (e) {
          // ignore
        }
      }
    }
  });

  document.getElementById('btn-save').onclick = saveFile;
  document.addEventListener('keydown', e => {
    if (e.ctrlKey && e.key === 's') {
      e.preventDefault();
      saveFile();
    }
  });
});
