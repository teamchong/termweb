// Centralized constants for the termweb-mux web client
// This file consolidates magic values scattered throughout the codebase

// ============================================================================
// WebSocket Configuration
// ============================================================================

export const WS_PATHS = {
  CONTROL: '/ws/control',
  PANEL: '/ws/panel',
  FILE: '/ws/file',
  PREVIEW: '/ws/preview',
} as const;

export const CONFIG_ENDPOINT = '/config';

// ============================================================================
// Timing Constants (milliseconds)
// ============================================================================

export const TIMING = {
  /** WebSocket reconnection delay */
  WS_RECONNECT_DELAY: 1000,
  /** Initial reconnection delay for exponential backoff */
  WS_RECONNECT_INITIAL: 1000,
  /** Maximum reconnection delay */
  WS_RECONNECT_MAX: 30000,
  /** Bell flash duration */
  BELL_FLASH_DURATION: 150,
  /** Stats overlay update interval */
  STATS_UPDATE_INTERVAL: 500,
  /** Buffer stats report interval */
  BUFFER_STATS_INTERVAL: 1000,
  /** FPS calculation window */
  FPS_CALCULATION_WINDOW: 1000,
  /** Clipboard copy flash duration */
  CLIPBOARD_FLASH_DURATION: 500,
} as const;

// ============================================================================
// Panel Configuration
// ============================================================================

export const PANEL = {
  /** Default panel width if measurement fails */
  DEFAULT_WIDTH: 800,
  /** Default panel height if measurement fails */
  DEFAULT_HEIGHT: 600,
  /** Default inspector height in pixels */
  DEFAULT_INSPECTOR_HEIGHT: 200,
  /** Minimum inspector height in pixels */
  MIN_INSPECTOR_HEIGHT: 100,
  /** Maximum inspector height as ratio of panel height */
  MAX_INSPECTOR_HEIGHT_RATIO: 0.6,
  /** Canvas tabIndex for focus */
  CANVAS_TAB_INDEX: 1,
  /** Default H.264 codec string (baseline profile 3.1) */
  DEFAULT_H264_CODEC: 'avc1.42E01F',
  /** Assumed FPS for timestamp calculation */
  ASSUMED_FPS: 30,
  /** Maximum latency samples to keep */
  MAX_LATENCY_SAMPLES: 30,
  /** Maximum buffer health value */
  MAX_BUFFER_HEALTH: 100,
  /** Health penalty per pending decode frame */
  HEALTH_PENALTY_PER_PENDING: 20,
  /** Approximate frame duration in ms */
  APPROX_FRAME_DURATION_MS: 33,
  /** Wheel deltaMode=1 (line) multiplier */
  LINE_SCROLL_MULTIPLIER: 20,
} as const;

// ============================================================================
// Split Container Configuration
// ============================================================================

export const SPLIT = {
  /** Divider size in pixels */
  DIVIDER_SIZE: 4,
  /** Minimum split ratio */
  MIN_RATIO: 0.1,
  /** Maximum split ratio */
  MAX_RATIO: 0.9,
  /** Default split ratio */
  DEFAULT_RATIO: 0.5,
  /** Weight for perpendicular distance in direction calculation */
  PERPENDICULAR_WEIGHT: 0.5,
} as const;

// ============================================================================
// File Transfer Configuration
// ============================================================================

export const FILE_TRANSFER = {
  /** Chunk size in bytes (256KB) */
  CHUNK_SIZE: 256 * 1024,
  /** Default compression level for zstd */
  COMPRESSION_LEVEL: 3,
  /** Maximum decompressed size for zstd (16MB) */
  MAX_DECOMPRESSED_SIZE: 16 * 1024 * 1024,
  /** Compress bound constant for zstd */
  COMPRESS_BOUND_CONSTANT: 512,
} as const;

// ============================================================================
// File Transfer Protocol Offsets
// ============================================================================

/** Field sizes in bytes for binary protocol */
export const PROTO_SIZE = {
  MSG_TYPE: 1,
  UINT32: 4,
  UINT64: 8,
  UINT16: 2,
  UINT8: 1,
} as const;

/** Common header: all messages start with msg_type (1 byte) + transfer_id (4 bytes) */
export const PROTO_HEADER = {
  /** Offset of transfer ID (after msg type) */
  TRANSFER_ID: 1,
  /** Total header size before payload */
  SIZE: 5,
} as const;

/** FILE_LIST message offsets (after PROTO_HEADER.TRANSFER_ID) */
export const PROTO_FILE_LIST = {
  FILE_COUNT: 5,
  TOTAL_BYTES: 9,
  PAYLOAD: 17,
} as const;

/** FILE_REQUEST message offsets */
export const PROTO_FILE_REQUEST = {
  FILE_INDEX: 5,
  CHUNK_OFFSET: 9,
  UNCOMPRESSED_SIZE: 17,
  DATA: 21,
} as const;

/** FILE_ACK message offsets */
export const PROTO_FILE_ACK = {
  BYTES_RECEIVED: 9,
} as const;

/** TRANSFER_COMPLETE message offsets */
export const PROTO_TRANSFER_COMPLETE = {
  TOTAL_BYTES: 5,
} as const;

/** TRANSFER_ERROR message offsets */
export const PROTO_TRANSFER_ERROR = {
  ERROR_LEN: 5,
  ERROR_MSG: 7,
} as const;

/** DRY_RUN_REPORT message offsets */
export const PROTO_DRY_RUN = {
  NEW_COUNT: 5,
  UPDATE_COUNT: 9,
  DELETE_COUNT: 13,
  ENTRIES: 17,
} as const;

/** Action codes for dry run entries */
export const DRY_RUN_ACTION = ['create', 'update', 'delete'] as const;

// ============================================================================
// Byte Size Constants
// ============================================================================

export const BYTES = {
  KB: 1024,
  MB: 1024 * 1024,
  GB: 1024 * 1024 * 1024,
} as const;

// ============================================================================
// Color Constants
// ============================================================================

export const COLORS = {
  /** Default background color */
  DEFAULT_BACKGROUND: '#282c34',
  /** Default foreground color */
  DEFAULT_FOREGROUND: '#ffffff',
  /** Luminance threshold for light color detection */
  LUMINANCE_LIGHT_THRESHOLD: 0.5,
  /** Luminance threshold for very dark color detection */
  LUMINANCE_VERY_DARK_THRESHOLD: 0.05,
  /** Number of palette colors */
  PALETTE_COUNT: 16,
} as const;

// ============================================================================
// UI Constants
// ============================================================================

export const UI = {
  /** Default tab title - empty, will be set by shell's title */
  DEFAULT_TAB_TITLE: 'zsh',
  /** Loading text */
  LOADING_TEXT: 'Connecting...',
  /** Default inspector tab */
  DEFAULT_INSPECTOR_TAB: 'screen',
} as const;

// ============================================================================
// ID Generation
// ============================================================================

export const ID_GENERATION = {
  /** Radix for random ID (base 36 = alphanumeric) */
  RADIX: 36,
  /** Start index for substring */
  START: 2,
  /** Length of generated ID */
  LENGTH: 7,
} as const;

// ============================================================================
// Binary Message Types (Server -> Client on Control WS)
// ============================================================================

export const SERVER_MSG = {
  /** Panel list with layout */
  PANEL_LIST: 0x01,
  /** New panel created */
  PANEL_CREATED: 0x02,
  /** Panel closed */
  PANEL_CLOSED: 0x03,
  /** Panel title changed */
  PANEL_TITLE: 0x04,
  /** Panel working directory changed */
  PANEL_PWD: 0x05,
  /** Panel bell triggered */
  PANEL_BELL: 0x06,
  /** Layout update from server */
  LAYOUT_UPDATE: 0x07,
  /** Clipboard data from terminal */
  CLIPBOARD: 0x08,
  /** Authentication state */
  AUTH_STATE: 0x0A,
  /** Overview open/closed state */
  OVERVIEW_STATE: 0x0E,
  /** Quick terminal open/closed state */
  QUICK_TERMINAL_STATE: 0x0F,
  /** Main client election state */
  MAIN_CLIENT_STATE: 0x10,
  /** Multiplayer: panel assignment change */
  PANEL_ASSIGNMENT: 0x11,
  /** Multiplayer: connected clients list (admin only) */
  CLIENT_LIST: 0x12,
  /** Multiplayer: your session identity */
  SESSION_IDENTITY: 0x13,
} as const;

// ============================================================================
// H.264 NAL Unit Types
// ============================================================================

export const NAL = {
  /** Sequence Parameter Set */
  TYPE_SPS: 7,
  /** Picture Parameter Set */
  TYPE_PPS: 8,
  /** IDR (Instantaneous Decoder Refresh) - keyframe */
  TYPE_IDR: 5,
  /** Mask for NAL unit type (lower 5 bits) */
  TYPE_MASK: 0x1f,
  /** Start code prefix length */
  START_CODE_LENGTH: 4,
} as const;

// ============================================================================
// Input Modifier Flags
// ============================================================================

export const MODIFIER = {
  /** Shift key modifier */
  SHIFT: 1,
  /** Control key modifier */
  CTRL: 2,
  /** Alt/Option key modifier */
  ALT: 4,
  /** Meta/Command key modifier */
  META: 8,
} as const;

// ============================================================================
// Wheel Delta Modes
// ============================================================================

export const WHEEL_MODE = {
  /** Pixel mode (default) */
  PIXEL: 0,
  /** Line mode */
  LINE: 1,
  /** Page mode */
  PAGE: 2,
} as const;

// ============================================================================
// Stats Display Thresholds
// ============================================================================

export const STATS_THRESHOLD = {
  /** FPS considered good (green) */
  FPS_GOOD: 25,
  /** FPS considered warning (yellow) */
  FPS_WARN: 15,
  /** Buffer health considered good (green) */
  HEALTH_GOOD: 80,
  /** Buffer health considered warning (yellow) */
  HEALTH_WARN: 40,
  /** Pending queue considered good (green) */
  QUEUE_GOOD: 1,
  /** Pending queue considered warning (yellow) */
  QUEUE_WARN: 3,
} as const;
