// Image viewer app for termweb-open

const params = new URLSearchParams(window.location.search);
const filePath = params.get('file');
const fileName = params.get('name') || 'Image';
const fileType = params.get('type') || 'image';

document.title = fileName;

const container = document.getElementById('container');
const img = document.getElementById('image');
const info = document.getElementById('info');

let scale = 1;
let translateX = 0;
let translateY = 0;
let isDragging = false;
let lastX = 0;
let lastY = 0;

function updateTransform() {
  img.style.transform = `translate(${translateX}px, ${translateY}px) scale(${scale})`;
}

function fitToScreen() {
  const containerRect = container.getBoundingClientRect();
  const imgWidth = img.naturalWidth;
  const imgHeight = img.naturalHeight;

  const scaleX = containerRect.width / imgWidth;
  const scaleY = containerRect.height / imgHeight;
  scale = Math.min(scaleX, scaleY, 1); // Don't upscale
  translateX = 0;
  translateY = 0;
  updateTransform();
  updateInfo();
}

function updateInfo() {
  info.textContent = `${fileName} | ${img.naturalWidth}x${img.naturalHeight} | ${Math.round(scale * 100)}%`;
}

// Load image
if (filePath) {
  img.src = `file://${filePath}`;
  img.onload = () => {
    fitToScreen();
  };
  img.onerror = () => {
    container.innerHTML = `<div style="color: red; text-align: center; padding: 20px;">Failed to load image: ${fileName}</div>`;
  };
}

// Keyboard controls
document.addEventListener('keydown', (e) => {
  switch (e.key) {
    case '+':
    case '=':
      scale = Math.min(scale * 1.25, 10);
      updateTransform();
      updateInfo();
      break;
    case '-':
    case '_':
      scale = Math.max(scale / 1.25, 0.1);
      updateTransform();
      updateInfo();
      break;
    case '0':
      scale = 1;
      translateX = 0;
      translateY = 0;
      updateTransform();
      updateInfo();
      break;
    case 'f':
    case 'F':
      fitToScreen();
      break;
    case 'ArrowLeft':
    case 'h':
      translateX += 50;
      updateTransform();
      break;
    case 'ArrowRight':
    case 'l':
      translateX -= 50;
      updateTransform();
      break;
    case 'ArrowUp':
    case 'k':
      translateY += 50;
      updateTransform();
      break;
    case 'ArrowDown':
    case 'j':
      translateY -= 50;
      updateTransform();
      break;
  }
});

// Mouse wheel zoom
container.addEventListener('wheel', (e) => {
  e.preventDefault();
  const delta = e.deltaY > 0 ? 0.9 : 1.1;
  scale = Math.max(0.1, Math.min(10, scale * delta));
  updateTransform();
  updateInfo();
});

// Mouse drag
container.addEventListener('mousedown', (e) => {
  isDragging = true;
  lastX = e.clientX;
  lastY = e.clientY;
  container.style.cursor = 'grabbing';
});

document.addEventListener('mousemove', (e) => {
  if (!isDragging) return;
  translateX += e.clientX - lastX;
  translateY += e.clientY - lastY;
  lastX = e.clientX;
  lastY = e.clientY;
  updateTransform();
});

document.addEventListener('mouseup', () => {
  isDragging = false;
  container.style.cursor = 'grab';
});
