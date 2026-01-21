// Clipboard interceptor for termweb
// Injected via Page.addScriptToEvaluateOnNewDocument to run in all frames
(function() {
  if (window._termwebClipboardHook) return;
  window._termwebClipboardHook = true;
  window._termwebClipboardData = '';
  window._termwebClipboardVersion = 0;
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

  // Hook navigator.clipboard.readText
  if (navigator.clipboard && navigator.clipboard.readText) {
    navigator.clipboard.readText = async function() {
      const ver = window._termwebClipboardVersion;
      console.log('__TERMWEB_CLIPBOARD_REQUEST__');
      for (let i = 0; i < 20; i++) {
        await new Promise(r => setTimeout(r, 10));
        if (window._termwebClipboardVersion > ver) break;
      }
      return window._termwebClipboardData || '';
    };
  }

  // Hook document.execCommand for copy/cut
  const origExecCommand = document.execCommand.bind(document);
  document.execCommand = function(cmd, showUI, value) {
    console.log('[TERMWEB] execCommand called:', cmd);
    if (cmd === 'copy' || cmd === 'cut') {
      let text = '';
      const active = document.activeElement;
      console.log('[TERMWEB] activeElement:', active ? active.tagName : 'null', active ? active.className?.substring(0,30) : '');
      // Try activeElement (Monaco uses hidden textarea)
      if (active && (active.tagName === 'TEXTAREA' || active.tagName === 'INPUT')) {
        const start = active.selectionStart;
        const end = active.selectionEnd;
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
        console.log('__TERMWEB_CLIPBOARD__:' + text);
      }
    }
    return origExecCommand(cmd, showUI, value);
  };

  // Listen for copy/cut events - read from clipboardData synchronously
  document.addEventListener('copy', function(e) {
    console.log('[TERMWEB] copy event fired');
    let text = '';
    // Try clipboardData first (set by browser during execCommand)
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
      console.log('__TERMWEB_CLIPBOARD__:' + text);
    }
  }, true);

  document.addEventListener('cut', function(e) {
    console.log('[TERMWEB] cut event fired');
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
      console.log('__TERMWEB_CLIPBOARD__:' + text);
    }
  }, true);

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
