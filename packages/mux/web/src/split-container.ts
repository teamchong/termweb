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

  private setupDividerDrag(): void {
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

      document.addEventListener('mousemove', onMouseMove);
      document.addEventListener('mouseup', onMouseUp);
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
      this.divider!.classList.remove('dragging');
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup', onMouseUp);
    };

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
}
