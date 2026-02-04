<script lang="ts">
  type Status = 'connected' | 'disconnected' | 'error';

  interface Props {
    status?: Status;
  }

  let { status = 'disconnected' }: Props = $props();

  const titles: Record<Status, string> = {
    connected: 'Connected',
    disconnected: 'Disconnected',
    error: 'Connection Error',
  };
</script>

<span
  id="status-dot"
  class={status}
  title={titles[status]}
></span>

<style>
  #status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #ef4444;
    margin-left: 8px;
    cursor: help;
    transition: background 0.2s;
  }
  #status-dot.connected {
    background: #22c55e;
  }
  #status-dot.error {
    background: #f59e0b;
  }
</style>
