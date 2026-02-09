// Protocol types and constants (must match server)

export const ClientMsg = {
  KEY_INPUT: 0x01,
  MOUSE_INPUT: 0x02,
  MOUSE_MOVE: 0x03,
  MOUSE_SCROLL: 0x04,
  TEXT_INPUT: 0x05,
  RESIZE: 0x10,
  REQUEST_KEYFRAME: 0x11,
  PAUSE_STREAM: 0x12,
  RESUME_STREAM: 0x13,
  BUFFER_STATS: 0x14, // Client reports buffer health for adaptive bitrate
  CREATE_PANEL: 0x21,
  SPLIT_PANEL: 0x22, // Create panel as split of existing panel (via PANEL_MSG envelope on control WS)
  INSPECTOR_SUBSCRIBE: 0x30,   // Subscribe to inspector: [msg_type:u8][tab_len:u8][tab:...]
  INSPECTOR_UNSUBSCRIBE: 0x31, // Unsubscribe from inspector: [msg_type:u8]
} as const;

export const FrameType = {
  KEYFRAME: 0x01,
  DELTA: 0x02,
} as const;

// Binary control message types (client -> server)
export const BinaryCtrlMsg = {
  CLOSE_PANEL: 0x81,
  RESIZE_PANEL: 0x82,
  FOCUS_PANEL: 0x83,
  VIEW_ACTION: 0x88,
  SET_OVERVIEW: 0x89,  // Set overview open/closed state
  SET_QUICK_TERMINAL: 0x8A,  // Set quick terminal open/closed state
  SET_CLIPBOARD: 0x8C,  // Send clipboard text to server: [panel_id:u32][len:u32][text...]
  // Multiplayer messages
  ASSIGN_PANEL: 0x84,     // Admin assigns panel to session: [panel_id:u32][session_id_len:u8][session_id:...]
  UNASSIGN_PANEL: 0x85,   // Admin unassigns panel: [panel_id:u32]
  PANEL_INPUT: 0x86,      // Coworker input to assigned panel: [panel_id:u32][input_msg...]
  PANEL_MSG: 0x87,        // Panel message envelope: [type:u8][panel_id:u32][inner_msg...] — routes panel input through zstd WS
  SET_INSPECTOR: 0x8B,    // Set inspector open/closed state: [type:u8][open:u8]
  // Auth messages
  GET_AUTH_STATE: 0x90,
  SET_PASSWORD: 0x91,
  VERIFY_PASSWORD: 0x92,
  CLEAR_PASSWORD: 0x93,
  CREATE_SESSION: 0x94,
  DELETE_SESSION: 0x95,
  REGEN_TOKEN: 0x96,
  CREATE_SHARE_LINK: 0x97,
  REVOKE_SHARE_LINK: 0x98,
  GET_SESSION_LIST: 0x99,
  GET_SHARE_LINKS: 0x9A,
} as const;

// Server -> client auth response types
export const AuthResponseType = {
  AUTH_STATE: 0x0A,
  SESSION_LIST: 0x0B,
  SHARE_LINKS: 0x0C,
} as const;

// Server -> client control message types
export const ServerCtrlMsg = {
  OVERVIEW_STATE: 0x0E,  // Overview open/closed state
  QUICK_TERMINAL_STATE: 0x0F,  // Quick terminal open/closed state
  MAIN_CLIENT_STATE: 0x10,  // Main client election: [type:u8][is_main:u8][client_id:u32]
  INSPECTOR_OPEN_STATE: 0x1E,  // Inspector open/closed state
} as const;

// Transfer protocol message types
export const TransferMsgType = {
  // Client -> Server
  TRANSFER_INIT: 0x20,
  FILE_LIST_REQUEST: 0x21,
  FILE_DATA: 0x22,
  TRANSFER_RESUME: 0x23,
  TRANSFER_CANCEL: 0x24,
  // Server -> Client
  TRANSFER_READY: 0x30,
  FILE_LIST: 0x31,
  FILE_REQUEST: 0x32,
  FILE_ACK: 0x33,
  TRANSFER_COMPLETE: 0x34,
  TRANSFER_ERROR: 0x35,
  DRY_RUN_REPORT: 0x36,
  BATCH_DATA: 0x37,
} as const;

// Role constants
export const Role = {
  ADMIN: 0,
  EDITOR: 1,
  VIEWER: 2,
  NONE: 255,
} as const;

export type RoleType = typeof Role[keyof typeof Role];

// Server configuration (path-based WebSocket)
export interface ServerConfig {
  wsPath?: boolean; // True if using path-based WebSocket on same port
  colors?: Record<string, string>;
}

// Key mapping for ghostty
export const KEY_MAP: Record<string, number> = {
  'KeyA': 0x00, 'KeyS': 0x01, 'KeyD': 0x02, 'KeyF': 0x03,
  'KeyH': 0x04, 'KeyG': 0x05, 'KeyZ': 0x06, 'KeyX': 0x07,
  'KeyC': 0x08, 'KeyV': 0x09, 'IntlBackslash': 0x0a, 'KeyB': 0x0b,
  'KeyQ': 0x0c, 'KeyW': 0x0d, 'KeyE': 0x0e, 'KeyR': 0x0f,
  'KeyY': 0x10, 'KeyT': 0x11, 'Digit1': 0x12, 'Digit2': 0x13,
  'Digit3': 0x14, 'Digit4': 0x15, 'Digit6': 0x16, 'Digit5': 0x17,
  'Equal': 0x18, 'Digit9': 0x19, 'Digit7': 0x1a, 'Minus': 0x1b,
  'Digit8': 0x1c, 'Digit0': 0x1d, 'BracketRight': 0x1e, 'KeyO': 0x1f,
  'KeyU': 0x20, 'BracketLeft': 0x21, 'KeyI': 0x22, 'KeyP': 0x23,
  'Enter': 0x24, 'KeyL': 0x25, 'KeyJ': 0x26, 'Quote': 0x27,
  'KeyK': 0x28, 'Semicolon': 0x29, 'Backslash': 0x2a, 'Comma': 0x2b,
  'Slash': 0x2c, 'KeyN': 0x2d, 'KeyM': 0x2e, 'Period': 0x2f,
  'Tab': 0x30, 'Space': 0x31, 'Backquote': 0x32, 'Backspace': 0x33,
  'Escape': 0x35, 'MetaRight': 0x36, 'MetaLeft': 0x37, 'ShiftLeft': 0x38,
  'CapsLock': 0x39, 'AltLeft': 0x3a, 'ControlLeft': 0x3b, 'ShiftRight': 0x3c,
  'AltRight': 0x3d, 'ControlRight': 0x3e,
  'F17': 0x40, 'NumpadDecimal': 0x41, 'NumpadMultiply': 0x43, 'NumpadAdd': 0x45,
  'NumLock': 0x47, 'NumpadDivide': 0x4b, 'NumpadEnter': 0x4c,
  'NumpadSubtract': 0x4e, 'F18': 0x4f, 'F19': 0x50, 'NumpadEqual': 0x51,
  'Numpad0': 0x52, 'Numpad1': 0x53, 'Numpad2': 0x54, 'Numpad3': 0x55,
  'Numpad4': 0x56, 'Numpad5': 0x57, 'Numpad6': 0x58, 'Numpad7': 0x59,
  'F20': 0x5a, 'Numpad8': 0x5b, 'Numpad9': 0x5c,
  'IntlYen': 0x5d, 'IntlRo': 0x5e,
  'F5': 0x60, 'F6': 0x61, 'F7': 0x62, 'F3': 0x63, 'F8': 0x64,
  'F9': 0x65, 'F11': 0x67, 'F13': 0x69, 'F16': 0x6a,
  'F14': 0x6b, 'F10': 0x6d, 'F12': 0x6f, 'F15': 0x71,
  'Home': 0x73, 'PageUp': 0x74, 'Delete': 0x75, 'F4': 0x76,
  'End': 0x77, 'F2': 0x78, 'PageDown': 0x79, 'F1': 0x7a,
  'ArrowLeft': 0x7b, 'ArrowRight': 0x7c, 'ArrowDown': 0x7d, 'ArrowUp': 0x7e,
};
