import { describe, it, expect } from 'vitest';
import {
  TIMING, PANEL, SPLIT, FILE_TRANSFER, BYTES, COLORS,
  SERVER_MSG, NAL, MODIFIER, WHEEL_MODE, STATS_THRESHOLD,
  PROTO_SIZE, PROTO_HEADER,
} from './constants';

describe('TIMING', () => {
  it('reconnect delay is positive', () => {
    expect(TIMING.WS_RECONNECT_DELAY).toBeGreaterThan(0);
  });
  it('max reconnect exceeds initial', () => {
    expect(TIMING.WS_RECONNECT_MAX).toBeGreaterThan(TIMING.WS_RECONNECT_INITIAL);
  });
});

describe('PANEL', () => {
  it('defaults are positive', () => {
    expect(PANEL.DEFAULT_WIDTH).toBeGreaterThan(0);
    expect(PANEL.DEFAULT_HEIGHT).toBeGreaterThan(0);
  });
  it('inspector min < default', () => {
    expect(PANEL.MIN_INSPECTOR_HEIGHT).toBeLessThan(PANEL.DEFAULT_INSPECTOR_HEIGHT);
  });
  it('max inspector ratio is between 0 and 1', () => {
    expect(PANEL.MAX_INSPECTOR_HEIGHT_RATIO).toBeGreaterThan(0);
    expect(PANEL.MAX_INSPECTOR_HEIGHT_RATIO).toBeLessThan(1);
  });
});

describe('SPLIT', () => {
  it('min ratio < default < max ratio', () => {
    expect(SPLIT.MIN_RATIO).toBeLessThan(SPLIT.DEFAULT_RATIO);
    expect(SPLIT.DEFAULT_RATIO).toBeLessThan(SPLIT.MAX_RATIO);
  });
  it('min + max >= 1 (full range covered)', () => {
    expect(SPLIT.MIN_RATIO + SPLIT.MAX_RATIO).toBeGreaterThanOrEqual(1);
  });
  it('divider size is positive', () => {
    expect(SPLIT.DIVIDER_SIZE).toBeGreaterThan(0);
  });
});

describe('FILE_TRANSFER', () => {
  it('chunk size is a power of 2', () => {
    const cs = FILE_TRANSFER.CHUNK_SIZE;
    expect(cs & (cs - 1)).toBe(0);
  });
  it('batch threshold < chunk size', () => {
    expect(FILE_TRANSFER.BATCH_THRESHOLD).toBeLessThan(FILE_TRANSFER.CHUNK_SIZE);
  });
});

describe('BYTES', () => {
  it('KB < MB < GB', () => {
    expect(BYTES.KB).toBeLessThan(BYTES.MB);
    expect(BYTES.MB).toBeLessThan(BYTES.GB);
  });
  it('each is 1024x the previous', () => {
    expect(BYTES.MB).toBe(BYTES.KB * 1024);
    expect(BYTES.GB).toBe(BYTES.MB * 1024);
  });
});

describe('COLORS', () => {
  it('luminance thresholds are between 0 and 1', () => {
    expect(COLORS.LUMINANCE_LIGHT_THRESHOLD).toBeGreaterThan(0);
    expect(COLORS.LUMINANCE_LIGHT_THRESHOLD).toBeLessThan(1);
    expect(COLORS.LUMINANCE_VERY_DARK_THRESHOLD).toBeGreaterThan(0);
    expect(COLORS.LUMINANCE_VERY_DARK_THRESHOLD).toBeLessThan(1);
  });
  it('very dark < light threshold', () => {
    expect(COLORS.LUMINANCE_VERY_DARK_THRESHOLD).toBeLessThan(COLORS.LUMINANCE_LIGHT_THRESHOLD);
  });
});

describe('SERVER_MSG', () => {
  it('has no duplicate values', () => {
    const values = Object.values(SERVER_MSG);
    expect(new Set(values).size).toBe(values.length);
  });
  it('all values fit in a byte', () => {
    for (const val of Object.values(SERVER_MSG)) {
      expect(val).toBeGreaterThanOrEqual(0);
      expect(val).toBeLessThanOrEqual(0xff);
    }
  });
});

describe('NAL', () => {
  it('SPS and PPS types are correct H.264 values', () => {
    expect(NAL.TYPE_SPS).toBe(7);
    expect(NAL.TYPE_PPS).toBe(8);
    expect(NAL.TYPE_IDR).toBe(5);
  });
  it('type mask extracts lower 5 bits', () => {
    expect(NAL.TYPE_MASK).toBe(0x1f);
    expect(NAL.TYPE_SPS & NAL.TYPE_MASK).toBe(NAL.TYPE_SPS);
    expect(NAL.TYPE_PPS & NAL.TYPE_MASK).toBe(NAL.TYPE_PPS);
    expect(NAL.TYPE_IDR & NAL.TYPE_MASK).toBe(NAL.TYPE_IDR);
  });
});

describe('MODIFIER', () => {
  it('flags are distinct powers of 2', () => {
    const flags = [MODIFIER.SHIFT, MODIFIER.CTRL, MODIFIER.ALT, MODIFIER.META];
    for (const f of flags) {
      expect(f & (f - 1)).toBe(0); // power of 2
    }
    // All distinct
    expect(new Set(flags).size).toBe(4);
  });
  it('can be combined without overlap', () => {
    const all = MODIFIER.SHIFT | MODIFIER.CTRL | MODIFIER.ALT | MODIFIER.META;
    expect(all).toBe(15); // 1+2+4+8
  });
});

describe('WHEEL_MODE', () => {
  it('has expected DOM values', () => {
    expect(WHEEL_MODE.PIXEL).toBe(0);
    expect(WHEEL_MODE.LINE).toBe(1);
    expect(WHEEL_MODE.PAGE).toBe(2);
  });
});

describe('STATS_THRESHOLD', () => {
  it('good > warn for FPS', () => {
    expect(STATS_THRESHOLD.FPS_GOOD).toBeGreaterThan(STATS_THRESHOLD.FPS_WARN);
  });
  it('good < warn for latency (lower is better)', () => {
    expect(STATS_THRESHOLD.LATENCY_GOOD).toBeLessThan(STATS_THRESHOLD.LATENCY_WARN);
  });
  it('good > warn for health', () => {
    expect(STATS_THRESHOLD.HEALTH_GOOD).toBeGreaterThan(STATS_THRESHOLD.HEALTH_WARN);
  });
});

describe('PROTO_SIZE', () => {
  it('has correct standard sizes', () => {
    expect(PROTO_SIZE.MSG_TYPE).toBe(1);
    expect(PROTO_SIZE.UINT8).toBe(1);
    expect(PROTO_SIZE.UINT16).toBe(2);
    expect(PROTO_SIZE.UINT32).toBe(4);
    expect(PROTO_SIZE.UINT64).toBe(8);
  });
});

describe('PROTO_HEADER', () => {
  it('header size = msg_type + transfer_id', () => {
    expect(PROTO_HEADER.SIZE).toBe(PROTO_SIZE.MSG_TYPE + PROTO_SIZE.UINT32);
  });
  it('transfer ID offset is after msg_type', () => {
    expect(PROTO_HEADER.TRANSFER_ID).toBe(PROTO_SIZE.MSG_TYPE);
  });
});
