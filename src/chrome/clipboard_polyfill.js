// Clipboard interceptor for termweb
// Injected via Page.addScriptToEvaluateOnNewDocument to run in all frames
(function() {
  if (window._termwebClipboardHook) return;
  window._termwebClipboardHook = true;
  window._termwebClipboardData = '';
  window._termwebClipboardVersion = 0;
  // Store original readText for direct access (bypasses our hook)
  window._termwebOrigReadText = navigator.clipboard && navigator.clipboard.readText
    ? navigator.clipboard.readText.bind(navigator.clipboard)
    : null;
  console.log('[TERMWEB] Clipboard polyfill installing in frame:', window.location.href.substring(0, 50));

  // Hook navigator.clipboard.writeText
  if (navigator.clipboard && navigator.clipboard.writeText) {
    const origWriteText = navigator.clipboard.writeText.bind(navigator.clipboard);
    navigator.clipboard.writeText = async function(text) {
      console.log('[TERMWEB] writeText called, len=' + text.length);
      window._termwebClipboardData = text;
      console.log('__TERMWEB_CLIPBOARD__:' + text);
      return origWriteText(text).catch(() => {});
    };
  }

  // Hook navigator.clipboard.write() - Monaco might use this
  if (navigator.clipboard && navigator.clipboard.write) {
    const origWrite = navigator.clipboard.write.bind(navigator.clipboard);
    navigator.clipboard.write = async function(data) {
      console.log('[TERMWEB] write() called with', data.length, 'items');
      try {
        for (const item of data) {
          console.log('[TERMWEB] write item types:', item.types);
          if (item.types.includes('text/plain')) {
            const blob = await item.getType('text/plain');
            const text = await blob.text();
            console.log('[TERMWEB] write text:', text.length, 'chars');
            window._termwebClipboardData = text;
            console.log('__TERMWEB_CLIPBOARD__:' + text);
          }
        }
      } catch(e) {
        console.log('[TERMWEB] write error:', e);
      }
      return origWrite(data).catch(() => {});
    };
  }

  // Helper to get clipboard data from this frame or parent frames
  function getClipboardData() {
    // Check local window
    if (window._termwebClipboardData) return window._termwebClipboardData;
    // Check parent frames (for iframes like Monaco)
    try {
      let w = window.parent;
      while (w && w !== window) {
        if (w._termwebClipboardData) return w._termwebClipboardData;
        if (w === w.parent) break;
        w = w.parent;
      }
    } catch(e) {} // Cross-origin frames will throw
    // Check top
    try {
      if (window.top && window.top._termwebClipboardData) return window.top._termwebClipboardData;
    } catch(e) {}
    return '';
  }

  // Hook navigator.clipboard.readText
  if (navigator.clipboard && navigator.clipboard.readText) {
    navigator.clipboard.readText = async function() {
      // If data already set (from Cmd+V path), return immediately
      const data = getClipboardData();
      if (data) {
        console.log('[TERMWEB] readText returning cached data, len=' + data.length);
        return data;
      }
      // Otherwise request from host (for menu paste)
      const ver = window._termwebClipboardVersion;
      console.log('__TERMWEB_CLIPBOARD_REQUEST__');
      for (let i = 0; i < 20; i++) {
        await new Promise(r => setTimeout(r, 10));
        if (window._termwebClipboardVersion > ver) break;
      }
      return getClipboardData();
    };
  }

  // Hook document.execCommand for copy/cut
  const origExecCommand = document.execCommand.bind(document);
  document.execCommand = function(cmd, showUI, value) {
    console.log('[TERMWEB] execCommand called:', cmd);
    if (cmd === 'copy' || cmd === 'cut') {
      let text = '';
      const active = document.activeElement;
      console.log('[TERMWEB] activeElement:', active ? active.tagName : 'null',
        'class:', active ? active.className?.substring(0,50) : '',
        'value:', active && active.value ? active.value.substring(0, 100) : 'N/A');
      // Try activeElement (Monaco uses hidden textarea)
      if (active && (active.tagName === 'TEXTAREA' || active.tagName === 'INPUT')) {
        const start = active.selectionStart;
        const end = active.selectionEnd;
        console.log('[TERMWEB] textarea selection:', start, '-', end, 'total:', active.value?.length);
        if (start !== end) {
          text = active.value.substring(start, end);
        } else {
          text = active.value;
        }
        console.log('[TERMWEB] execCommand from textarea:', text.length, 'chars');
      }
      // Try contentEditable
      if (!text && active && active.isContentEditable) {
        const sel = window.getSelection();
        text = sel ? sel.toString() : '';
        console.log('[TERMWEB] execCommand from contentEditable:', text.length, 'chars');
      }
      // Fallback - search for any textarea with content
      if (!text) {
        const textareas = document.querySelectorAll('textarea');
        for (const ta of textareas) {
          if (ta.value) {
            text = ta.value;
            console.log('[TERMWEB] execCommand from found textarea:', text.length, 'chars');
            break;
          }
        }
      }
      // Final fallback to selection
      if (!text) {
        const sel = window.getSelection();
        text = sel ? sel.toString() : '';
        console.log('[TERMWEB] execCommand selection:', text.length, 'chars');
      }
      if (text) {
        window._termwebClipboardData = text;
        // Also set in top frame so main context can read it
        try { window.top._termwebClipboardData = text; } catch(e) {}
        console.log('__TERMWEB_CLIPBOARD__:' + text);
      }
    }
    return origExecCommand(cmd, showUI, value);
  };

  // Listen for copy/cut events - use bubbling phase (false) to run AFTER Monaco sets data
  document.addEventListener('copy', function(e) {
    console.log('[TERMWEB] copy event fired (bubble phase)');
    let text = '';
    // Try clipboardData first (should be set by Monaco now)
    if (e.clipboardData) {
      text = e.clipboardData.getData('text/plain');
      console.log('[TERMWEB] copy clipboardData:', text.length, 'chars');
    }
    // Fallback to window.getSelection
    if (!text) {
      const sel = window.getSelection();
      text = sel ? sel.toString() : '';
      console.log('[TERMWEB] copy selection:', text.length, 'chars');
    }
    if (text) {
      window._termwebClipboardData = text;
      // Also set in top frame so main context can read it
      try { window.top._termwebClipboardData = text; } catch(e) {}
      // Also write to system clipboard via original writeText
      if (window._termwebOrigReadText) {
        navigator.clipboard.writeText(text).catch(() => {});
      }
      console.log('__TERMWEB_CLIPBOARD__:' + text);
    }
  }, false); // false = bubbling phase, runs AFTER capture handlers

  document.addEventListener('cut', function(e) {
    console.log('[TERMWEB] cut event fired (bubble phase)');
    let text = '';
    if (e.clipboardData) {
      text = e.clipboardData.getData('text/plain');
      console.log('[TERMWEB] cut clipboardData:', text.length, 'chars');
    }
    if (!text) {
      const sel = window.getSelection();
      text = sel ? sel.toString() : '';
      console.log('[TERMWEB] cut selection:', text.length, 'chars');
    }
    if (text) {
      window._termwebClipboardData = text;
      // Also write to system clipboard
      if (window._termwebOrigReadText) {
        navigator.clipboard.writeText(text).catch(() => {});
      }
      console.log('__TERMWEB_CLIPBOARD__:' + text);
    }
  }, false); // false = bubbling phase

  // Listen for paste events - inject our clipboard data
  document.addEventListener('paste', function(e) {
    if (window._termwebClipboardData) {
      e.preventDefault();
      e.stopPropagation();
      const el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) {
        document.execCommand('insertText', false, window._termwebClipboardData);
      }
    }
  }, true);

  // Request clipboard from host on focusin (throttled)
  let lastFocusSync = 0;
  document.addEventListener('focusin', function(e) {
    const now = Date.now();
    if (now - lastFocusSync > 500) {
      lastFocusSync = now;
      console.log('__TERMWEB_CLIPBOARD_REQUEST__');
    }
  }, true);
})();
