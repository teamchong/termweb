// Termweb Bridge - Content Script
// Injects the main world bridge script and observes viewport resize

(function() {
  'use strict';

  // Prevent double injection
  if (window.__termwebContentScriptLoaded) return;
  window.__termwebContentScriptLoaded = true;

  // Log that content script is running (this will show in CDP console events)
  console.log('__TERMWEB_CONTENT__:script_loaded:' + window.location.href);

  // Inject the bridge script into the main world (page context)
  // This allows it to override page APIs like showDirectoryPicker
  console.log('__TERMWEB_CONTENT__:injecting_bridge');
  const script = document.createElement('script');
  script.src = chrome.runtime.getURL('termweb-bridge.js');
  script.onload = function() {
    console.log('__TERMWEB_CONTENT__:bridge_loaded');
    this.remove();
  };
  script.onerror = function(e) {
    console.log('__TERMWEB_CONTENT__:bridge_error:' + e.message);
  };
  (document.head || document.documentElement).appendChild(script);

  // Observe viewport resize using ResizeObserver
  // This is more reliable than SIGWINCH for detecting browser resize
  let lastWidth = 0;
  let lastHeight = 0;
  let resizeTimeout = null;

  function reportResize() {
    const width = window.innerWidth;
    const height = window.innerHeight;

    // Only report if dimensions actually changed
    if (width !== lastWidth || height !== lastHeight) {
      lastWidth = width;
      lastHeight = height;
      // Use console.log to communicate with termweb (it intercepts these via CDP)
      console.log('__TERMWEB_RESIZE__:' + width + ':' + height);
    }
  }

  // Debounce resize events to avoid flooding
  function onResize() {
    if (resizeTimeout) {
      clearTimeout(resizeTimeout);
    }
    resizeTimeout = setTimeout(reportResize, 50);
  }

  // Initial report
  reportResize();

  // Use ResizeObserver on document.documentElement for reliable resize detection
  if (typeof ResizeObserver !== 'undefined') {
    const observer = new ResizeObserver(onResize);
    observer.observe(document.documentElement);
  } else {
    // Fallback to window resize event
    window.addEventListener('resize', onResize);
  }

  // Also listen for visualViewport changes (handles zoom, mobile keyboards, etc.)
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', onResize);
  }

  // Report page load status
  if (document.readyState === 'complete') {
    console.log('__TERMWEB_PAGE__:complete:' + window.location.href);
  } else {
    window.addEventListener('load', function() {
      console.log('__TERMWEB_PAGE__:complete:' + window.location.href);
    });
  }

  // Listen for messages from the bridge script (main world)
  window.addEventListener('message', function(event) {
    // Only accept messages from same window
    if (event.source !== window) return;

    // Forward termweb messages to console for CDP interception
    if (event.data && event.data.type === 'termweb') {
      console.log(event.data.message);
    }

    // Forward RTC signaling messages to extension background/offscreen
    if (event.data && event.data.type === '__TERMWEB_RTC__') {
      console.log('__TERMWEB_CONTENT__:forwarding_rtc_signal:' + JSON.stringify(event.data.data).substring(0, 100));
      chrome.runtime.sendMessage({
        type: 'RTC_SIGNAL',
        data: event.data.data
      }).catch(e => {
        console.log('__TERMWEB_CONTENT__:sendMessage_error:' + e.message);
      });
    }
  });
})();
