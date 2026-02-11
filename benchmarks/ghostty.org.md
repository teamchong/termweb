bun run packages/mux/benchmark/run.ts --port 7681

╔══════════════════════════════════════════════════════════════╗
║          Termweb Bandwidth Benchmark Report                 ║
║          VT Passthrough vs H264 + zstd                      ║
╚══════════════════════════════════════════════════════════════╝

  Session duration:  85.9s
  Commands seen:     sh, bash, termweb, chrome, cat

  ┌─────────────────────────────────────────────────────────┐
  │  Approach              │  Bytes (↑)    │  Rate         │
  ├─────────────────────────────────────────────────────────┤
  │  VT Passthrough        │  599.20 MB    │  6.98 MB/s    │
  │  H264 + zstd (termweb) │  82.18 MB     │  979.7 KB/s   │
  └─────────────────────────────────────────────────────────┘

  Result: H264+zstd saves 86.3% bandwidth (0.14x ratio)

  Detailed Breakdown:
  ───────────────────
    VT bytes (raw PTY output):       599.20 MB
    H264 video bytes:                82.18 MB (1024 frames)
    Control channel sent (zstd):     1.4 KB
    Control channel received:        2.6 KB
    Raw BGRA pixels captured:        34349.19 MB
    H264 compression ratio (vs raw): 418:1

  Notes:
  ──────
  • Comparison is server→client output only (input is equivalent for both)
  • VT passthrough sends raw escape sequences — bandwidth scales with output volume
  • H264+zstd has bounded bandwidth (capped by bitrate), regardless of terminal output
  • Heavy workloads (claude code, cat large files) cause VT clients to lag;
    H264 decoding is constant-time via hardware acceleration