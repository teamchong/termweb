// Termweb Bridge - Background Service Worker
// Handles tab events and relays them to termweb via console messages
// Uses offscreen document for tabCapture frame processing (service workers can't use DOM)

// Track active tab for debugging
let activeTabId = null;

// Signal polling state
let signalPollInterval = null;
let lastSignalId = 0;

// TabCapture state
let captureTabId = null;
let isCapturing = false;
let offscreenCreated = false;

// ============================================================================
// Signal Polling - Read window.__termwebRtcSignal from page via executeScript
// ============================================================================
async function pollForSignals(tabId) {
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId: tabId },
      func: () => {
        const signal = window.__termwebRtcSignal;
        if (signal) {
          const id = signal._id || 0;
          window.__termwebRtcSignal = null; // Clear after reading
          return { signal, id };
        }
        return null;
      }
    });

    if (results && results[0] && results[0].result) {
      const { signal, id } = results[0].result;
      if (id > lastSignalId) {
        lastSignalId = id;
        console.log('__TERMWEB_CAPTURE__:poll_signal:' + signal.type);
        // Forward to offscreen document
        chrome.runtime.sendMessage({ type: 'RTC_SIGNAL', data: signal });
      }
    }
  } catch (e) {
    // Tab might not exist or scripting not allowed
  }
}

function startSignalPolling(tabId) {
  stopSignalPolling();
  console.log('__TERMWEB_CAPTURE__:starting_signal_poll:' + tabId);
  signalPollInterval = setInterval(() => pollForSignals(tabId), 50);
}

function stopSignalPolling() {
  if (signalPollInterval) {
    clearInterval(signalPollInterval);
    signalPollInterval = null;
  }
}

// ============================================================================
// Offscreen Document Management
// ============================================================================
async function ensureOffscreenDocument() {
  console.log('__TERMWEB_CAPTURE__:ensuring_offscreen');
  if (offscreenCreated) {
    console.log('__TERMWEB_CAPTURE__:offscreen_already_created');
    return true;
  }

  try {
    // Check if offscreen document already exists
    const existingContexts = await chrome.runtime.getContexts({
      contextTypes: ['OFFSCREEN_DOCUMENT']
    });

    if (existingContexts.length > 0) {
      console.log('__TERMWEB_CAPTURE__:offscreen_exists');
      offscreenCreated = true;
      return true;
    }

    // Create offscreen document
    console.log('__TERMWEB_CAPTURE__:creating_offscreen');
    await chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['USER_MEDIA'],
      justification: 'Tab capture for frame streaming'
    });

    offscreenCreated = true;
    console.log('__TERMWEB_CAPTURE__:offscreen_created');
    return true;
  } catch (e) {
    console.log('__TERMWEB_CAPTURE__:offscreen_error:' + e.message);
    return false;
  }
}

// ============================================================================
// TabCapture Functions
// ============================================================================

// Start capture with user gesture context (called from content script click handler)
// This can use tabCapture.capture() directly since we're in a trusted gesture context
async function startCaptureWithGesture(tabId) {
  if (isCapturing) {
    stopCapture();
  }

  try {
    console.log('__TERMWEB_CAPTURE__:starting_gesture_capture:' + tabId);

    // Ensure offscreen document exists for frame processing
    if (!await ensureOffscreenDocument()) {
      console.log('__TERMWEB_CAPTURE__:offscreen_failed');
      return false;
    }

    // Use tabCapture.capture() - works because we're in a user gesture context
    const stream = await chrome.tabCapture.capture({
      video: true,
      audio: false,
      videoConstraints: {
        mandatory: {
          maxFrameRate: 120,
          minFrameRate: 5
        }
      }
    });

    if (!stream) {
      console.log('__TERMWEB_CAPTURE__:stream_failed');
      return false;
    }

    captureTabId = tabId;
    isCapturing = true;

    // Send stream to offscreen document for processing
    // We need to use a different approach - transfer the stream via message port
    // Actually, MediaStreams can't be transferred. We need to process in background.
    // But background is a service worker without DOM access...

    // Alternative: Get stream ID and pass to offscreen
    // The stream we captured can be converted to a stream ID
    const tracks = stream.getVideoTracks();
    if (tracks.length > 0) {
      // Store stream reference and send notification to offscreen
      globalThis.__captureStream = stream;

      // For service worker, we need to use getMediaStreamId with the captured stream
      // Actually, let's try a different approach - inject processing into page
      chrome.runtime.sendMessage({
        type: 'CAPTURE_STREAM_READY',
        tabId: tabId
      });
    }

    console.log('__TERMWEB_CAPTURE__:gesture_capture_started:' + tabId);
    return true;
  } catch (e) {
    console.log('__TERMWEB_CAPTURE__:gesture_error:' + e.message);
    return false;
  }
}

async function startCapture(tabId) {
  if (isCapturing) {
    await stopCapture();
  }

  try {
    // Ensure offscreen document exists
    if (!await ensureOffscreenDocument()) {
      console.log('__TERMWEB_CAPTURE__:offscreen_failed');
      return false;
    }

    // Get stream ID for the tab using tabCapture API
    const streamId = await chrome.tabCapture.getMediaStreamId({
      targetTabId: tabId
    });

    if (!streamId) {
      console.log('__TERMWEB_CAPTURE__:stream_id_failed');
      return false;
    }

    captureTabId = tabId;
    isCapturing = true;

    // Send stream ID to offscreen document to start capture
    chrome.runtime.sendMessage({
      type: 'START_CAPTURE',
      streamId: streamId
    });

    console.log('__TERMWEB_CAPTURE__:started:' + tabId);
    return true;
  } catch (e) {
    console.log('__TERMWEB_CAPTURE__:error:' + e.message);
    return false;
  }
}

function stopCapture() {
  isCapturing = false;
  captureTabId = null;

  // Tell offscreen document to stop
  chrome.runtime.sendMessage({ type: 'STOP_CAPTURE' });

  console.log('__TERMWEB_CAPTURE__:stopped');
}

// ============================================================================
// Tab Switch Handling
// ============================================================================
function handleTabActivated(tabId) {
  // When tab changes, restart capture on new tab
  if (isCapturing && tabId !== captureTabId) {
    // Start capturing the new active tab
    startCapture(tabId);
  }
}

// ============================================================================
// Message Handlers
// ============================================================================
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // RTC signaling from content script (forwarded from page context via postMessage)
  // Forward to offscreen document for WebRTC handling
  if (message.type === 'RTC_SIGNAL') {
    console.log('__TERMWEB_CAPTURE__:rtc_signal_forwarding');
    // Ensure offscreen document exists and forward message
    ensureOffscreenDocument().then(() => {
      chrome.runtime.sendMessage(message);
    });
    return false;
  }

  // Messages from offscreen document
  if (message.type === 'CAPTURE_WS_CONNECTED') {
    // WebSocket connected - tell termweb to trigger capture via CDP click
    console.log('__TERMWEB_CAPTURE__:ws_connected_ready');
    return false;
  }

  // Request stream ID for tabCapture (from offscreen document)
  if (message.type === 'REQUEST_STREAM_ID') {
    console.log('__TERMWEB_CAPTURE__:request_stream_id');
    // Get active tab and create stream ID
    chrome.tabs.query({ active: true, currentWindow: true }, async (tabs) => {
      if (!tabs || tabs.length === 0) {
        console.log('__TERMWEB_CAPTURE__:no_active_tab');
        sendResponse({ error: 'no_active_tab' });
        return;
      }
      try {
        const tabId = tabs[0].id;
        console.log('__TERMWEB_CAPTURE__:getting_stream_id:' + tabId);
        const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
        console.log('__TERMWEB_CAPTURE__:stream_id_obtained');
        captureTabId = tabId;
        isCapturing = true;
        // Start polling for signals from Zig
        startSignalPolling(tabId);
        sendResponse({ streamId: streamId });
      } catch (e) {
        console.log('__TERMWEB_CAPTURE__:stream_id_error:' + e.message);
        sendResponse({ error: e.message });
      }
    });
    return true; // Keep channel open for async response
  }

  // Gesture-triggered capture from content script (via CDP click on hidden button)
  // This runs in a trusted user gesture context, so tabCapture.capture() will work
  if (message.type === 'TERMWEB_GESTURE_CAPTURE') {
    console.log('__TERMWEB_CAPTURE__:gesture_received');
    if (sender.tab && sender.tab.id) {
      startCaptureWithGesture(sender.tab.id);
    }
    return false;
  }

  // Messages from termweb (via content script or direct)
  if (message.type === 'TERMWEB_START_CAPTURE') {
    startCapture(message.tabId).then(success => {
      sendResponse({ success });
    });
    return true;
  }

  // Start capture for current tab (from content script via CDP Runtime.evaluate)
  if (message.type === 'TERMWEB_START_CAPTURE_CURRENT') {
    console.log('__TERMWEB_CAPTURE__:start_capture_current');
    // Get sender's tab ID or query active tab
    if (sender.tab && sender.tab.id) {
      startCapture(sender.tab.id).then(success => {
        console.log('__TERMWEB_CAPTURE__:capture_started:' + success);
        sendResponse({ success });
      });
    } else {
      // Fallback: query active tab
      chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
        if (tabs.length > 0) {
          startCapture(tabs[0].id).then(success => {
            console.log('__TERMWEB_CAPTURE__:capture_started:' + success);
            sendResponse({ success });
          });
        }
      });
    }
    return true;
  }

  if (message.type === 'TERMWEB_STOP_CAPTURE') {
    stopCapture();
    sendResponse({ success: true });
    return false;
  }

  return false;
});

// ============================================================================
// Tab Event Listeners
// ============================================================================

// Listen for tab creation
chrome.tabs.onCreated.addListener((tab) => {
  console.log('__TERMWEB_TAB__:created:' + tab.id + ':' + (tab.url || 'about:blank'));
});

// Listen for tab updates (URL changes, loading state)
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'loading' && changeInfo.url) {
    console.log('__TERMWEB_PAGE__:loading:' + changeInfo.url);
  } else if (changeInfo.status === 'complete') {
    console.log('__TERMWEB_PAGE__:complete:' + (tab.url || ''));
  }
});

// Listen for tab activation (switching tabs)
chrome.tabs.onActivated.addListener((activeInfo) => {
  activeTabId = activeInfo.tabId;
  handleTabActivated(activeInfo.tabId);
  // Restart signal polling on new tab
  startSignalPolling(activeInfo.tabId);
  chrome.tabs.get(activeInfo.tabId, (tab) => {
    if (tab) {
      console.log('__TERMWEB_TAB__:activated:' + tab.id + ':' + (tab.url || ''));
    }
  });
});

// Listen for tab removal
chrome.tabs.onRemoved.addListener((tabId, removeInfo) => {
  console.log('__TERMWEB_TAB__:removed:' + tabId);
  // Stop capture if the captured tab was closed
  if (tabId === captureTabId) {
    stopCapture();
  }
});

// Listen for window focus changes
chrome.windows.onFocusChanged.addListener((windowId) => {
  if (windowId !== chrome.windows.WINDOW_ID_NONE) {
    console.log('__TERMWEB_WINDOW__:focused:' + windowId);
  }
});

// ============================================================================
// Startup - Create offscreen document and start signal polling
// ============================================================================
console.log('__TERMWEB_CAPTURE__:background_starting');
(async () => {
  try {
    await ensureOffscreenDocument();
    console.log('__TERMWEB_CAPTURE__:background_ready');

    // Start polling for signals on the active tab
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs && tabs.length > 0) {
        startSignalPolling(tabs[0].id);
      }
    });
  } catch (e) {
    console.log('__TERMWEB_CAPTURE__:background_error:' + e.message);
  }
})();
