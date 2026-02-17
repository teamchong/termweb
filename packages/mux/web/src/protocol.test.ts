import { describe, it, expect } from 'vitest';
import { ClientMsg, FrameType, BinaryCtrlMsg, ServerCtrlMsg, TransferMsgType, Role } from './protocol';

// Verify no duplicate message type values within each enum
function checkNoDuplicateValues(name: string, obj: Record<string, number>) {
  const values = Object.values(obj);
  const unique = new Set(values);
  it(`${name} has no duplicate values`, () => {
    expect(unique.size).toBe(values.length);
  });
}

// Verify all values are within byte range
function checkByteRange(name: string, obj: Record<string, number>) {
  for (const [key, value] of Object.entries(obj)) {
    it(`${name}.${key} (0x${value.toString(16)}) fits in a byte`, () => {
      expect(value).toBeGreaterThanOrEqual(0);
      expect(value).toBeLessThanOrEqual(0xff);
    });
  }
}

describe('ClientMsg', () => {
  checkNoDuplicateValues('ClientMsg', ClientMsg);
  checkByteRange('ClientMsg', ClientMsg);
});

describe('FrameType', () => {
  checkNoDuplicateValues('FrameType', FrameType);
  checkByteRange('FrameType', FrameType);
});

describe('BinaryCtrlMsg', () => {
  checkNoDuplicateValues('BinaryCtrlMsg', BinaryCtrlMsg);
  checkByteRange('BinaryCtrlMsg', BinaryCtrlMsg);

  it('all control messages have high bit set (0x80+)', () => {
    for (const [key, value] of Object.entries(BinaryCtrlMsg)) {
      expect(value, `${key} should be >= 0x80`).toBeGreaterThanOrEqual(0x80);
    }
  });
});

describe('ServerCtrlMsg', () => {
  checkNoDuplicateValues('ServerCtrlMsg', ServerCtrlMsg);
  checkByteRange('ServerCtrlMsg', ServerCtrlMsg);
});

describe('TransferMsgType', () => {
  checkNoDuplicateValues('TransferMsgType', TransferMsgType);
  checkByteRange('TransferMsgType', TransferMsgType);

  it('client->server transfer messages are in 0x20-0x2F range', () => {
    const clientMsgs = ['TRANSFER_INIT', 'FILE_LIST_REQUEST', 'FILE_DATA', 'TRANSFER_RESUME', 'TRANSFER_CANCEL', 'UPLOAD_FILE_LIST', 'SYNC_REQUEST', 'BLOCK_CHECKSUMS', 'SYNC_ACK'];
    for (const key of clientMsgs) {
      const val = TransferMsgType[key as keyof typeof TransferMsgType];
      expect(val, `${key}`).toBeGreaterThanOrEqual(0x20);
      expect(val, `${key}`).toBeLessThanOrEqual(0x2f);
    }
  });

  it('server->client transfer messages are in 0x30-0x3F range', () => {
    const serverMsgs = ['TRANSFER_READY', 'FILE_LIST', 'FILE_REQUEST', 'FILE_ACK', 'TRANSFER_COMPLETE', 'TRANSFER_ERROR', 'DRY_RUN_REPORT', 'BATCH_DATA', 'SYNC_FILE_LIST', 'DELTA_DATA', 'SYNC_COMPLETE'];
    for (const key of serverMsgs) {
      const val = TransferMsgType[key as keyof typeof TransferMsgType];
      expect(val, `${key}`).toBeGreaterThanOrEqual(0x30);
      expect(val, `${key}`).toBeLessThanOrEqual(0x3f);
    }
  });
});

describe('Role', () => {
  it('has expected role values', () => {
    expect(Role.ADMIN).toBe(0);
    expect(Role.EDITOR).toBe(1);
    expect(Role.VIEWER).toBe(2);
    expect(Role.NONE).toBe(255);
  });

  it('roles are ordered by privilege level', () => {
    expect(Role.ADMIN).toBeLessThan(Role.EDITOR);
    expect(Role.EDITOR).toBeLessThan(Role.VIEWER);
    expect(Role.VIEWER).toBeLessThan(Role.NONE);
  });
});

// Cross-enum: no collisions between ClientMsg and BinaryCtrlMsg
// (they share the same WS but must not overlap)
describe('Cross-enum uniqueness', () => {
  it('ClientMsg and BinaryCtrlMsg have no overlapping values', () => {
    const clientVals = new Set(Object.values(ClientMsg));
    for (const val of Object.values(BinaryCtrlMsg)) {
      expect(clientVals.has(val), `0x${val.toString(16)} appears in both ClientMsg and BinaryCtrlMsg`).toBe(false);
    }
  });
});
