// Utility functions

import {
  BYTES,
  COLORS,
  ID_GENERATION,
  WS_PATHS,
} from './constants';

// ============================================================================
// WebSocket utilities
// ============================================================================

/** Get the auth token query string (?token=xxx) from the current page URL */
function getAuthQuery(): string {
  const params = new URLSearchParams(window.location.search);
  const token = params.get('token');
  return token ? `?token=${encodeURIComponent(token)}` : '';
}

/**
 * Build WebSocket URL from path - auto-detects ws/wss based on page protocol.
 * Forwards ?token= query parameter from page URL to WebSocket URL for auth.
 */
export function getWsUrl(path: string): string {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const host = window.location.host;
  return `${protocol}//${host}${path}${getAuthQuery()}`;
}

/**
 * Build authenticated HTTP URL for sub-resources (WASM, workers, etc.).
 * Appends ?token= from the page URL so each request authenticates.
 */
export function getAuthUrl(path: string): string {
  return `${path}${getAuthQuery()}`;
}

// ============================================================================
// Shared instances (avoid creating on every call)
// ============================================================================

/** Shared TextEncoder instance - reuse to avoid allocation */
export const sharedTextEncoder = new TextEncoder();

/** Shared TextDecoder instance - reuse to avoid allocation */
export const sharedTextDecoder = new TextDecoder();

// ============================================================================
// Platform detection (computed once)
// ============================================================================

/** Whether the current platform is macOS/iOS */
export const isMac = typeof navigator !== 'undefined' && (
  (navigator as { userAgentData?: { platform?: string } }).userAgentData?.platform === 'macOS'
  || /Mac|iPhone|iPad|iPod/.test(navigator.userAgent)
);

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
  const clamp = (v: number) => Math.max(0, Math.min(255, Math.round(v)));
  return `#${clamp(r).toString(16).padStart(2, '0')}${clamp(g).toString(16).padStart(2, '0')}${clamp(b).toString(16).padStart(2, '0')}`;
}

/** Calculate relative luminance using BT.601 coefficients */
export function luminance(hex: string): number {
  const rgb = hexToRgb(hex);
  if (!rgb) return 0;
  return (0.299 * rgb.r / 255) + (0.587 * rgb.g / 255) + (0.114 * rgb.b / 255);
}

export function isLightColor(hex: string): boolean {
  return luminance(hex) > COLORS.LUMINANCE_LIGHT_THRESHOLD;
}

export function isVeryDark(hex: string): boolean {
  return luminance(hex) < COLORS.LUMINANCE_VERY_DARK_THRESHOLD;
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
  if (bytes < BYTES.KB) return `${bytes} B`;
  if (bytes < BYTES.MB) return `${(bytes / BYTES.KB).toFixed(1)} KB`;
  if (bytes < BYTES.GB) return `${(bytes / BYTES.MB).toFixed(1)} MB`;
  return `${(bytes / BYTES.GB).toFixed(2)} GB`;
}

/**
 * Generate a unique ID
 */
export function generateId(): string {
  return Math.random().toString(ID_GENERATION.RADIX).substring(ID_GENERATION.START, ID_GENERATION.START + ID_GENERATION.LENGTH);
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
export function throttle<T extends (...args: never[]) => void>(
  fn: T,
  limit: number
): (...args: Parameters<T>) => void {
  let pending: Parameters<T> | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  return (...args: Parameters<T>) => {
    if (timer === null) {
      // Leading edge: fire immediately
      fn(...args);
      timer = setTimeout(() => {
        // Trailing edge: fire latest queued args if any
        if (pending !== null) {
          fn(...pending);
          pending = null;
        }
        timer = null;
      }, limit);
    } else {
      // During throttle window: save latest args
      pending = args;
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
 * Parse query string parameters using modern URLSearchParams API
 */
export function parseQueryParams(): Record<string, string> {
  const params: Record<string, string> = {};
  const searchParams = new URLSearchParams(window.location.search);
  searchParams.forEach((value, key) => {
    params[key] = value;
  });
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

// ============================================================================
// BinaryReader utility class for parsing binary messages
// ============================================================================

/**
 * BinaryReader - helper class for reading binary protocol messages
 * Tracks offset automatically and provides bounds checking
 */
export class BinaryReader {
  private view: DataView;
  private bytes: Uint8Array;
  private _offset: number;
  private length: number;

  constructor(data: ArrayBuffer, startOffset = 0) {
    this.view = new DataView(data);
    this.bytes = new Uint8Array(data);
    this._offset = startOffset;
    this.length = data.byteLength;
  }

  get offset(): number {
    return this._offset;
  }

  get remaining(): number {
    return this.length - this._offset;
  }

  hasBytes(count: number): boolean {
    return this._offset + count <= this.length;
  }

  readU8(): number {
    if (!this.hasBytes(1)) throw new RangeError('Buffer overflow reading u8');
    return this.view.getUint8(this._offset++);
  }

  readU16(): number {
    if (!this.hasBytes(2)) throw new RangeError('Buffer overflow reading u16');
    const val = this.view.getUint16(this._offset, true);
    this._offset += 2;
    return val;
  }

  readU32(): number {
    if (!this.hasBytes(4)) throw new RangeError('Buffer overflow reading u32');
    const val = this.view.getUint32(this._offset, true);
    this._offset += 4;
    return val;
  }

  readU64(): bigint {
    if (!this.hasBytes(8)) throw new RangeError('Buffer overflow reading u64');
    const val = this.view.getBigUint64(this._offset, true);
    this._offset += 8;
    return val;
  }

  readF32(): number {
    if (!this.hasBytes(4)) throw new RangeError('Buffer overflow reading f32');
    const val = this.view.getFloat32(this._offset, true);
    this._offset += 4;
    return val;
  }

  readF64(): number {
    if (!this.hasBytes(8)) throw new RangeError('Buffer overflow reading f64');
    const val = this.view.getFloat64(this._offset, true);
    this._offset += 8;
    return val;
  }

  readBytes(length: number): Uint8Array {
    if (!this.hasBytes(length)) throw new RangeError(`Buffer overflow reading ${length} bytes`);
    const val = this.bytes.slice(this._offset, this._offset + length);
    this._offset += length;
    return val;
  }

  readString(length: number): string {
    return sharedTextDecoder.decode(this.readBytes(length));
  }

  readLengthPrefixedString(lengthBytes: 1 | 2 = 2): string {
    const len = lengthBytes === 1 ? this.readU8() : this.readU16();
    return this.readString(len);
  }

  skip(count: number): void {
    if (!this.hasBytes(count)) throw new RangeError(`Buffer overflow skipping ${count} bytes`);
    this._offset += count;
  }
}

// ============================================================================
// Circular buffer for efficient fixed-size collections
// ============================================================================

/**
 * CircularBuffer - fixed-size buffer that overwrites oldest entries
 * Useful for latency samples, timestamps, etc.
 */
export class CircularBuffer<T> {
  private buffer: T[];
  private head = 0;
  private count = 0;
  private capacity: number;

  constructor(capacity: number) {
    this.capacity = capacity;
    this.buffer = new Array(capacity);
  }

  push(item: T): void {
    this.buffer[this.head] = item;
    this.head = (this.head + 1) % this.capacity;
    if (this.count < this.capacity) this.count++;
  }

  toArray(): T[] {
    if (this.count === 0) return [];
    if (this.count < this.capacity) {
      return this.buffer.slice(0, this.count);
    }
    // Buffer is full, need to reorder from oldest to newest
    return [...this.buffer.slice(this.head), ...this.buffer.slice(0, this.head)];
  }

  get length(): number {
    return this.count;
  }

  clear(): void {
    this.head = 0;
    this.count = 0;
  }

  /** Get items newer than the given threshold (for timestamp buffers) */
  filterRecent(threshold: T, compare: (a: T, b: T) => number): T[] {
    return this.toArray().filter(item => compare(item, threshold) > 0);
  }

  /** Calculate average of numeric buffer (avoids allocation of intermediate array) */
  average(this: CircularBuffer<number>): number {
    if (this.count === 0) return 0;
    let sum = 0;
    for (let i = 0; i < this.count; i++) {
      const idx = (this.head - this.count + i + this.capacity) % this.capacity;
      sum += this.buffer[idx];
    }
    return sum / this.count;
  }
}

// ============================================================================
// CRC32 / ZIP utilities
// ============================================================================

const CRC32_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let c = i;
  for (let j = 0; j < 8; j++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
  CRC32_TABLE[i] = c;
}

export function crc32(data: Uint8Array): number {
  let crc = ~0;
  for (let i = 0; i < data.length; i++) {
    crc = CRC32_TABLE[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
  }
  return ~crc >>> 0;
}

/** Create a ZIP file from a map of path → data entries (stored, no compression). */
export function createZip(files: Map<string, Uint8Array>): Uint8Array {
  const encoder = new TextEncoder();
  const entries: Array<{ name: Uint8Array; data: Uint8Array; crc: number; offset: number }> = [];

  // Calculate total size
  let totalSize = 22; // end of central directory
  for (const [name, data] of files) {
    const nameBytes = encoder.encode(name);
    totalSize += 30 + nameBytes.length + data.length; // local header + data
    totalSize += 46 + nameBytes.length; // central directory entry
  }

  const zip = new Uint8Array(totalSize);
  const view = new DataView(zip.buffer);
  let pos = 0;

  // Write local file headers + data
  for (const [name, data] of files) {
    const nameBytes = encoder.encode(name);
    const fileCrc = crc32(data);
    const localOffset = pos;

    // Local file header signature
    view.setUint32(pos, 0x04034b50, true); pos += 4;
    view.setUint16(pos, 20, true); pos += 2;   // version needed
    view.setUint16(pos, 0, true); pos += 2;    // flags
    view.setUint16(pos, 0, true); pos += 2;    // compression: stored
    view.setUint16(pos, 0, true); pos += 2;    // mod time
    view.setUint16(pos, 0, true); pos += 2;    // mod date
    view.setUint32(pos, fileCrc, true); pos += 4;
    view.setUint32(pos, data.length, true); pos += 4; // compressed size
    view.setUint32(pos, data.length, true); pos += 4; // uncompressed size
    view.setUint16(pos, nameBytes.length, true); pos += 2;
    view.setUint16(pos, 0, true); pos += 2;    // extra field length
    zip.set(nameBytes, pos); pos += nameBytes.length;
    zip.set(data, pos); pos += data.length;

    entries.push({ name: nameBytes, data, crc: fileCrc, offset: localOffset });
  }

  // Write central directory
  const centralDirOffset = pos;
  for (const entry of entries) {
    view.setUint32(pos, 0x02014b50, true); pos += 4; // signature
    view.setUint16(pos, 20, true); pos += 2;   // version made by
    view.setUint16(pos, 20, true); pos += 2;   // version needed
    view.setUint16(pos, 0, true); pos += 2;    // flags
    view.setUint16(pos, 0, true); pos += 2;    // compression
    view.setUint16(pos, 0, true); pos += 2;    // mod time
    view.setUint16(pos, 0, true); pos += 2;    // mod date
    view.setUint32(pos, entry.crc, true); pos += 4;
    view.setUint32(pos, entry.data.length, true); pos += 4;
    view.setUint32(pos, entry.data.length, true); pos += 4;
    view.setUint16(pos, entry.name.length, true); pos += 2;
    view.setUint16(pos, 0, true); pos += 2;    // extra field length
    view.setUint16(pos, 0, true); pos += 2;    // file comment length
    view.setUint16(pos, 0, true); pos += 2;    // disk number
    view.setUint16(pos, 0, true); pos += 2;    // internal attrs
    view.setUint32(pos, 0, true); pos += 4;    // external attrs
    view.setUint32(pos, entry.offset, true); pos += 4;
    zip.set(entry.name, pos); pos += entry.name.length;
  }
  const centralDirSize = pos - centralDirOffset;

  // End of central directory
  view.setUint32(pos, 0x06054b50, true); pos += 4;
  view.setUint16(pos, 0, true); pos += 2;      // disk number
  view.setUint16(pos, 0, true); pos += 2;      // central dir disk
  view.setUint16(pos, entries.length, true); pos += 2;
  view.setUint16(pos, entries.length, true); pos += 2;
  view.setUint32(pos, centralDirSize, true); pos += 4;
  view.setUint32(pos, centralDirOffset, true); pos += 4;
  view.setUint16(pos, 0, true); pos += 2;      // comment length

  return zip.slice(0, pos);
}

// ============================================================================
// Stream utilities
// ============================================================================
