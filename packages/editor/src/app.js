import { EditorView, basicSetup } from 'codemirror';
import { EditorState } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import { defaultKeymap, indentWithTab } from '@codemirror/commands';
import { javascript } from '@codemirror/lang-javascript';
import { python } from '@codemirror/lang-python';
import { json } from '@codemirror/lang-json';
import { html } from '@codemirror/lang-html';
import { css } from '@codemirror/lang-css';
import { markdown } from '@codemirror/lang-markdown';
import { oneDark } from '@codemirror/theme-one-dark';

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
let editor = null;

function getLanguageExtension(filename) {
  const ext = filename.split('.').pop().toLowerCase();
  switch (ext) {
    case 'js':
    case 'mjs':
    case 'jsx':
    case 'ts':
    case 'tsx':
      return javascript({ jsx: ext.includes('x'), typescript: ext.startsWith('t') });
    case 'py':
      return python();
    case 'json':
      return json();
    case 'html':
    case 'htm':
      return html();
    case 'css':
    case 'scss':
    case 'less':
      return css();
    case 'md':
    case 'markdown':
      return markdown();
    default:
      return [];
  }
}

function updateStatus() {
  const s = document.getElementById('status');
  const currentContent = editor.state.doc.toString();
  const isModified = currentContent !== originalContent;
  s.textContent = isModified ? 'Modified' : 'Saved';
  s.className = 'status ' + (isModified ? 'modified' : 'saved');
}

async function saveFile() {
  if (!filePath || !editor) return;
  const content = editor.state.doc.toString();
  const encoded = btoa(unescape(encodeURIComponent(content)));
  const res = await fsCall('writefile', filePath, encoded);
  if (res.success) {
    originalContent = content;
    updateStatus();
  }
}

// Initialize on load
document.addEventListener('DOMContentLoaded', () => {
  const params = new URLSearchParams(location.search);
  filePath = params.get('path');
  const initContent = params.get('content');
  const filename = filePath ? filePath.split('/').pop() : 'untitled.txt';

  if (filePath) document.getElementById('filename').textContent = filename;

  originalContent = initContent ? atob(initContent) : '';

  const extensions = [
    basicSetup,
    oneDark,
    keymap.of([...defaultKeymap, indentWithTab]),
    getLanguageExtension(filename),
    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        updateStatus();
      }
    })
  ];

  editor = new EditorView({
    state: EditorState.create({
      doc: originalContent,
      extensions
    }),
    parent: document.getElementById('editor-container')
  });

  document.getElementById('btn-save').onclick = saveFile;
  document.addEventListener('keydown', e => {
    if (e.ctrlKey && e.key === 's') {
      e.preventDefault();
      saveFile();
    }
  });
});
