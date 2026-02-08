<script lang="ts">
  import { tabs, activeTabId } from '../stores/index';
  import type { MuxClient } from '../services/mux';
  import { PANEL } from '../constants';
  import { NAL } from '../constants';

  interface Props {
    open?: boolean;
    panelsEl?: HTMLElement;
    muxClient?: MuxClient | null;
    onClose?: () => void;
    onSelectTab?: (id: string) => void;
    onCloseTab?: (id: string) => void;
    onNewTab?: () => void;
  }

  let { open = false, panelsEl, muxClient, onClose, onSelectTab, onCloseTab, onNewTab }: Props = $props();

  // Convert tabs to array
  let tabList = $derived(Array.from($tabs.values()));

  // Preview dimensions
  let previewWidth = $state(0);
  let previewHeight = $state(0);

  // Keyboard navigation - selected index (-1 = new tab button)
  let selectedIndex = $state(0);

  // Canvas refs keyed by panelServerId
  let canvasRefs = $state<Record<number, HTMLCanvasElement | undefined>>({});

  // Per-panel decoders for live preview
  let panelDecoders = new Map<number, VideoDecoder>();
  let panelContexts = new Map<number, CanvasRenderingContext2D>();
  let panelDecoderConfigured = new Map<number, boolean>();
  let panelLastCodec = new Map<number, string>();
  let panelGotFirstKeyframe = new Map<number, boolean>();

  // Tab → panel server IDs mapping
  let tabPanelMap = $state(new Map<string, number[]>());

  // Snapshot fallbacks for initial display
  let snapshots = $state(new Map<string, string>());

  function handleSelectTab(id: string) {
    closeOverview();
    onSelectTab?.(id);
  }

  function handleCloseTab(e: MouseEvent, id: string) {
    e.stopPropagation();
    onCloseTab?.(id);
    // Close overview if no tabs remain
    if ($tabs.size <= 1) {
      closeOverview();
    }
  }

  function handleNewTab() {
    closeOverview();
    onNewTab?.();
  }

  function closeOverview() {
    stopLivePreview();
    onClose?.();
  }

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) {
      closeOverview();
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    const totalItems = tabList.length + 1; // tabs + new tab button

    switch (e.key) {
      case 'Escape':
        e.preventDefault();
        e.stopPropagation();
        closeOverview();
        break;
      case 'ArrowRight':
      case 'ArrowDown':
        e.preventDefault();
        selectedIndex = (selectedIndex + 1) % totalItems;
        break;
      case 'ArrowLeft':
      case 'ArrowUp':
        e.preventDefault();
        selectedIndex = (selectedIndex - 1 + totalItems) % totalItems;
        break;
      case 'Enter':
        e.preventDefault();
        if (selectedIndex < tabList.length) {
          handleSelectTab(tabList[selectedIndex].id);
        } else {
          handleNewTab();
        }
        break;
    }
  }

  function parseNalUnits(data: Uint8Array): Uint8Array[] {
    const units: Uint8Array[] = [];
    let start = 0;

    for (let i = 0; i < data.length - 3; i++) {
      if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 0 && data[i + 3] === 1) {
        if (i > start) {
          units.push(data.slice(start, i));
        }
        start = i + 4;
        i += 3;
      }
    }

    if (start < data.length) {
      units.push(data.slice(start));
    }

    return units;
  }

  function getCodecFromSps(sps: Uint8Array): string {
    if (sps.length < 4) return PANEL.DEFAULT_H264_CODEC;
    const profile = sps[1];
    const constraints = sps[2];
    const level = sps[3];
    return `avc1.${profile.toString(16).padStart(2, '0')}${constraints.toString(16).padStart(2, '0')}${level.toString(16).padStart(2, '0')}`;
  }

  function getOrCreateDecoder(panelId: number): VideoDecoder | null {
    if (panelDecoders.has(panelId)) return panelDecoders.get(panelId)!;

    const decoder = new VideoDecoder({
      output: (frame) => {
        const canvas = canvasRefs[panelId];
        if (!canvas) {
          frame.close();
          return;
        }
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth;
          canvas.height = frame.displayHeight;
        }
        let ctx = panelContexts.get(panelId);
        if (!ctx) {
          ctx = canvas.getContext('2d', { alpha: false }) ?? undefined;
          if (ctx) panelContexts.set(panelId, ctx);
        }
        if (ctx) {
          ctx.drawImage(frame, 0, 0);
        }
        frame.close();
      },
      error: (e) => {
        console.error(`Overview decoder error for panel ${panelId}:`, e);
        panelDecoderConfigured.delete(panelId);
        panelGotFirstKeyframe.delete(panelId);
      },
    });
    panelDecoders.set(panelId, decoder);
    return decoder;
  }

  function handlePreviewFrame(panelId: number, frameData: Uint8Array): void {
    const decoder = getOrCreateDecoder(panelId);
    if (!decoder) return;

    const nalUnits = parseNalUnits(frameData);
    let isKeyframe = false;
    let sps: Uint8Array | null = null;

    for (const nal of nalUnits) {
      if (nal.length === 0) continue;
      const nalType = nal[0] & NAL.TYPE_MASK;
      if (nalType === NAL.TYPE_SPS) sps = nal;
      else if (nalType === NAL.TYPE_IDR) isKeyframe = true;
    }

    if (sps) {
      const codec = getCodecFromSps(sps);
      const lastCodec = panelLastCodec.get(panelId);
      const configured = panelDecoderConfigured.get(panelId);
      if (!configured || codec !== lastCodec) {
        try {
          if (configured) {
            decoder.reset();
            panelGotFirstKeyframe.delete(panelId);
          }
          decoder.configure({ codec, optimizeForLatency: true });
          panelDecoderConfigured.set(panelId, true);
          panelLastCodec.set(panelId, codec);
        } catch (e) {
          console.error('Overview decoder configure error:', e);
          return;
        }
      }
    }

    if (!panelDecoderConfigured.get(panelId)) return;

    if (!panelGotFirstKeyframe.get(panelId)) {
      if (!isKeyframe) return;
      panelGotFirstKeyframe.set(panelId, true);
    }

    // Skip frames if decoder is backed up
    if (!isKeyframe && decoder.decodeQueueSize > 2) return;

    const timestamp = performance.now() * 1000;
    try {
      const chunk = new EncodedVideoChunk({
        type: isKeyframe ? 'key' : 'delta',
        timestamp,
        data: frameData,
      });
      decoder.decode(chunk);
    } catch (e) {
      console.error('Overview decode error:', e);
    }
  }

  function startLivePreview(): void {
    if (!muxClient || !panelsEl) return;

    // Calculate preview dimensions from panels container
    const rect = panelsEl.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return;
    const aspectRatio = rect.width / rect.height;
    const targetHeight = 200;
    previewWidth = Math.round(targetHeight * aspectRatio);
    previewHeight = targetHeight;

    // Get panel → tab mapping
    tabPanelMap = muxClient.getTabPanelServerIds();

    // Capture initial snapshots for fallback display
    snapshots = muxClient.getTabSnapshots();

    // Set H264 override handler for overview frame rendering
    muxClient.setH264OverrideHandler(handlePreviewFrame);
  }

  function stopLivePreview(): void {
    // Close all decoders
    for (const [, decoder] of panelDecoders) {
      try {
        if (decoder.state !== 'closed') decoder.close();
      } catch { /* ignore */ }
    }
    panelDecoders.clear();
    panelContexts.clear();
    panelDecoderConfigured.clear();
    panelLastCodec.clear();
    panelGotFirstKeyframe.clear();
    canvasRefs = {};

    // Clear H264 override handler
    muxClient?.setH264OverrideHandler(null);
  }

  // Start live preview when overview opens
  $effect(() => {
    if (open && panelsEl && muxClient) {
      // Reset selection to active tab
      const activeIndex = tabList.findIndex(t => t.id === $activeTabId);
      selectedIndex = activeIndex >= 0 ? activeIndex : 0;
      // Use requestAnimationFrame to ensure DOM is ready
      requestAnimationFrame(() => {
        startLivePreview();
      });
      return () => {
        stopLivePreview();
      };
    }
  });

  // Keyboard listener
  $effect(() => {
    if (open) {
      window.addEventListener('keydown', handleKeydown);
      return () => {
        window.removeEventListener('keydown', handleKeydown);
      };
    }
  });
</script>

{#if open}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="tab-overview" onclick={handleOverlayClick}>
    <div class="tab-overview-grid">
      {#each tabList as tab, i (tab.id)}
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <div
          class="tab-preview"
          class:active={$activeTabId === tab.id}
          class:selected={selectedIndex === i}
          style="width: {previewWidth}px;"
          onclick={() => handleSelectTab(tab.id)}
        >
          <div class="tab-preview-title">
            <span
              class="tab-preview-close"
              role="button"
              tabindex="0"
              onclick={(e) => handleCloseTab(e, tab.id)}
              onkeydown={(e) => e.key === 'Enter' && handleCloseTab(e as unknown as MouseEvent, tab.id)}
            >✕</span>
            <span class="tab-preview-title-text">
              <span class="tab-preview-indicator">•</span>
              <span class="tab-preview-title-label">{tab.title || '👻'}</span>
            </span>
            <span class="tab-preview-spacer"></span>
          </div>
          <div
            class="tab-preview-content"
            style="width: {previewWidth}px; height: {previewHeight}px;"
          >
            {#if tabPanelMap.has(tab.id)}
              {#each tabPanelMap.get(tab.id) ?? [] as serverId (serverId)}
                <canvas
                  bind:this={canvasRefs[serverId]}
                  class="tab-preview-canvas"
                ></canvas>
              {/each}
            {:else if snapshots.has(tab.id)}
              <img
                src={snapshots.get(tab.id)}
                alt={tab.title || 'Tab preview'}
                class="tab-preview-image"
              />
            {/if}
          </div>
        </div>
      {/each}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <div
        class="tab-preview-new"
        class:selected={selectedIndex === tabList.length}
        style="width: {previewWidth}px; height: {previewHeight + 18}px;"
        onclick={handleNewTab}
      >
        <span class="tab-preview-new-icon">+</span>
      </div>
    </div>
  </div>
{/if}

<style>
  .tab-overview {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: color-mix(in srgb, var(--bg) 90%, black);
    z-index: 1000;
    overflow: auto;
    padding: 32px;
  }

  .tab-overview-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 20px;
    align-items: flex-start;
    justify-content: flex-start;
  }

  .tab-preview {
    background: var(--bg);
    border-radius: 12px;
    overflow: hidden;
    cursor: pointer;
    transition: transform 0.15s, box-shadow 0.15s, border-color 0.15s;
    position: relative;
    border: 3px solid transparent;
  }

  .tab-preview:hover {
    transform: scale(1.02);
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
    border-color: rgba(255, 255, 255, 0.3);
  }

  .tab-preview.active {
    border-color: #007AFF;
    box-shadow: 0 0 0 1px #007AFF, 0 4px 20px rgba(0, 122, 255, 0.3);
  }

  .tab-preview.selected {
    outline: 2px solid rgba(255, 255, 255, 0.6);
    outline-offset: 2px;
  }

  .tab-preview-new.selected {
    outline: 2px solid rgba(255, 255, 255, 0.6);
    outline-offset: 2px;
  }

  .tab-preview-title {
    padding: 0 6px;
    font-size: 11px;
    color: var(--text);
    background: var(--toolbar-bg);
    display: flex;
    align-items: center;
    justify-content: space-between;
    border-radius: 12px 12px 0 0;
  }

  .tab-preview-spacer {
    width: 16px;
    flex-shrink: 0;
  }

  .tab-preview-title-text {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-width: 0;
    flex: 1;
  }

  .tab-preview-indicator {
    color: var(--text-dim);
    flex-shrink: 0;
  }

  .tab-preview-title-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .tab-preview-close {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    font-size: 10px;
    color: var(--text-dim);
    cursor: pointer;
    transition: opacity 0.15s, background 0.1s;
    opacity: 0;
  }

  .tab-preview:hover .tab-preview-close {
    opacity: 1;
  }

  .tab-preview-close:hover {
    background: var(--close-hover);
    color: var(--text);
  }

  .tab-preview-content {
    overflow: hidden;
    background: var(--bg);
    border-radius: 0 0 12px 12px;
    position: relative;
  }

  .tab-preview-canvas {
    width: 100%;
    height: 100%;
    object-fit: contain;
    display: block;
  }

  .tab-preview-image {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }

  .tab-preview-new {
    background: rgba(255, 255, 255, 0.05);
    border: 3px dashed rgba(255, 255, 255, 0.2);
    border-radius: 12px;
    cursor: pointer;
    transition: all 0.15s;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .tab-preview-new:hover {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.4);
    transform: scale(1.02);
  }

  .tab-preview-new-icon {
    font-size: 48px;
    color: rgba(255, 255, 255, 0.4);
  }

  .tab-preview-new:hover .tab-preview-new-icon {
    color: rgba(255, 255, 255, 0.7);
  }

  @media (hover: none) {
    .tab-preview-close {
      opacity: 1;
    }
  }
</style>
