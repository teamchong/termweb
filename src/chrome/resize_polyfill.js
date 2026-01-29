// ResizeObserver polyfill for termweb
// Injected in isolated world - reports viewport changes via console.log
(function() {
  if (window.__termwebResizeInstalled) return;
  window.__termwebResizeInstalled = true;

  let lastWidth = 0;
  let lastHeight = 0;

  function reportSize() {
    const w = window.innerWidth;
    const h = window.innerHeight;
    if (w !== lastWidth || h !== lastHeight) {
      lastWidth = w;
      lastHeight = h;
      console.log('__TERMWEB_RESIZE__:' + w + ':' + h);
    }
  }

  // Report initial size
  reportSize();

  // Use ResizeObserver on documentElement for viewport changes
  if (typeof ResizeObserver !== 'undefined') {
    const observer = new ResizeObserver(reportSize);
    observer.observe(document.documentElement);
  }

  // Also listen to resize event as fallback
  window.addEventListener('resize', reportSize);
})();
