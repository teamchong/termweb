<script lang="ts">
  import QRCode from 'qrcode';

  interface Props {
    open?: boolean;
    onClose?: () => void;
    shareUrl?: string;
    title?: string;
    loading?: boolean;
  }

  let { open = false, onClose, shareUrl: propUrl, title = 'Share Terminal', loading = false }: Props = $props();

  let qrDataUrl = $state('');
  let copied = $state(false);
  let shareUrl = $state('');

  $effect(() => {
    if (open && !loading) {
      shareUrl = propUrl || window.location.href.replace(/[?#].*$/, '');
      QRCode.toDataURL(shareUrl, {
        width: 200,
        margin: 2,
        color: { dark: '#000000', light: '#ffffff' },
      }).then(url => { qrDataUrl = url; }).catch(() => {});
      copied = false;
    } else if (open && loading) {
      qrDataUrl = '';
      shareUrl = '';
      copied = false;
    }
  });

  function handleCopy() {
    navigator.clipboard.writeText(shareUrl).then(() => {
      copied = true;
      setTimeout(() => { copied = false; }, 1500);
    }).catch(() => {});
  }

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) onClose?.();
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      onClose?.();
    }
  }
</script>

{#if open}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="share-overlay" onclick={handleOverlayClick} onkeydown={handleKeydown}>
    <div class="share-dialog">
      <div class="share-header">{title}</div>

      {#if loading}
        <div class="spinner-container">
          <div class="spinner"></div>
          <div class="spinner-text">Loading share link...</div>
        </div>
      {:else}
        {#if qrDataUrl}
          <div class="qr-container">
            <img src={qrDataUrl} alt="QR Code" class="qr-code" />
          </div>
        {/if}

        <div class="url-container">
          <input
            type="text"
            class="url-input"
            value={shareUrl}
            readonly
            onclick={(e) => (e.target as HTMLInputElement).select()}
          />
          <button type="button" class="copy-btn" class:copied onclick={handleCopy}>
            {copied ? 'Copied' : 'Copy'}
          </button>
        </div>

        <div class="share-hint">
          Scan the QR code or copy the URL to share this terminal session.
        </div>
      {/if}

      <button type="button" class="close-btn" onclick={() => onClose?.()}>Close</button>
    </div>
  </div>
{/if}

<style>
  .share-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1001;
  }

  .share-dialog {
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 8px;
    width: 340px;
    max-width: 90vw;
    padding: 20px;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 16px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  }

  .share-header {
    font-size: 16px;
    font-weight: 600;
    color: var(--text);
  }

  .qr-container {
    background: white;
    border-radius: 8px;
    padding: 8px;
  }

  .qr-code {
    display: block;
    width: 200px;
    height: 200px;
  }

  .url-container {
    display: flex;
    width: 100%;
    gap: 6px;
  }

  .url-input {
    flex: 1;
    padding: 8px 10px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    background: rgba(0, 0, 0, 0.2);
    color: var(--text);
    font-size: 12px;
    font-family: monospace;
    outline: none;
    cursor: text;
    min-width: 0;
  }

  .url-input:focus {
    border-color: rgba(128, 128, 128, 0.5);
  }

  .copy-btn {
    padding: 8px 14px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    background: rgba(128, 128, 128, 0.15);
    color: var(--text);
    font-size: 12px;
    cursor: pointer;
    white-space: nowrap;
    transition: background 0.15s;
  }

  .copy-btn:hover {
    background: rgba(128, 128, 128, 0.25);
  }

  .copy-btn.copied {
    background: rgba(100, 200, 100, 0.3);
    border-color: rgba(100, 200, 100, 0.5);
  }

  .share-hint {
    font-size: 11px;
    color: var(--text-dim);
    text-align: center;
  }

  .close-btn {
    padding: 6px 20px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    background: transparent;
    color: var(--text);
    font-size: 12px;
    cursor: pointer;
  }

  .close-btn:hover {
    background: rgba(128, 128, 128, 0.15);
  }

  .spinner-container {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    padding: 32px 0;
  }

  .spinner {
    width: 32px;
    height: 32px;
    border: 3px solid rgba(128, 128, 128, 0.2);
    border-top-color: var(--text);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .spinner-text {
    font-size: 12px;
    color: var(--text-dim);
  }
</style>
