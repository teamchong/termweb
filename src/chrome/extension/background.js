// Termweb Bridge - Background Service Worker
// Handles tab events and relays them to termweb via console messages

// Track active tab for debugging
let activeTabId = null;

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
  chrome.tabs.get(activeInfo.tabId, (tab) => {
    if (tab) {
      console.log('__TERMWEB_TAB__:activated:' + tab.id + ':' + (tab.url || ''));
    }
  });
});

// Listen for tab removal
chrome.tabs.onRemoved.addListener((tabId, removeInfo) => {
  console.log('__TERMWEB_TAB__:removed:' + tabId);
});

// Listen for window focus changes
chrome.windows.onFocusChanged.addListener((windowId) => {
  if (windowId !== chrome.windows.WINDOW_ID_NONE) {
    console.log('__TERMWEB_WINDOW__:focused:' + windowId);
  }
});
