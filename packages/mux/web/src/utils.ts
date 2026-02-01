// Utility functions

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
 * Apply color scheme from config
 */
export function applyColors(colors: Record<string, string>): void {
  const root = document.documentElement;

  const colorMap: Record<string, string> = {
    background: '--terminal-bg',
    foreground: '--terminal-fg',
    selection_background: '--selection-bg',
    selection_foreground: '--selection-fg',
  };

  for (const [key, cssVar] of Object.entries(colorMap)) {
    if (colors[key]) {
      root.style.setProperty(cssVar, colors[key]);
    }
  }

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
