import type { Panel } from './panel';

type SplitDirection = 'horizontal' | 'vertical';
type SplitCommand = 'right' | 'down' | 'left' | 'up';

export class SplitContainer {
  parent: SplitContainer | null;
  direction: SplitDirection | null = null;
  first: SplitContainer | null = null;
  second: SplitContainer | null = null;
  panel: Panel | null = null;
  ratio = 0.5;
  element: HTMLElement;
  divider: HTMLElement | null = null;
  private isDragging = false;
  private dividerMouseDownHandler: ((e: MouseEvent) => void) | null = null;

  constructor(parent: SplitContainer | null = null) {
    this.parent = parent;
    this.element = document.createElement('div');
  }

  static createLeaf(panel: Panel, parent: SplitContainer | null = null): SplitContainer {
    const container = new SplitContainer(parent);
    container.panel = panel;
    container.element = document.createElement('div');
    container.element.className = 'split-pane';
    container.element.style.flex = '1';
    panel.reparent(container.element);
    return container;
  }

  split(splitDirection: SplitCommand, newPanel: Panel): SplitContainer | null {
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
    let moveHandler: ((e: MouseEvent) => void) | null = null;
    let upHandler: (() => void) | null = null;

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

      moveHandler = onMouseMove;
      upHandler = onMouseUp;
      document.addEventListener('mousemove', moveHandler);
      document.addEventListener('mouseup', upHandler);
    };

    const onMouseMove = (e: MouseEvent) => {
      if (!this.isDragging) return;

      let delta: number;
      if (this.direction === 'horizontal') {
        delta = e.clientX - startPos;
      } else {
        delta = e.clientY - startPos;
      }

      const dividerSize = 4;
      const availableSize = containerSize - dividerSize;
      const deltaRatio = delta / availableSize;

      this.ratio = Math.max(0.1, Math.min(0.9, startRatio + deltaRatio));
      this.applyRatio();
    };

    const onMouseUp = () => {
      this.isDragging = false;
      this.divider?.classList.remove('dragging');
      if (moveHandler) document.removeEventListener('mousemove', moveHandler);
      if (upHandler) document.removeEventListener('mouseup', upHandler);
      moveHandler = null;
      upHandler = null;
    };

    this.dividerMouseDownHandler = onMouseDown;
    this.divider!.addEventListener('mousedown', onMouseDown);
  }

  applyRatio(): void {
    if (!this.first || !this.second) return;

    const firstPercent = (this.ratio * 100).toFixed(2);
    const secondPercent = ((1 - this.ratio) * 100).toFixed(2);

    this.first.element.style.flex = `0 0 calc(${firstPercent}% - 2px)`;
    this.second.element.style.flex = `0 0 calc(${secondPercent}% - 2px)`;
  }

  findContainer(panel: Panel): SplitContainer | null {
    if (this.panel === panel) return this;
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

  getAllPanels(): Panel[] {
    const panels: Panel[] = [];
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

  removePanel(panel: Panel): boolean {
    if (this.panel === panel) {
      return true;
    }

    if (this.first && this.first.panel === panel) {
      const toRemove = this.first;
      this.promoteChild(this.second!);
      if (toRemove.element) toRemove.element.remove();
      return true;
    }

    if (this.second && this.second.panel === panel) {
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
      this.panel!.reparent(this.element);

      if (parent) {
        parent.replaceChild(this.element, oldElement);
      }
    }
  }

  destroy(): void {
    // Clean up divider event listener
    if (this.divider && this.dividerMouseDownHandler) {
      this.divider.removeEventListener('mousedown', this.dividerMouseDownHandler);
      this.dividerMouseDownHandler = null;
    }

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

  // Count the number of leaf panels in this subtree
  private weight(): number {
    if (this.panel) return 1;
    const leftWeight = this.first?.weight() ?? 0;
    const rightWeight = this.second?.weight() ?? 0;
    return leftWeight + rightWeight;
  }

  // Equalize splits based on the number of leaves on each side (like Ghostty)
  equalize(): void {
    if (this.direction !== null && this.first && this.second) {
      const leftWeight = this.first.weight();
      const rightWeight = this.second.weight();
      this.ratio = leftWeight / (leftWeight + rightWeight);
      this.applyRatio();
      this.first.equalize();
      this.second.equalize();
    }
  }

  // Resize split by moving divider in the given direction
  resizeSplit(direction: 'up' | 'down' | 'left' | 'right', amount: number): void {
    // Find the appropriate divider to move based on direction
    const isVerticalMove = direction === 'up' || direction === 'down';
    const isNegative = direction === 'up' || direction === 'left';

    // Find a container with matching direction
    const targetDirection: SplitDirection = isVerticalMove ? 'vertical' : 'horizontal';
    const container = this.findContainerWithDirection(targetDirection);

    if (container) {
      const rect = container.element.getBoundingClientRect();
      const containerSize = isVerticalMove ? rect.height : rect.width;
      const deltaRatio = (isNegative ? -amount : amount) / containerSize;
      container.ratio = Math.max(0.1, Math.min(0.9, container.ratio + deltaRatio));
      container.applyRatio();
    }
  }

  private findContainerWithDirection(targetDirection: SplitDirection): SplitContainer | null {
    // Walk up the tree to find a container with the matching direction
    let current: SplitContainer | null = this;
    while (current) {
      if (current.direction === targetDirection) {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  // Select split in the given direction from the panel with panelId
  selectSplitInDirection(direction: 'up' | 'down' | 'left' | 'right', panelId: number | undefined): Panel | null {
    if (!panelId) return null;

    // Get all panels with their bounding rects
    const panels = this.getAllPanels();
    const currentPanel = panels.find(p => p.id === panelId);
    if (!currentPanel) return null;

    const currentRect = currentPanel.canvas.getBoundingClientRect();
    const currentCenterX = currentRect.left + currentRect.width / 2;
    const currentCenterY = currentRect.top + currentRect.height / 2;

    let bestPanel: Panel | null = null;
    let bestDistance = Infinity;

    for (const panel of panels) {
      if (panel.id === panelId) continue;

      const rect = panel.canvas.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;

      // Check if panel is in the correct direction
      let inDirection = false;
      let distance = 0;

      switch (direction) {
        case 'up':
          inDirection = centerY < currentCenterY;
          distance = currentCenterY - centerY + Math.abs(centerX - currentCenterX) * 0.5;
          break;
        case 'down':
          inDirection = centerY > currentCenterY;
          distance = centerY - currentCenterY + Math.abs(centerX - currentCenterX) * 0.5;
          break;
        case 'left':
          inDirection = centerX < currentCenterX;
          distance = currentCenterX - centerX + Math.abs(centerY - currentCenterY) * 0.5;
          break;
        case 'right':
          inDirection = centerX > currentCenterX;
          distance = centerX - currentCenterX + Math.abs(centerY - currentCenterY) * 0.5;
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
