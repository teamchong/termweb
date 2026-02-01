// Utility functions

// ============================================================================
// Color utilities
// ============================================================================

interface RGB {
  r: number;
  g: number;
  b: number;
}

export function hexToRgb(hex: string): RGB | null {
  const m = hex.match(/^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i);
  return m ? { r: parseInt(m[1], 16), g: parseInt(m[2], 16), b: parseInt(m[3], 16) } : null;
}

export function rgbToHex(r: number, g: number, b: number): string {
  return `#${Math.round(r).toString(16).padStart(2, '0')}${Math.round(g).toString(16).padStart(2, '0')}${Math.round(b).toString(16).padStart(2, '0')}`;
}

export function luminance(hex: string): number {
  const rgb = hexToRgb(hex);
  if (!rgb) return 0;
  return (0.299 * rgb.r / 255) + (0.587 * rgb.g / 255) + (0.114 * rgb.b / 255);
}

export function isLightColor(hex: string): boolean {
  return luminance(hex) > 0.5;
}

export function isVeryDark(hex: string): boolean {
  return luminance(hex) < 0.05;
}

export function highlightColor(hex: string, level: number): string {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const r = rgb.r + (255 - rgb.r) * level;
  const g = rgb.g + (255 - rgb.g) * level;
  const b = rgb.b + (255 - rgb.b) * level;
  return rgbToHex(r, g, b);
}

export function shadowColor(hex: string, level: number): string {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const r = rgb.r * (1 - level);
  const g = rgb.g * (1 - level);
  const b = rgb.b * (1 - level);
  return rgbToHex(r, g, b);
}

export function blendWithBlack(hex: string, alpha: number): string {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const r = rgb.r * (1 - alpha);
  const g = rgb.g * (1 - alpha);
  const b = rgb.b * (1 - alpha);
  return rgbToHex(r, g, b);
}

// ============================================================================
// Byte utilities
// ============================================================================

/**
 * Format bytes to human readable string
 */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

/**
 * Generate a unique ID
 */
export function generateId(): string {
  return Math.random().toString(36).substring(2, 9);
}

/**
 * Debounce a function
 */
export function debounce<T extends (...args: unknown[]) => void>(
  fn: T,
  delay: number
): (...args: Parameters<T>) => void {
  let timeoutId: ReturnType<typeof setTimeout> | null = null;
  return (...args: Parameters<T>) => {
    if (timeoutId) clearTimeout(timeoutId);
    timeoutId = setTimeout(() => fn(...args), delay);
  };
}

/**
 * Throttle a function
 */
export function throttle<T extends (...args: unknown[]) => void>(
  fn: T,
  limit: number
): (...args: Parameters<T>) => void {
  let inThrottle = false;
  return (...args: Parameters<T>) => {
    if (!inThrottle) {
      fn(...args);
      inThrottle = true;
      setTimeout(() => (inThrottle = false), limit);
    }
  };
}

/**
 * Apply ghostty colors to CSS variables (all derived from config)
 */
export function applyColors(colors: Record<string, string>): void {
  const root = document.documentElement;
  const bg = colors.background || '#282c34';
  const fg = colors.foreground || '#ffffff';
  const isLight = isLightColor(bg);

  // Terminal background - toolbar matches it
  root.style.setProperty('--bg', bg);
  root.style.setProperty('--toolbar-bg', bg);

  // Tabbar slightly darker than toolbar background
  const tabbarBg = shadowColor(bg, 0.1);
  root.style.setProperty('--tabbar-bg', tabbarBg);

  // Active tab is the original background
  root.style.setProperty('--tab-active', bg);

  // Text colors from foreground config
  root.style.setProperty('--text', fg);

  // Overlay colors based on theme
  const overlay = isLight ? '0,0,0' : '255,255,255';
  root.style.setProperty('--tab-hover', `rgba(${overlay},0.08)`);
  root.style.setProperty('--close-hover', `rgba(${overlay},0.1)`);
  root.style.setProperty('--text-dim', `rgba(${overlay},0.5)`);

  // Accent from foreground
  root.style.setProperty('--accent', fg);

  // Apply palette colors (palette0-palette15)
  for (let i = 0; i < 16; i++) {
    const key = `palette${i}`;
    if (colors[key]) {
      root.style.setProperty(`--palette-${i}`, colors[key]);
    }
  }
}

/**
 * Parse query string parameters
 */
export function parseQueryParams(): Record<string, string> {
  const params: Record<string, string> = {};
  const search = window.location.search.substring(1);
  if (!search) return params;

  for (const pair of search.split('&')) {
    const [key, value] = pair.split('=');
    if (key) {
      params[decodeURIComponent(key)] = decodeURIComponent(value || '');
    }
  }
  return params;
}

/**
 * Create a binary message buffer
 */
export function createBinaryMessage(type: number, ...parts: (number | Uint8Array)[]): ArrayBuffer {
  // Calculate total size
  let size = 1; // type byte
  for (const part of parts) {
    size += typeof part === 'number' ? 1 : part.length;
  }

  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);

  let offset = 0;
  view.setUint8(offset++, type);

  for (const part of parts) {
    if (typeof part === 'number') {
      view.setUint8(offset++, part);
    } else {
      bytes.set(part, offset);
      offset += part.length;
    }
  }

  return buffer;
}

/**
 * Read a little-endian u16 from a DataView
 */
export function readU16LE(view: DataView, offset: number): number {
  return view.getUint16(offset, true);
}

/**
 * Read a little-endian u32 from a DataView
 */
export function readU32LE(view: DataView, offset: number): number {
  return view.getUint32(offset, true);
}

/**
 * Write a little-endian u16 to a DataView
 */
export function writeU16LE(view: DataView, offset: number, value: number): void {
  view.setUint16(offset, value, true);
}

/**
 * Write a little-endian u32 to a DataView
 */
export function writeU32LE(view: DataView, offset: number, value: number): void {
  view.setUint32(offset, value, true);
}
