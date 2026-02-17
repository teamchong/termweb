import { describe, it, expect } from 'vitest';
import { formatShortcut, getCommands } from './dialogs';
import type { KeyBinding } from './types';

describe('formatShortcut', () => {
  it('formats single key', () => {
    expect(formatShortcut({ key: 'k', mods: [] })).toBe('K');
  });

  it('formats super modifier', () => {
    expect(formatShortcut({ key: 'k', mods: ['super'] })).toBe('⌘K');
  });

  it('formats multiple modifiers in correct order', () => {
    expect(formatShortcut({ key: 'd', mods: ['super', 'shift'] })).toBe('⇧⌘D');
  });

  it('formats all modifiers', () => {
    expect(formatShortcut({ key: 'a', mods: ['ctrl', 'alt', 'shift', 'super'] })).toBe('⌃⌥⇧⌘A');
  });

  it('maps special keys', () => {
    expect(formatShortcut({ key: 'enter', mods: ['super'] })).toBe('⌘↵');
    expect(formatShortcut({ key: 'arrowup', mods: ['super'] })).toBe('⌘↑');
    expect(formatShortcut({ key: 'arrowdown', mods: [] })).toBe('↓');
    expect(formatShortcut({ key: 'arrowleft', mods: [] })).toBe('←');
    expect(formatShortcut({ key: 'arrowright', mods: [] })).toBe('→');
    expect(formatShortcut({ key: 'escape', mods: [] })).toBe('Esc');
    expect(formatShortcut({ key: 'tab', mods: [] })).toBe('⇥');
    expect(formatShortcut({ key: ' ', mods: ['ctrl'] })).toBe('⌃␣');
  });
});

describe('getCommands', () => {
  it('returns cached commands with no bindings', () => {
    const commands = getCommands();
    expect(commands.length).toBeGreaterThan(0);
  });

  it('returns same array when bindings is empty', () => {
    const commands = getCommands({});
    expect(commands.length).toBeGreaterThan(0);
  });

  it('commands are sorted alphabetically by title', () => {
    const commands = getCommands();
    for (let i = 1; i < commands.length; i++) {
      expect(commands[i].title.localeCompare(commands[i - 1].title)).toBeGreaterThanOrEqual(0);
    }
  });

  it('overrides shortcuts from bindings', () => {
    const bindings: Record<string, KeyBinding> = {
      'copy_to_clipboard': { key: 'c', mods: ['super'] },
    };
    const commands = getCommands(bindings);
    const copyCmd = commands.find(c => c.action === 'copy_to_clipboard');
    expect(copyCmd?.shortcut).toBe('⌘C');
  });

  it('every command has title, action, and description', () => {
    const commands = getCommands();
    for (const cmd of commands) {
      expect(cmd.title).toBeTruthy();
      expect(cmd.action).toBeTruthy();
      expect(cmd.description).toBeTruthy();
    }
  });

  it('no duplicate action strings', () => {
    const commands = getCommands();
    const actions = commands.map(c => c.action);
    expect(new Set(actions).size).toBe(actions.length);
  });
});
