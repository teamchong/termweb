import * as pdfjsLib from 'pdfjs-dist';

// Set up the worker
pdfjsLib.GlobalWorkerOptions.workerSrc = 'pdf.worker.min.mjs';

let pdfDoc = null;
let currentPage = 1;
let totalPages = 0;
let scale = 1.0;

async function loadPDF(url) {
  try {
    document.getElementById('loading').style.display = 'flex';
    document.getElementById('viewer').style.display = 'none';

    const loadingTask = pdfjsLib.getDocument(url);
    pdfDoc = await loadingTask.promise;
    totalPages = pdfDoc.numPages;

    document.getElementById('total-pages').textContent = totalPages;
    document.getElementById('loading').style.display = 'none';
    document.getElementById('viewer').style.display = 'block';

    renderPage(currentPage);
  } catch (err) {
    console.error('Error loading PDF:', err);
    document.getElementById('loading').innerHTML = `
      <div style="color: #f14c4c;">
        <h2>Error Loading PDF</h2>
        <p>${err.message}</p>
      </div>
    `;
  }
}

async function renderPage(num) {
  if (!pdfDoc) return;

  const page = await pdfDoc.getPage(num);
  const viewport = page.getViewport({ scale });

  const canvas = document.getElementById('pdf-canvas');
  const context = canvas.getContext('2d');
  canvas.height = viewport.height;
  canvas.width = viewport.width;

  const renderContext = {
    canvasContext: context,
    viewport: viewport
  };

  await page.render(renderContext).promise;

  document.getElementById('current-page').textContent = num;
  document.getElementById('btn-prev').disabled = num <= 1;
  document.getElementById('btn-next').disabled = num >= totalPages;
}

function goToPrevPage() {
  if (currentPage <= 1) return;
  currentPage--;
  renderPage(currentPage);
}

function goToNextPage() {
  if (currentPage >= totalPages) return;
  currentPage++;
  renderPage(currentPage);
}

function zoomIn() {
  scale = Math.min(3.0, scale + 0.25);
  renderPage(currentPage);
  document.getElementById('zoom-level').textContent = Math.round(scale * 100) + '%';
}

function zoomOut() {
  scale = Math.max(0.25, scale - 0.25);
  renderPage(currentPage);
  document.getElementById('zoom-level').textContent = Math.round(scale * 100) + '%';
}

function fitWidth() {
  if (!pdfDoc) return;
  pdfDoc.getPage(currentPage).then(page => {
    const viewport = page.getViewport({ scale: 1 });
    const containerWidth = document.getElementById('viewer').clientWidth - 40;
    scale = containerWidth / viewport.width;
    renderPage(currentPage);
    document.getElementById('zoom-level').textContent = Math.round(scale * 100) + '%';
  });
}

// Initialize on load
document.addEventListener('DOMContentLoaded', () => {
  const params = new URLSearchParams(location.search);
  const pdfPath = params.get('file');
  const pdfName = params.get('name') || 'document.pdf';

  document.getElementById('filename').textContent = pdfName;

  document.getElementById('btn-prev').onclick = goToPrevPage;
  document.getElementById('btn-next').onclick = goToNextPage;
  document.getElementById('btn-zoom-in').onclick = zoomIn;
  document.getElementById('btn-zoom-out').onclick = zoomOut;
  document.getElementById('btn-fit').onclick = fitWidth;

  // Keyboard shortcuts
  document.addEventListener('keydown', e => {
    if (e.key === 'ArrowLeft' || e.key === 'PageUp') goToPrevPage();
    if (e.key === 'ArrowRight' || e.key === 'PageDown') goToNextPage();
    if (e.key === '+' || e.key === '=') zoomIn();
    if (e.key === '-') zoomOut();
  });

  if (pdfPath) {
    // Load PDF from file path via data URL or fetch
    loadPDF(pdfPath);
  }
});
