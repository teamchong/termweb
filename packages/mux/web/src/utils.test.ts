import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  hexToRgb,
  rgbToHex,
  luminance,
  isLightColor,
  isVeryDark,
  highlightColor,
  shadowColor,
  formatBytes,
  generateId,
  debounce,
  throttle,
  crc32,
  createZip,
  BinaryReader,
  CircularBuffer,
} from './utils';

// Color utilities

describe('hexToRgb', () => {
  it('parses 6-digit hex with #', () => {
    expect(hexToRgb('#ff0000')).toEqual({ r: 255, g: 0, b: 0 });
  });
  it('parses 6-digit hex without #', () => {
    expect(hexToRgb('00ff00')).toEqual({ r: 0, g: 255, b: 0 });
  });
  it('is case-insensitive', () => {
    expect(hexToRgb('#AABBCC')).toEqual({ r: 170, g: 187, b: 204 });
  });
  it('returns null for invalid input', () => {
    expect(hexToRgb('xyz')).toBeNull();
    expect(hexToRgb('#ff')).toBeNull();
    expect(hexToRgb('')).toBeNull();
  });
});

describe('rgbToHex', () => {
  it('converts RGB to hex', () => {
    expect(rgbToHex(255, 0, 0)).toBe('#ff0000');
    expect(rgbToHex(0, 255, 0)).toBe('#00ff00');
    expect(rgbToHex(0, 0, 255)).toBe('#0000ff');
  });
  it('clamps out-of-range values', () => {
    expect(rgbToHex(300, -10, 128)).toBe('#ff0080');
  });
  it('rounds fractional values', () => {
    expect(rgbToHex(127.6, 0, 0)).toBe('#800000');
  });
});

describe('luminance', () => {
  it('returns ~1 for white', () => {
    expect(luminance('#ffffff')).toBeCloseTo(1.0, 2);
  });
  it('returns 0 for black', () => {
    expect(luminance('#000000')).toBeCloseTo(0, 2);
  });
  it('returns 0 for invalid hex', () => {
    expect(luminance('invalid')).toBe(0);
  });
});

describe('isLightColor / isVeryDark', () => {
  it('white is light', () => {
    expect(isLightColor('#ffffff')).toBe(true);
  });
  it('black is not light', () => {
    expect(isLightColor('#000000')).toBe(false);
  });
  it('black is very dark', () => {
    expect(isVeryDark('#000000')).toBe(true);
  });
  it('white is not very dark', () => {
    expect(isVeryDark('#ffffff')).toBe(false);
  });
});

describe('highlightColor', () => {
  it('level 0 returns original color', () => {
    expect(highlightColor('#804020', 0)).toBe('#804020');
  });
  it('level 1 returns white', () => {
    expect(highlightColor('#804020', 1)).toBe('#ffffff');
  });
  it('returns original for invalid hex', () => {
    expect(highlightColor('bad', 0.5)).toBe('bad');
  });
});

describe('shadowColor', () => {
  it('level 0 returns original color', () => {
    expect(shadowColor('#804020', 0)).toBe('#804020');
  });
  it('level 1 returns black', () => {
    expect(shadowColor('#804020', 1)).toBe('#000000');
  });
  it('returns original for invalid hex', () => {
    expect(shadowColor('bad', 0.5)).toBe('bad');
  });
});

// Byte utilities

describe('formatBytes', () => {
  it('formats bytes', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(512)).toBe('512 B');
  });
  it('formats kilobytes', () => {
    expect(formatBytes(1024)).toBe('1.0 KB');
    expect(formatBytes(1536)).toBe('1.5 KB');
  });
  it('formats megabytes', () => {
    expect(formatBytes(1048576)).toBe('1.0 MB');
  });
  it('formats gigabytes', () => {
    expect(formatBytes(1073741824)).toBe('1.00 GB');
  });
});

describe('generateId', () => {
  it('returns a 7-character string', () => {
    const id = generateId();
    expect(id.length).toBe(7);
  });
  it('returns alphanumeric characters', () => {
    const id = generateId();
    expect(id).toMatch(/^[a-z0-9]+$/);
  });
  it('generates unique IDs', () => {
    const ids = new Set(Array.from({ length: 100 }, () => generateId()));
    expect(ids.size).toBe(100);
  });
});

// Debounce / Throttle

describe('debounce', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('delays execution', () => {
    const fn = vi.fn();
    const debounced = debounce(fn, 100);
    debounced();
    expect(fn).not.toHaveBeenCalled();
    vi.advanceTimersByTime(100);
    expect(fn).toHaveBeenCalledOnce();
  });

  it('resets timer on subsequent calls', () => {
    const fn = vi.fn();
    const debounced = debounce(fn, 100);
    debounced();
    vi.advanceTimersByTime(50);
    debounced();
    vi.advanceTimersByTime(50);
    expect(fn).not.toHaveBeenCalled();
    vi.advanceTimersByTime(50);
    expect(fn).toHaveBeenCalledOnce();
  });
});

describe('throttle', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('fires immediately on first call (leading edge)', () => {
    const fn = vi.fn();
    const throttled = throttle(fn, 100);
    throttled();
    expect(fn).toHaveBeenCalledOnce();
  });

  it('fires trailing edge with latest args', () => {
    const fn = vi.fn();
    const throttled = throttle(fn, 100);
    throttled(1 as never);
    throttled(2 as never);
    throttled(3 as never);
    expect(fn).toHaveBeenCalledOnce(); // leading
    vi.advanceTimersByTime(100);
    expect(fn).toHaveBeenCalledTimes(2); // trailing with last args
    expect(fn).toHaveBeenLastCalledWith(3);
  });

  it('allows new leading call after window expires', () => {
    const fn = vi.fn();
    const throttled = throttle(fn, 100);
    throttled();
    vi.advanceTimersByTime(100);
    throttled();
    expect(fn).toHaveBeenCalledTimes(2);
  });
});

// BinaryReader

describe('BinaryReader', () => {
  function makeBuffer(...bytes: number[]): ArrayBuffer {
    return new Uint8Array(bytes).buffer;
  }

  it('reads u8', () => {
    const reader = new BinaryReader(makeBuffer(0x42));
    expect(reader.readU8()).toBe(0x42);
    expect(reader.remaining).toBe(0);
  });

  it('reads u16 little-endian', () => {
    const reader = new BinaryReader(makeBuffer(0x34, 0x12));
    expect(reader.readU16()).toBe(0x1234);
  });

  it('reads u32 little-endian', () => {
    const reader = new BinaryReader(makeBuffer(0x78, 0x56, 0x34, 0x12));
    expect(reader.readU32()).toBe(0x12345678);
  });

  it('reads string', () => {
    const encoded = new TextEncoder().encode('hello');
    const reader = new BinaryReader(encoded.buffer);
    expect(reader.readString(5)).toBe('hello');
  });

  it('reads length-prefixed string (2-byte)', () => {
    const text = new TextEncoder().encode('hi');
    const buf = new Uint8Array(2 + text.length);
    new DataView(buf.buffer).setUint16(0, text.length, true);
    buf.set(text, 2);
    const reader = new BinaryReader(buf.buffer);
    expect(reader.readLengthPrefixedString()).toBe('hi');
  });

  it('throws on overflow', () => {
    const reader = new BinaryReader(makeBuffer(0x01));
    reader.readU8();
    expect(() => reader.readU8()).toThrow('Buffer overflow');
  });

  it('tracks offset correctly', () => {
    const reader = new BinaryReader(makeBuffer(1, 2, 3, 4, 5));
    expect(reader.offset).toBe(0);
    reader.readU8();
    expect(reader.offset).toBe(1);
    reader.skip(2);
    expect(reader.offset).toBe(3);
    expect(reader.remaining).toBe(2);
  });

  it('supports startOffset', () => {
    const reader = new BinaryReader(makeBuffer(0xAA, 0xBB, 0xCC), 1);
    expect(reader.readU8()).toBe(0xBB);
  });
});

// CircularBuffer

describe('CircularBuffer', () => {
  it('stores and retrieves items', () => {
    const buf = new CircularBuffer<number>(3);
    buf.push(1);
    buf.push(2);
    expect(buf.toArray()).toEqual([1, 2]);
    expect(buf.length).toBe(2);
  });

  it('overwrites oldest when full', () => {
    const buf = new CircularBuffer<number>(3);
    buf.push(1);
    buf.push(2);
    buf.push(3);
    buf.push(4);
    expect(buf.toArray()).toEqual([2, 3, 4]);
    expect(buf.length).toBe(3);
  });

  it('handles wrapping correctly', () => {
    const buf = new CircularBuffer<number>(3);
    buf.push(1); buf.push(2); buf.push(3);
    buf.push(4); buf.push(5);
    expect(buf.toArray()).toEqual([3, 4, 5]);
  });

  it('clears properly', () => {
    const buf = new CircularBuffer<number>(3);
    buf.push(1); buf.push(2);
    buf.clear();
    expect(buf.length).toBe(0);
    expect(buf.toArray()).toEqual([]);
  });

  it('calculates average', () => {
    const buf = new CircularBuffer<number>(5);
    buf.push(10); buf.push(20); buf.push(30);
    expect(buf.average()).toBe(20);
  });

  it('returns 0 average for empty buffer', () => {
    const buf = new CircularBuffer<number>(5);
    expect(buf.average()).toBe(0);
  });

  it('filterRecent returns items above threshold', () => {
    const buf = new CircularBuffer<number>(5);
    buf.push(1); buf.push(5); buf.push(3); buf.push(7);
    const recent = buf.filterRecent(4, (a, b) => a - b);
    expect(recent).toEqual([5, 7]);
  });
});

// CRC32

describe('crc32', () => {
  it('computes correct CRC32 for known input', () => {
    const data = new TextEncoder().encode('hello');
    // Known CRC32 of "hello" = 0x3610A686
    expect(crc32(data)).toBe(0x3610A686);
  });

  it('returns 0 for empty input', () => {
    expect(crc32(new Uint8Array(0))).toBe(0);
  });
});

// createZip

describe('createZip', () => {
  it('creates valid ZIP with local file header signature', () => {
    const files = new Map<string, Uint8Array>();
    files.set('test.txt', new TextEncoder().encode('hello world'));
    const zip = createZip(files);

    // Check local file header signature (PK\x03\x04)
    const view = new DataView(zip.buffer);
    expect(view.getUint32(0, true)).toBe(0x04034b50);
  });

  it('creates ZIP with correct end-of-central-directory signature', () => {
    const files = new Map<string, Uint8Array>();
    files.set('a.txt', new TextEncoder().encode('data'));
    const zip = createZip(files);

    // Find EOCD signature (PK\x05\x06) - it's near the end
    const view = new DataView(zip.buffer);
    let found = false;
    for (let i = zip.length - 22; i >= 0; i--) {
      if (view.getUint32(i, true) === 0x06054b50) {
        found = true;
        // Check file count = 1
        expect(view.getUint16(i + 8, true)).toBe(1);
        break;
      }
    }
    expect(found).toBe(true);
  });

  it('handles multiple files', () => {
    const files = new Map<string, Uint8Array>();
    files.set('a.txt', new TextEncoder().encode('aaa'));
    files.set('b.txt', new TextEncoder().encode('bbb'));
    const zip = createZip(files);

    // Find EOCD and check file count = 2
    const view = new DataView(zip.buffer);
    for (let i = zip.length - 22; i >= 0; i--) {
      if (view.getUint32(i, true) === 0x06054b50) {
        expect(view.getUint16(i + 8, true)).toBe(2);
        break;
      }
    }
  });

  it('handles empty file map', () => {
    const zip = createZip(new Map());
    const view = new DataView(zip.buffer);
    // Should just have EOCD
    expect(view.getUint32(0, true)).toBe(0x06054b50);
  });
});
