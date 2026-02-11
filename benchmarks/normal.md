bun run packages/mux/benchmark/run.ts --port 7681

╔══════════════════════════════════════════════════════════════╗
║          Termweb Bandwidth Benchmark Report                 ║
║          VT Passthrough vs H264 + zstd                      ║
╚══════════════════════════════════════════════════════════════╝

  Session duration:  142.1s
  Commands seen:     sh, bash, vi, nvim, starship, btm, claude, npm, uv, npm exec @upsta, npm exec @playw, MainThread, npm exec mcp-re, git, ssh

  ┌─────────────────────────────────────────────────────────┐
  │  Approach              │  Bytes (↑)    │  Rate         │
  ├─────────────────────────────────────────────────────────┤
  │  VT Passthrough        │  22.10 MB     │  159.3 KB/s   │
  │  H264 + zstd (termweb) │  11.93 MB     │  86.0 KB/s    │
  └─────────────────────────────────────────────────────────┘

  Result: H264+zstd saves 46.0% bandwidth (0.54x ratio)

  Detailed Breakdown:
  ───────────────────
    VT bytes (raw PTY output):       22.10 MB
    H264 video bytes:                11.92 MB (589 frames)
    Control channel sent (zstd):     7.3 KB
    Control channel received:        23.0 KB
    Raw BGRA pixels captured:        67299.28 MB
    H264 compression ratio (vs raw): 5646:1

  Notes:
  ──────
  • Comparison is server→client output only (input is equivalent for both)
  • VT passthrough sends raw escape sequences — bandwidth scales with output volume
  • H264+zstd has bounded bandwidth (capped by bitrate), regardless of terminal output
  • Heavy workloads (claude code, cat large files) cause VT clients to lag;
    H264 decoding is constant-time via hardware acceleration