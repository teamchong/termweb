/**
 * Kitty Graphics Protocol - Display images in terminal
 *
 * Supports PNG, JPEG, and raw RGBA data.
 * Works with Kitty, Ghostty, WezTerm terminals.
 */

const fs = require('fs');
const path = require('path');

// Kitty graphics escape sequences
const ESC = '\x1b';
const APC = `${ESC}_G`;
const ST = `${ESC}\\`;

class KittyGraphics {
  constructor() {
    this._nextId = 1;
  }

  /**
   * Display an image from file
   * @param {string} filePath - Path to image file
   * @param {Object} options
   * @param {number} [options.width] - Display width in cells
   * @param {number} [options.height] - Display height in cells
   * @param {number} [options.x] - X position (column)
   * @param {number} [options.y] - Y position (row)
   * @param {number} [options.z] - Z-index for layering
   */
  async displayFile(filePath, options = {}) {
    const data = fs.readFileSync(filePath);
    const base64 = data.toString('base64');
    const format = this._detectFormat(filePath);

    return this._display(base64, format, options);
  }

  /**
   * Display an image from buffer
   * @param {Buffer} buffer - Image data
   * @param {Object} options
   */
  async displayBuffer(buffer, options = {}) {
    const base64 = buffer.toString('base64');
    const format = options.format || 100; // Default to PNG

    return this._display(base64, format, options);
  }

  /**
   * Display an image from base64 data
   * @param {string} base64 - Base64 encoded image
   * @param {Object} options
   */
  async displayBase64(base64, options = {}) {
    const format = options.format || 100; // PNG
    return this._display(base64, format, options);
  }

  /**
   * Display raw RGBA pixels
   * @param {Buffer} rgba - RGBA pixel data
   * @param {number} width - Image width in pixels
   * @param {number} height - Image height in pixels
   * @param {Object} options
   */
  async displayRGBA(rgba, width, height, options = {}) {
    const base64 = rgba.toString('base64');
    return this._display(base64, 32, { ...options, pixelWidth: width, pixelHeight: height });
  }

  /**
   * Clear all images
   */
  clear() {
    process.stdout.write(`${APC}a=d,d=a${ST}`);
  }

  /**
   * Clear specific image by ID
   * @param {number} id
   */
  clearImage(id) {
    process.stdout.write(`${APC}a=d,d=i,i=${id}${ST}`);
  }

  /**
   * Internal display method
   * @private
   */
  _display(base64, format, options = {}) {
    const id = options.id || this._nextId++;
    const chunkSize = 4096;

    let offset = 0;
    let first = true;

    while (offset < base64.length) {
      const chunk = base64.slice(offset, offset + chunkSize);
      const isLast = offset + chunkSize >= base64.length;

      let cmd = '';

      if (first) {
        // First chunk - include all options
        cmd = `a=T,f=${format},t=d,i=${id},q=2,m=${isLast ? 0 : 1}`;

        if (options.width) cmd += `,c=${options.width}`;
        if (options.height) cmd += `,r=${options.height}`;
        if (options.pixelWidth) cmd += `,s=${options.pixelWidth}`;
        if (options.pixelHeight) cmd += `,v=${options.pixelHeight}`;
        if (options.x) cmd += `,x=${options.x}`;
        if (options.y) cmd += `,y=${options.y}`;
        if (options.z) cmd += `,z=${options.z}`;
        if (options.xOffset) cmd += `,X=${options.xOffset}`;
        if (options.yOffset) cmd += `,Y=${options.yOffset}`;

        cmd += ',C=1'; // Don't move cursor

        first = false;
      } else {
        // Continuation chunk
        cmd = `m=${isLast ? 0 : 1}`;
      }

      process.stdout.write(`${APC}${cmd};${chunk}${ST}`);
      offset += chunkSize;
    }

    return id;
  }

  /**
   * Detect image format from file extension
   * @private
   */
  _detectFormat(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    switch (ext) {
      case '.png':
        return 100;
      case '.jpg':
      case '.jpeg':
        return 32; // Kitty decodes as raw
      case '.gif':
        return 100; // Treat as PNG for now
      default:
        return 100;
    }
  }

  /**
   * Check if terminal supports Kitty graphics
   */
  static isSupported() {
    const term = process.env.TERM_PROGRAM || '';
    return ['kitty', 'ghostty', 'WezTerm'].some((t) =>
      term.toLowerCase().includes(t.toLowerCase())
    );
  }

  /**
   * Get terminal info
   */
  static getTerminalInfo() {
    return {
      program: process.env.TERM_PROGRAM || 'unknown',
      term: process.env.TERM || 'unknown',
      supported: KittyGraphics.isSupported(),
    };
  }
}

module.exports = KittyGraphics;
