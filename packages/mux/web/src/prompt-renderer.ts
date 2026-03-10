/**
 * Prompt overlay renderer — renders terminal cells to an offscreen canvas (Canvas 2D).
 * The offscreen canvas is then composited into the main WebGPU render pass by
 * webgpu-renderer.ts via setPromptOverlay().
 */

export interface PromptCell {
  codepoint: number;
  char: string;
  fgR: number; fgG: number; fgB: number;
  bgR: number; bgG: number; bgB: number;
}

export interface PromptRenderer {
  /** Render cells onto the offscreen canvas and return it */
  render(
    cells: PromptCell[][],  // rows of cells
    startX: number,         // pixel X of col 0
    startY: number,         // pixel Y of first row
    cellW: number,          // cell width in surface pixels
    cellH: number,          // cell height in surface pixels
    surfW: number,          // surface width (canvas resolution)
    surfH: number,          // surface height
  ): HTMLCanvasElement;
  /** Clear the offscreen canvas */
  clear(): void;
  /** Dispose resources */
  dispose(): void;
}

/** Create a prompt renderer that draws cells to an offscreen Canvas 2D element. */
export function createPromptRenderer(): PromptRenderer {
  const offscreen = document.createElement('canvas');
  const ctx = offscreen.getContext('2d', { alpha: true })!;

  return {
    render(cells, startX, startY, cellW, cellH, surfW, surfH): HTMLCanvasElement {
      if (offscreen.width !== surfW || offscreen.height !== surfH) {
        offscreen.width = surfW;
        offscreen.height = surfH;
      }
      ctx.clearRect(0, 0, surfW, surfH);

      const fontSize = Math.round(cellH * 0.75);
      ctx.font = `${fontSize}px ui-monospace, 'Cascadia Code', 'Source Code Pro', Menlo, Consolas, monospace`;
      ctx.textBaseline = 'middle';

      for (let row = 0; row < cells.length; row++) {
        const rowY = startY + row * cellH;
        const rowCells = cells[row];
        for (let col = 0; col < rowCells.length; col++) {
          const cell = rowCells[col];
          if (cell.codepoint === 0 && !cell.bgR && !cell.bgG && !cell.bgB) continue;
          const x = startX + col * cellW;

          // Background — only draw if non-default (non-zero)
          if (cell.bgR || cell.bgG || cell.bgB) {
            ctx.fillStyle = `rgb(${cell.bgR},${cell.bgG},${cell.bgB})`;
            ctx.fillRect(x, rowY, cellW, cellH);
          }

          // Character
          if (cell.codepoint > 0) {
            ctx.fillStyle = `rgb(${cell.fgR},${cell.fgG},${cell.fgB})`;
            ctx.fillText(cell.char, x + 1, rowY + cellH / 2);
          }
        }
      }

      return offscreen;
    },

    clear() {
      ctx.clearRect(0, 0, offscreen.width, offscreen.height);
    },

    dispose() { /* nothing */ },
  };
}
