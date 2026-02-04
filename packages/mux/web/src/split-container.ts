import { SPLIT } from './constants';

type SplitDirection = 'horizontal' | 'vertical';
type SplitCommand = 'right' | 'down' | 'left' | 'up';

// Minimal interface for panels - works with both vanilla JS and Svelte components
export interface PanelLike {
  id: string;
  serverId: number | null;
  element: HTMLElement;
  canvas?: HTMLCanvasElement;
  destroy: () => void;
}

export class SplitContainer {
  parent: SplitContainer | null;
  direction: SplitDirection | null = null;
  first: SplitContainer | null = null;
  second: SplitContainer | null = null;
  panel: PanelLike | null = null;
  ratio: number = SPLIT.DEFAULT_RATIO;
  element: HTMLElement;
  divider: HTMLElement | null = null;
  private isDragging = false;
  private dividerMouseDownHandler: ((e: MouseEvent) => void) | null = null;
  private documentMoveHandler: ((e: MouseEvent) => void) | null = null;
  private documentUpHandler: (() => void) | null = null;

  constructor(parent: SplitContainer | null = null) {
    this.parent = parent;
    this.element = document.createElement('div');
  }

  static createLeaf(panel: PanelLike, parent: SplitContainer | null = null): SplitContainer {
    const container = new SplitContainer(parent);
    container.panel = panel;
    container.element = document.createElement('div');
    container.element.className = 'split-pane';
    container.element.style.flex = '1';
    if (panel.element.parentElement) {
      panel.element.parentElement.removeChild(panel.element);
    }
    container.element.appendChild(panel.element);
    return container;
  }

  split(splitDirection: SplitCommand, newPanel: PanelLike): SplitContainer | null {
    if (this.direction !== null) {
      console.error('Cannot split a non-leaf container directly');
      return null;
    }

    const isHorizontal = splitDirection === 'left' || splitDirection === 'right';
    const newPanelFirst = splitDirection === 'left' || splitDirection === 'up';

    const oldPanel = this.panel!;
    this.panel = null;
    this.direction = isHorizontal ? 'horizontal' : 'vertical';

    if (newPanelFirst) {
      this.first = SplitContainer.createLeaf(newPanel, this);
      this.second = SplitContainer.createLeaf(oldPanel, this);
    } else {
      this.first = SplitContainer.createLeaf(oldPanel, this);
      this.second = SplitContainer.createLeaf(newPanel, this);
    }

    this.rebuildDOM();
    return newPanelFirst ? this.first : this.second;
  }

  rebuildDOM(): void {
    const parent = this.element.parentElement;
    const oldElement = this.element;

    this.element = document.createElement('div');
    this.element.className = `split-container ${this.direction}`;
    if (oldElement.style.flex) {
      this.element.style.flex = oldElement.style.flex;
    }

    this.element.appendChild(this.first!.element);

    this.divider = document.createElement('div');
    this.divider.className = 'split-divider';
    this.setupDividerDrag();
    this.element.appendChild(this.divider);

    this.element.appendChild(this.second!.element);

    this.applyRatio();

    if (parent) {
      parent.replaceChild(this.element, oldElement);
    }
  }

  setupDividerDrag(): void {
    let startPos = 0;
    let startRatio = 0;
    let containerSize = 0;

    const onMouseDown = (e: MouseEvent) => {
      e.preventDefault();
      this.isDragging = true;
      this.divider!.classList.add('dragging');

      const rect = this.element.getBoundingClientRect();
      if (this.direction === 'horizontal') {
        startPos = e.clientX;
        containerSize = rect.width;
      } else {
        startPos = e.clientY;
        containerSize = rect.height;
      }
      startRatio = this.ratio;

      this.documentMoveHandler = onMouseMove;
      this.documentUpHandler = onMouseUp;
      document.addEventListener('mousemove', this.documentMoveHandler);
      document.addEventListener('mouseup', this.documentUpHandler);
    };

    const onMouseMove = (e: MouseEvent) => {
      if (!this.isDragging) return;

      let delta: number;
      if (this.direction === 'horizontal') {
        delta = e.clientX - startPos;
      } else {
        delta = e.clientY - startPos;
      }

      const availableSize = containerSize - SPLIT.DIVIDER_SIZE;
      const deltaRatio = delta / availableSize;

      this.ratio = Math.max(SPLIT.MIN_RATIO, Math.min(SPLIT.MAX_RATIO, startRatio + deltaRatio));
      this.applyRatio();
    };

    const onMouseUp = () => {
      this.isDragging = false;
      this.divider?.classList.remove('dragging');
      this.cleanupDragListeners();
    };

    this.dividerMouseDownHandler = onMouseDown;
    this.divider!.addEventListener('mousedown', onMouseDown);
  }

  private cleanupDragListeners(): void {
    if (this.documentMoveHandler) {
      document.removeEventListener('mousemove', this.documentMoveHandler);
      this.documentMoveHandler = null;
    }
    if (this.documentUpHandler) {
      document.removeEventListener('mouseup', this.documentUpHandler);
      this.documentUpHandler = null;
    }
  }

  applyRatio(): void {
    if (!this.first || !this.second) return;

    const firstPercent = (this.ratio * 100).toFixed(2);
    const secondPercent = ((1 - this.ratio) * 100).toFixed(2);

    this.first.element.style.flex = `0 0 calc(${firstPercent}% - 2px)`;
    this.second.element.style.flex = `0 0 calc(${secondPercent}% - 2px)`;
  }

  findContainer(panel: PanelLike): SplitContainer | null {
    if (this.panel?.id === panel.id) return this;
    if (this.first) {
      const found = this.first.findContainer(panel);
      if (found) return found;
    }
    if (this.second) {
      const found = this.second.findContainer(panel);
      if (found) return found;
    }
    return null;
  }

  getAllPanels(): PanelLike[] {
    const panels: PanelLike[] = [];
    if (this.panel) {
      panels.push(this.panel);
    }
    if (this.first) {
      panels.push(...this.first.getAllPanels());
    }
    if (this.second) {
      panels.push(...this.second.getAllPanels());
    }
    return panels;
  }

  removePanel(panel: PanelLike): boolean {
    if (this.panel?.id === panel.id) {
      return true;
    }

    if (this.first && this.first.panel?.id === panel.id) {
      const toRemove = this.first;
      this.promoteChild(this.second!);
      if (toRemove.element) toRemove.element.remove();
      return true;
    }

    if (this.second && this.second.panel?.id === panel.id) {
      const toRemove = this.second;
      this.promoteChild(this.first!);
      if (toRemove.element) toRemove.element.remove();
      return true;
    }

    if (this.first && this.first.removePanel(panel)) return true;
    if (this.second && this.second.removePanel(panel)) return true;

    return false;
  }

  private promoteChild(child: SplitContainer): void {
    if (this.divider) {
      this.divider.remove();
      this.divider = null;
    }

    if (child.direction !== null) {
      this.direction = child.direction;
      this.first = child.first;
      this.second = child.second;
      this.ratio = child.ratio;
      this.divider = child.divider;
      this.panel = null;
      if (this.first) this.first.parent = this;
      if (this.second) this.second.parent = this;
      this.rebuildDOM();
    } else {
      this.direction = null;
      this.first = null;
      this.second = null;
      this.panel = child.panel;

      const parent = this.element.parentElement;
      const oldElement = this.element;

      this.element = document.createElement('div');
      this.element.className = 'split-pane';
      this.element.style.flex = '1';
      if (this.panel && this.panel.element.parentElement) {
        this.panel.element.parentElement.removeChild(this.panel.element);
      }
      if (this.panel) {
        this.element.appendChild(this.panel.element);
      }

      if (parent) {
        parent.replaceChild(this.element, oldElement);
      }
    }
  }

  destroy(): void {
    if (this.divider && this.dividerMouseDownHandler) {
      this.divider.removeEventListener('mousedown', this.dividerMouseDownHandler);
      this.dividerMouseDownHandler = null;
    }
    this.cleanupDragListeners();
    this.isDragging = false;

    if (this.panel) {
      this.panel.destroy();
    }
    if (this.first) {
      this.first.destroy();
    }
    if (this.second) {
      this.second.destroy();
    }
    if (this.element && this.element.parentElement) {
      this.element.remove();
    }
  }

  private weight(forDirection: SplitDirection): number {
    if (this.panel) return 1;
    if (this.direction !== forDirection) return 1;
    const leftWeight = this.first?.weight(forDirection) ?? 0;
    const rightWeight = this.second?.weight(forDirection) ?? 0;
    return leftWeight + rightWeight;
  }

  equalize(): void {
    if (this.direction !== null && this.first && this.second) {
      const leftWeight = this.first.weight(this.direction);
      const rightWeight = this.second.weight(this.direction);
      this.ratio = leftWeight / (leftWeight + rightWeight);
      this.applyRatio();
      this.first.equalize();
      this.second.equalize();
    }
  }

  resizeSplit(direction: 'up' | 'down' | 'left' | 'right', amount: number): void {
    const isVerticalMove = direction === 'up' || direction === 'down';
    const isNegative = direction === 'up' || direction === 'left';

    const targetDirection: SplitDirection = isVerticalMove ? 'vertical' : 'horizontal';
    const container = this.findContainerWithDirection(targetDirection);

    if (container) {
      const rect = container.element.getBoundingClientRect();
      const containerSize = isVerticalMove ? rect.height : rect.width;
      const deltaRatio = (isNegative ? -amount : amount) / containerSize;
      container.ratio = Math.max(SPLIT.MIN_RATIO, Math.min(SPLIT.MAX_RATIO, container.ratio + deltaRatio));
      container.applyRatio();
    }
  }

  private findContainerWithDirection(targetDirection: SplitDirection): SplitContainer | null {
    let current: SplitContainer | null = this;
    while (current) {
      if (current.direction === targetDirection) {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  selectSplitInDirection(direction: 'up' | 'down' | 'left' | 'right', panelId: string | undefined): PanelLike | null {
    if (!panelId) return null;

    const panels = this.getAllPanels();
    const currentPanel = panels.find(p => p.id === panelId);
    if (!currentPanel || !currentPanel.canvas) return null;

    const currentRect = currentPanel.canvas.getBoundingClientRect();
    const currentCenterX = currentRect.left + currentRect.width / 2;
    const currentCenterY = currentRect.top + currentRect.height / 2;

    let bestPanel: PanelLike | null = null;
    let bestDistance = Infinity;

    for (const panel of panels) {
      if (panel.id === panelId || !panel.canvas) continue;

      const rect = panel.canvas.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;

      let inDirection = false;
      let distance = 0;

      switch (direction) {
        case 'up':
          inDirection = centerY < currentCenterY;
          distance = currentCenterY - centerY + Math.abs(centerX - currentCenterX) * SPLIT.PERPENDICULAR_WEIGHT;
          break;
        case 'down':
          inDirection = centerY > currentCenterY;
          distance = centerY - currentCenterY + Math.abs(centerX - currentCenterX) * SPLIT.PERPENDICULAR_WEIGHT;
          break;
        case 'left':
          inDirection = centerX < currentCenterX;
          distance = currentCenterX - centerX + Math.abs(centerY - currentCenterY) * SPLIT.PERPENDICULAR_WEIGHT;
          break;
        case 'right':
          inDirection = centerX > currentCenterX;
          distance = centerX - currentCenterX + Math.abs(centerY - currentCenterY) * SPLIT.PERPENDICULAR_WEIGHT;
          break;
      }

      if (inDirection && distance < bestDistance) {
        bestDistance = distance;
        bestPanel = panel;
      }
    }

    return bestPanel;
  }
}
